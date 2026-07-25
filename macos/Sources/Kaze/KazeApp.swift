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
        if env["KAZE_WEEK_SELFTEST"] != nil {
            Task { @MainActor in Self.weekSelfTest() }
            return
        }
        if env["KAZE_FEED_EXPORT"] != nil {
            Task { @MainActor in Self.runFeedExport(folderOverride: env["KAZE_FEED_PATH"]) }
            return
        }
        if let week = env["KAZE_ANALYZE_WEEK"] {
            Task { await Self.runWeekBackfill(week) }
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
        // Same one-time maintenance the app does at startup.
        try? Schema.ensureIndexes(db)
        try? Schema.ensureFastSearchDeletes(db)
        let store = Store(db: db)
        guard let service = try? AnalysisService(store: store, frameExtractor: FrameExtractor()) else {
            print("ERROR: could not init analysis service"); exit(1)
        }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        do {
            let dry = try await service.dryRun(date: yesterday)
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

        // 1b. Re-analyzing a day that was already merged must not inflate daysSeen. Week
        //     backfill and "Analyze today so far" both re-merge days, and an inflated count
        //     would confirm a behavior that was never seen on three distinct days.
        let beforeRemerge = store.allObservations().first?.daysSeen ?? 0
        _ = try? store.mergeObservations([obs], day: "day3")
        let afterRemerge = store.allObservations().first?.daysSeen ?? 0
        print("re-merge of day3: daysSeen \(beforeRemerge) -> \(afterRemerge) (expect unchanged at 3)")
        if afterRemerge != 3 { ok = false }

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

    /// Verifies the ISO-week math the week backfill depends on, and the one invariant that
    /// silently breaks it: `DayLabel` must produce exactly the string SQLite's
    /// `date(createdAt,'unixepoch','localtime')` produces, or `recordedDays()` never matches
    /// and backfill reports nothing to do.
    @MainActor
    static func weekSelfTest() {
        var ok = true

        // ISO weeks disagree with calendar years at both ends: week 1 can start in December,
        // Dec 29-31 can belong to the next year's week 1, and some years have 53 weeks.
        for (year, weeks) in [(2020, 53), (2024, 52), (2025, 52), (2026, 53)] {
            for week in 1...weeks {
                let days = AnalysisService.days(inISOWeek: year, week: week)
                guard days.count == 7 else {
                    print("FAIL \(year)-W\(week): got \(days.count) days"); ok = false; continue
                }
                let weekday = AnalysisService.isoCalendar.component(.weekday, from: days[0])
                if weekday != 2 { // 1 = Sunday, so Monday is 2
                    print("FAIL \(year)-W\(week) starts on weekday \(weekday), expected Monday(2)"); ok = false
                }
                for day in days {
                    let (y, w) = AnalysisService.isoWeek(of: day)
                    if (y, w) != (year, week) {
                        print("FAIL \(DayLabel.string(from: day)) maps to \(y)-W\(w), expected \(year)-W\(week)")
                        ok = false
                    }
                }
            }
        }
        print("iso weeks: round-tripped 2020/2024/2025/2026, Monday-first, members consistent")

        // DayLabel vs SQLite, against the real recorded data.
        Paths.ensureDirectories()
        if let db = try? Schema.open() {
            let store = Store(db: db)
            let days = (try? store.recordedDays()) ?? []
            let rows = (try? store.db.query(
                "SELECT MIN(createdAt) AS lo, MAX(createdAt) AS hi FROM frame")) ?? []
            var mismatches = 0
            for stamp in [rows.first?.double("lo"), rows.first?.double("hi")].compactMap({ $0 }) {
                let fromSQL = ((try? store.db.query(
                    "SELECT date(?, 'unixepoch', 'localtime') AS d", [stamp])) ?? [])
                    .first?.string("d") ?? "?"
                let fromSwift = DayLabel.string(from: Date(timeIntervalSince1970: stamp))
                if fromSQL != fromSwift {
                    print("FAIL day label mismatch: sqlite=\(fromSQL) swift=\(fromSwift)")
                    mismatches += 1
                    ok = false
                }
            }
            // Every recorded day must parse back, or weeksNeedingAnalysis silently skips it.
            let unparseable = days.filter { DayLabel.date(from: $0) == nil }
            if !unparseable.isEmpty {
                print("FAIL \(unparseable.count) recorded day(s) unparseable, e.g. \(unparseable[0])")
                ok = false
            }
            print("day labels: \(days.count) recorded day(s), \(mismatches) sqlite/swift mismatch(es), \(unparseable.count) unparseable")
            db.close()
        } else {
            print("day labels: skipped (no database)")
        }

        print(ok ? "PASS: iso week + day label math OK" : "FAIL")
        exit(ok ? 0 : 1)
    }

    /// Headless JSONL feed export — KAZE_FEED_EXPORT=1, optional KAZE_FEED_PATH to override
    /// the configured folder. Reads analysis.db only; never calls the API.
    @MainActor
    static func runFeedExport(folderOverride: String?) {
        Paths.ensureDirectories()
        guard let store = try? AnalysisStore() else {
            print("ERROR: could not open analysis.db"); exit(1)
        }
        do {
            let urls = try FeedExporter.export(store: store, folderOverride: folderOverride)
            print("FEED wrote \(urls.count) file(s):")
            for url in urls {
                let records = (try? String(contentsOf: url, encoding: .utf8))?
                    .split(separator: "\n", omittingEmptySubsequences: true).count ?? 0
                print("  \(url.path) (\(records) record(s))")
            }
            exit(0)
        } catch {
            print("FEED export failed: \(error)")
            exit(1)
        }
    }

    /// Headless week backfill — KAZE_ANALYZE_WEEK=2026-W30. Analyzes every recorded day of
    /// that ISO week that has no digest yet (skipping today), then exports as usual.
    @MainActor
    static func runWeekBackfill(_ spec: String) async {
        // Strictly YYYY-Www. Calendar normalizes W0 / W99 / W53-of-a-52-week-year into a
        // neighbouring year instead of rejecting them, so a loose parser would silently
        // analyze a different week than the caller asked for.
        let parts = spec.uppercased().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 3, parts[1].hasPrefix("W"),
              parts[0].allSatisfy(\.isASCII), parts[1].dropFirst().allSatisfy(\.isASCII),
              let year = Int(parts[0]), let week = Int(parts[1].dropFirst())
        else {
            print("ERROR: expected KAZE_ANALYZE_WEEK=YYYY-Www (e.g. 2026-W30), got \"\(spec)\"")
            exit(1)
        }
        guard !AnalysisService.days(inISOWeek: year, week: week).isEmpty else {
            print("ERROR: \(spec) is not a real ISO week")
            exit(1)
        }

        Paths.ensureDirectories()
        guard let db = try? Schema.open() else {
            print("ERROR: could not open database"); exit(1)
        }
        try? Schema.ensureIndexes(db)
        try? Schema.ensureFastSearchDeletes(db)
        guard let service = try? AnalysisService(
            store: Store(db: db), frameExtractor: FrameExtractor())
        else {
            print("ERROR: could not init analysis service"); exit(1)
        }

        let analyzed = await service.analyzeWeek(year: year, week: week)
        if !analyzed.isEmpty {
            print("WEEK \(spec): analyzed \(analyzed.count) day(s): \(analyzed.joined(separator: ", "))")
            exit(0)
        }
        // Nothing analyzed is only success when there was nothing to do — a cron caller has
        // to be able to tell that apart from a bad key, a rate limit or a network failure.
        if let error = service.lastError {
            print("WEEK \(spec): failed — \(error)")
            exit(1)
        }
        print("WEEK \(spec): nothing to analyze (no recorded days without a digest)")
        exit(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // windows close; the app lives in the menu bar
    }
}
