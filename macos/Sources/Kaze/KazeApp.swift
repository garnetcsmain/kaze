import SwiftUI
import AppKit

@main
struct KazeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra("Kaze", systemImage: "clock.arrow.circlepath") {
            menuContent
        }

        Window("Kaze", id: WindowID.rewind) {
            RewindView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)

        Window("Kaze Library", id: WindowID.library) {
            LibraryView()
                .environmentObject(state)
        }
        .defaultSize(width: 660, height: 620)
        .windowResizability(.contentSize)

        Window("Kaze Insights", id: WindowID.insights) {
            InsightsView()
                .environmentObject(state)
        }
        .defaultSize(width: 640, height: 680)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button("Search") { showWindow(WindowID.rewind) }
        Button("Library") { showWindow(WindowID.library) }
        Button("Insights") { showWindow(WindowID.insights) }
        Button("Run Daily Analysis Now") {
            Task { @MainActor in
                if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) {
                    await state.analysis?.analyze(date: yesterday, notify: true)
                }
            }
            showWindow(WindowID.insights)
        }
        Button("Settings…") {
            NSApp.setActivationPolicy(.regular)
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(state.screenRecording ? "Stop Screen Recording" : "Start Screen Recording") {
            state.toggleScreenRecording()
        }
        Button(state.audioRecording ? "Stop Audio Recording" : "Start Audio Recording") {
            state.toggleAudioRecording()
        }
        Divider()
        Button("Quit Kaze") { NSApp.terminate(nil) }
    }

    private func showWindow(_ id: String) {
        NSApp.setActivationPolicy(.regular) // show dock icon while a window is open
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum WindowID {
    static let rewind = "rewind"
    static let library = "library"
    static let insights = "insights"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app; dock icon appears with windows

        // Headless test/cron hooks (exercise the real pipeline without the UI):
        //   KAZE_ANALYZE_DRYRUN=1   → compact yesterday, print token estimate, exit
        //   KAZE_ANALYZE_RUN=1      → run the full daily analysis (needs API key), print, exit
        let env = ProcessInfo.processInfo.environment
        if env["KAZE_LEDGER_SELFTEST"] != nil {
            Task { @MainActor in Self.ledgerSelfTest() }
            return
        }
        if env["KAZE_PROVIDER_SELFTEST"] != nil {
            Task { @MainActor in Self.providerSelfTest() }
            return
        }
        if env["KAZE_JOURNAL_EXPORT"] != nil {
            Task { @MainActor in Self.runJournalExport(folderOverride: env["KAZE_JOURNAL_PATH"]) }
            return
        }
        if env["KAZE_ANALYZE_DRYRUN"] != nil || env["KAZE_ANALYZE_RUN"] != nil {
            Task { await Self.runHeadless(live: env["KAZE_ANALYZE_RUN"] != nil) }
            return
        }

        Task { await AppState.shared.bootstrap() }

        // Return to accessory mode when the last window closes (hideDock parity).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { closing in
            DispatchQueue.main.async {
                let visible = NSApp.windows.contains {
                    $0.isVisible && $0 !== closing.object as? NSWindow && $0.canBecomeKey
                        && !($0 is NSPanel)
                }
                if !visible {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.shutdownSync()
        }
    }

    /// Headless entry point for the analyzer — used by tests and cron. Prints to stdout
    /// and exits without ever showing UI or starting capture.
    @MainActor
    static func runHeadless(live: Bool) async {
        Paths.ensureDirectories()
        guard let db = try? Schema.open() else {
            print("ERROR: could not open database"); exit(1)
        }
        let store = Store(db: db)
        guard let service = try? AnalysisService(store: store, frameExtractor: FrameExtractor()) else {
            print("ERROR: could not init analysis service"); exit(1)
        }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        do {
            let dry = try service.dryRun(date: yesterday)
            print("DRYRUN day=\(dry.day) frames=\(dry.frames) segments=\(dry.segments) ambiguous=\(dry.ambiguousSegments) approxTokens=\(dry.approxTokens) chars=\(dry.promptChars)")
            print("----- prompt preview -----")
            print(dry.preview)
            print("--------------------------")

            // Exercise the vision-sampling image path (frame → JPEG) without any API call.
            let extractor = FrameExtractor()
            if let frame = try store.timeline(limit: 1).first {
                if let jpeg = await FrameJPEG.data(for: frame, extractor: extractor) {
                    print("VISION-EXPORT frame#\(frame.id): jpeg=\(jpeg.count / 1024)KB (max \(Int(K.visionMaxImageDimension))px)")
                } else {
                    print("VISION-EXPORT frame#\(frame.id): FAILED")
                }
            }
        } catch {
            print("DRYRUN failed: \(error)"); exit(1)
        }

        if live {
            let kind = LLMSettings.activeProvider
            print("Running live analysis (provider=\(kind.displayName), model=\(LLMSettings.model(for: kind)))…")
            if let digest = await service.analyze(date: yesterday, notify: false) {
                print("SUMMARY: \(digest.summary)")
                print("FOCUS: \(digest.focusAreas.joined(separator: ", "))")
                let obs = service.analysisStore.allObservations()
                print("LEDGER (\(obs.count)):")
                for o in obs { print("  [\(o.daysSeen)d\(o.confirmed ? " ✓" : "")] \(o.category): \(o.behavior) → \(o.suggestion)") }
            } else {
                print("ANALYZE failed: \(service.lastError ?? "unknown")")
            }
        }
        exit(0)
    }

    /// Verifies the real AnalysisStore code: ledger merge + 3-day confirmation, and the
    /// question queue (dedupe → answer → context). Runs against a throwaway DB.
    @MainActor
    static func ledgerSelfTest() {
        Paths.ensureDirectories()
        let tmp = Paths.dataDir.appendingPathComponent("analysis-selftest.db")
        try? FileManager.default.removeItem(at: tmp)
        func cleanupAndExit(_ code: Int32) -> Never {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: tmp.path + suffix))
            }
            exit(code)
        }
        guard let store = try? AnalysisStore(path: tmp) else { print("FAIL: store init"); cleanupAndExit(1) }
        var ok = true

        // 1. Ledger: same behavior merged across 3 days → confirmed exactly on day 3.
        let obs = DailyAnalysis.Observation(
            behavior: "Cycles through the same 6 web pages every morning",
            category: "polling-loop", evidence: "test", frequency: 3,
            suggestion: "Build a morning digest instead")
        for day in 1...3 {
            let newly = (try? store.mergeObservations([obs], day: "day\(day)")) ?? []
            let entry = store.allObservations().first
            print("day \(day): daysSeen=\(entry?.daysSeen ?? 0) confirmed=\(entry?.confirmed ?? false) newlyConfirmed=\(newly.count)")
            if day < 3 && (entry?.confirmed ?? true) { ok = false }
            if day == 3 && (newly.count != 1 || entry?.confirmed != true) { ok = false }
        }

        // 2. Questions: dedupe by (day, ts), answer flow, answers feed the prompt context.
        store.addQuestion(day: "day1", ts: 1000, duration: 300, frameID: nil, hint: "maybe a design tool")
        store.addQuestion(day: "day1", ts: 1000, duration: 300, frameID: nil, hint: "duplicate")
        let open = store.openQuestions()
        print("questions: open=\(open.count) (expect 1, deduped)")
        if open.count != 1 { ok = false }
        if let q = open.first {
            store.answerQuestion(q.id, answer: "I was editing photos in Pixelmator")
            let after = store.openQuestions()
            let ctx = store.answersContext()
            print("after answer: open=\(after.count) contextHasAnswer=\(ctx.contains("Pixelmator"))")
            if !after.isEmpty || !ctx.contains("Pixelmator") { ok = false }
        }

        // 3. Implementation drafts: save + read back by id, never touching confirmed/dismissed.
        if let confirmedID = store.allObservations().first(where: { $0.confirmed })?.id {
            store.saveImplementation(id: confirmedID, category: "shell",
                                      implementation: "alias test='echo hi'", caveat: "")
            let reloaded = store.observation(id: confirmedID)
            print("implementation: category=\(reloaded?.implementationCategory ?? "nil") caveat=\(reloaded?.implementationCaveat ?? "(empty)")")
            if reloaded?.implementation != "alias test='echo hi'" || reloaded?.implementationCategory != "shell" { ok = false }
            if reloaded?.implementationCaveat != nil { ok = false }
        } else {
            print("FAIL: no confirmed observation to attach an implementation to")
            ok = false
        }

        // 4. Resolutions: adopt → no recurrence within grace; recurrence after grace flags
        //    the fix as not holding; ignore-with-reason lands in the prompt context.
        if let id = store.allObservations().first(where: { $0.confirmed })?.id {
            store.setResolution(id, resolution: "adopted", reason: nil)
            let fresh = store.observation(id: id)?.stillRecurring ?? true
            // Backdate the adoption past the grace window, then merge a new sighting.
            _ = try? store.db.execute("UPDATE observation SET resolutionAt = ? WHERE id = ?",
                                      [Date().timeIntervalSince1970 - 3 * 86400, id])
            _ = try? store.mergeObservations([obs], day: "day4")
            let recurring = store.observation(id: id)?.stillRecurring ?? false
            let adoptedCtx = store.resolutionsContext().contains("ADOPTED")
            print("resolution: freshRecurring=\(fresh) (expect false) recurringAfterGrace=\(recurring) (expect true) contextHasAdopted=\(adoptedCtx)")
            if fresh || !recurring || !adoptedCtx { ok = false }

            store.setResolution(id, resolution: "ignored", reason: "too fiddly to maintain")
            let ignoredCtx = store.resolutionsContext()
            print("resolution: contextHasIgnoredReason=\(ignoredCtx.contains("too fiddly to maintain"))")
            if !ignoredCtx.contains("too fiddly to maintain") { ok = false }
            store.setResolution(id, resolution: nil, reason: nil)
            if store.observation(id: id)?.resolution != nil { ok = false }
        } else {
            print("FAIL: no confirmed observation for resolution test")
            ok = false
        }

        print(ok ? "PASS: ledger + questions + implementation + resolutions OK" : "FAIL")
        cleanupAndExit(ok ? 0 : 1)
    }

    /// Verifies the multi-provider plumbing without any live API call: Gemini schema
    /// translation, per-provider Keychain round-trip, and active-provider selection.
    @MainActor
    static func providerSelfTest() {
        var ok = true

        // 1. Gemini schema translation: types uppercased, additionalProperties dropped.
        let gem = SchemaTranslator.toGemini(AnalysisService.outputSchema)
        let rootType = gem["type"] as? String
        let hasAdditional = gem["additionalProperties"] != nil
        let obsItems = ((gem["properties"] as? [String: Any])?["observations"] as? [String: Any])?["items"] as? [String: Any]
        let catType = ((obsItems?["properties"] as? [String: Any])?["category"] as? [String: Any])?["type"] as? String
        let catEnum = ((obsItems?["properties"] as? [String: Any])?["category"] as? [String: Any])?["enum"] as? [String]
        print("gemini schema: rootType=\(rootType ?? "nil") additionalPropertiesDropped=\(!hasAdditional) category.type=\(catType ?? "nil") enumCount=\(catEnum?.count ?? 0)")
        if rootType != "OBJECT" || hasAdditional || catType != "STRING" || (catEnum?.isEmpty ?? true) { ok = false }

        // 2. Keychain round-trip per provider (uses a sentinel value, then clears).
        for kind in LLMProviderKind.allCases {
            let had = APIKeyStore.hasKey(for: kind)
            if had && ProcessInfo.processInfo.environment[kind.envVars.first ?? ""] == nil {
                print("\(kind.rawValue): key already present, skipping round-trip")
                continue
            }
            let sentinel = "test-\(kind.rawValue)-key"
            APIKeyStore.save(sentinel, for: kind)
            let read = APIKeyStore.key(for: kind)
            let match = read == sentinel
            APIKeyStore.clear(for: kind)
            let cleared = APIKeyStore.key(for: kind) == nil
            print("\(kind.rawValue): saved+read=\(match) cleared=\(cleared) defaultModel=\(kind.defaultModel)")
            if !match || !cleared { ok = false }
        }

        // 3. Active provider + model resolution.
        print("activeProvider=\(LLMSettings.activeProvider.rawValue) model=\(LLMSettings.model(for: LLMSettings.activeProvider))")
        print(ok ? "PASS: provider plumbing OK" : "FAIL")
        exit(ok ? 0 : 1)
    }

    /// Headless Obsidian-journal backfill — KAZE_JOURNAL_EXPORT=1, optional
    /// KAZE_JOURNAL_PATH to override the configured folder. Prints written paths, exits.
    @MainActor
    static func runJournalExport(folderOverride: String?) {
        Paths.ensureDirectories()
        guard let store = try? AnalysisStore() else {
            print("ERROR: could not open analysis.db"); exit(1)
        }
        do {
            let urls = try JournalExporter.backfill(store: store, folderOverride: folderOverride)
            print("JOURNAL exported \(urls.count) file(s):")
            for url in urls { print("  \(url.path)") }
            exit(0)
        } catch {
            print("JOURNAL export failed: \(error)")
            exit(1)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // windows close; the app lives in the menu bar
    }
}
