import Foundation
import AppKit
import SwiftUI

/// Owns the database and all services; mirrors the Electron main process lifecycle
/// (index.ts): init DB → register scheduler tasks → retention sweep → start audio.
/// Recording toggles reproduce the tray behaviors, including flush-on-stop.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Recording toggles persist across launches. Screen defaults ON; audio defaults OFF
    // (opt-in — flip it in the menu bar or Settings when wanted).
    private static let screenPrefKey = "kaze.recording.screen"
    private static let audioPrefKey = "kaze.recording.audio"

    @Published var screenRecording: Bool
    @Published var audioRecording: Bool
    @Published var bootError: String?
    @Published var isReady = false
    /// True while the one-time index build runs over an existing history (Schema.ensureIndexes).
    @Published var preparingDatabase = false

    private(set) var db: SQLiteDB?
    private(set) var store: Store?
    let scheduler = Scheduler()
    let frameExtractor = FrameExtractor()
    @Published private(set) var analysis: AnalysisService?

    private var analysisTimer: Timer?

    private var screenshotService: ScreenshotService?
    private var encodingService: EncodingService?
    private var ocrService: OCRService?
    private var transcriptionService: TranscriptionService?
    private var retentionService: RetentionService?
    private var audioService: AudioCaptureService?

    private let screenTaskIDs = ["screenshot", "check-encoding", "process-encoding", "delete-screenshots"]
    private var didShutdown = false

    private init() {
        let defaults = UserDefaults.standard
        screenRecording = defaults.object(forKey: Self.screenPrefKey) as? Bool ?? true
        audioRecording = defaults.object(forKey: Self.audioPrefKey) as? Bool ?? false
    }

    // MARK: - Startup

    func bootstrap() async {
        Paths.ensureDirectories()

        // Opening, indexing and crash recovery all happen off the main actor. The first
        // launch after indexes were introduced has to build them across the whole history,
        // and every SQLiteDB call blocks its thread — doing this inline would beachball the
        // app before it finished starting. Indexes must exist before the scheduler runs:
        // its OCR and cleanup queries are the ones that need them.
        preparingDatabase = true
        let outcome = await Task.detached(priority: .userInitiated) { () -> (db: SQLiteDB?, error: String?) in
            let db: SQLiteDB
            do {
                db = try Schema.open()
            } catch {
                return (nil, "\(error)")
            }
            // Maintenance only makes the database faster — never fail startup over it.
            do {
                try Schema.ensureIndexes(db)
                try Schema.ensureFastSearchDeletes(db)
            } catch {
                Log.error("Database maintenance failed (continuing anyway): \(error)")
            }
            try? Store(db: db).resetStuckWork() // recover tasks stranded by a previous crash
            return (db, nil)
        }.value
        preparingDatabase = false

        guard let db = outcome.db else {
            let message = outcome.error ?? "unknown error"
            bootError = message
            Log.error("Database init failed: \(message)")
            return
        }
        self.db = db
        let store = Store(db: db)
        self.store = store

        let screenshot = ScreenshotService(store: store)
        let encoding = EncodingService(store: store)
        let ocr = OCRService(store: store)
        let transcription = TranscriptionService(store: store)
        let retention = RetentionService(store: store)
        let audio = AudioCaptureService()

        screenshotService = screenshot
        encodingService = encoding
        ocrService = ocr
        transcriptionService = transcription
        retentionService = retention
        audioService = audio

        audio.onChunk = { url, startDate, duration in
            do {
                try store.insertAudioChunk(
                    filename: url.lastPathComponent,
                    startedAt: startDate.timeIntervalSince1970.rounded(.down),
                    duration: duration)
            } catch {
                Log.error("Failed to record audio chunk \(url.lastPathComponent): \(error)")
            }
        }

        if Paths.whisperBinary == nil {
            Log.error("whisper binary not found — transcription disabled. Set KAZE_BIN_DIR or use the bundled app.")
        }

        // Same task table as the Electron app, plus the (previously missing) OCR task.
        scheduler.addTask("screenshot", interval: K.screenshotInterval) { await screenshot.capture() }
        scheduler.addTask("check-encoding", interval: K.encodingCheckInterval) { await encoding.checkFramesForEncoding() }
        scheduler.addTask("process-encoding", interval: K.encodingProcessInterval, requiredState: .lowPower) {
            await encoding.processEncodingTasks()
        }
        scheduler.addTask("delete-screenshots", interval: K.screenshotCleanupInterval) {
            await encoding.deleteUnnecessaryScreenshots()
        }
        scheduler.addTask("process-transcription", interval: K.transcriptionCheckInterval) {
            await transcription.processPendingChunks()
        }
        scheduler.addTask("process-ocr", interval: K.ocrInterval) { await ocr.processPendingFrames() }
        if !screenRecording {
            for id in screenTaskIDs { scheduler.pauseTask(id) }
            Log.info("Screen recording is off (persisted preference)")
        }
        scheduler.start()

        if audioRecording {
            await audio.start()
        } else {
            Log.info("Audio recording is off (default) — enable it from the menu bar or Settings")
        }

        // Phase 2: daily AI analysis. Independent of capture — runs even if the API key
        // isn't set yet (it just no-ops until one is added in Settings).
        // Set up before the retention sweep below, which asks it which days are analyzed.
        do {
            let analysis = try AnalysisService(store: store, frameExtractor: frameExtractor)
            self.analysis = analysis
            let analysisStore = analysis.analysisStore
            retention.hasDigest = { analysisStore.hasDigest(day: $0) }
            analysis.requestNotificationPermission()
            startAnalysisTimer()
        } catch {
            Log.error("Analysis service init failed: \(error)")
        }

        Task.detached(priority: .utility) { retention.cleanupOldRecordings() }

        isReady = true
        Log.info("Kaze started (native)")
    }

    /// Checks every 15 min whether yesterday's digest is due (past the configured hour and
    /// not yet generated). A menu-bar timer keeps this on the main actor with the service.
    private func startAnalysisTimer() {
        analysisTimer?.invalidate()
        let timer = Timer(timeInterval: K.analysisCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.analysis?.runDailyIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        analysisTimer = timer
        Task { await analysis?.runDailyIfDue() } // also check once at launch
    }

    // MARK: - Recording toggles (tray parity)

    func toggleScreenRecording() {
        if screenRecording {
            scheduler.pauseTask("screenshot")
            let encoding = encodingService
            Task.detached(priority: .utility) { await encoding?.flushPendingFrames() }
            for id in ["check-encoding", "process-encoding", "delete-screenshots"] {
                scheduler.pauseTask(id)
            }
        } else {
            for id in screenTaskIDs {
                scheduler.resumeTask(id)
            }
        }
        screenRecording.toggle()
        UserDefaults.standard.set(screenRecording, forKey: Self.screenPrefKey)
    }

    func toggleAudioRecording() {
        let audio = audioService
        if audioRecording {
            // Off-main: stop() can block on CoreAudio queues.
            Task.detached { audio?.stop() } // flushes the partial chunk; transcription keeps draining
        } else {
            Task { await audio?.start() }
        }
        audioRecording.toggle()
        UserDefaults.standard.set(audioRecording, forKey: Self.audioPrefKey)
    }

    // MARK: - Shutdown (will-quit parity: stop scheduler, stop audio, flush frames, retention, close DB)

    /// Called from applicationWillTerminate (main thread). The flush/retention work runs
    /// on a detached task — never on the main actor, which this method is blocking.
    func shutdownSync() {
        guard !didShutdown else { return }
        didShutdown = true
        Log.info("Shutting down…")

        analysisTimer?.invalidate()
        scheduler.stop()

        // All teardown runs off the main thread: audio stop can block on CoreAudio
        // queues, and the encoder awaits AVAssetWriter. The timeout guarantees exit.
        let audio = audioService
        let encoding = encodingService
        let retention = retentionService
        let db = db
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            audio?.stop() // flushes the partial audio chunk
            await encoding?.flushPendingFrames()
            retention?.cleanupOldRecordings()
            db?.close()
            Log.info("Shutdown complete")
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
    }
}
