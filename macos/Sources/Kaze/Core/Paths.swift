import Foundation

/// On-disk layout — identical to the Electron app so existing data carries over:
/// ~/Library/Application Support/Kaze/Record Data/{main.db, recordings/, audio/, logs/, temp/screenshots/}
enum Paths {
    static let dataDir: URL = {
        // $KAZE_DATA_DIR points the whole app at a different history — used to try changes
        // against a copy of a real recording set without risking the live one.
        if let override = ProcessInfo.processInfo.environment["KAZE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Kaze/Record Data", isDirectory: true)
    }()

    static var dbFile: URL { dataDir.appendingPathComponent("main.db") }
    static var recordingsDir: URL { dataDir.appendingPathComponent("recordings", isDirectory: true) }
    static var audioDir: URL { dataDir.appendingPathComponent("audio", isDirectory: true) }
    static var logsDir: URL { dataDir.appendingPathComponent("logs", isDirectory: true) }
    static var screenshotsDir: URL { dataDir.appendingPathComponent("temp/screenshots", isDirectory: true) }

    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [dataDir, recordingsDir, audioDir, logsDir, screenshotsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Directory holding the whisper binary and models.
    /// Resolution order: app bundle Resources/bin → $KAZE_BIN_DIR → repo bin/darwin-arm64 (dev runs).
    static let binDir: URL? = {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("bin", isDirectory: true)
            if fm.fileExists(atPath: bundled.appendingPathComponent("whisper").path) {
                return bundled
            }
        }
        if let env = ProcessInfo.processInfo.environment["KAZE_BIN_DIR"] {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            if fm.fileExists(atPath: url.path) { return url }
        }
        // Dev fallback: resolve relative to this source file (macos/Sources/Kaze/Core/ → repo root)
        let source = URL(fileURLWithPath: #filePath)
        let repoRoot = source
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Kaze
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repo root
        let devBin = repoRoot.appendingPathComponent("bin/darwin-arm64", isDirectory: true)
        if fm.fileExists(atPath: devBin.path) { return devBin }
        return nil
    }()

    static var whisperBinary: URL? { binDir?.appendingPathComponent("whisper") }
    static var whisperModel: URL? { binDir?.appendingPathComponent("models/ggml-base-q5_0.bin") }
}
