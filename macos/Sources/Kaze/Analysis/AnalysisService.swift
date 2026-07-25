import Foundation
import UserNotifications

/// Phase 2: the daily digest. Implements the source video's recipe —
/// compact a day's screen text + audio → cheap model summarizes and flags repeated
/// low-value behaviors → observations ledger → confirm a pattern after N days → surface
/// concrete optimizations in a morning notification.
@MainActor
final class AnalysisService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRunDay: String?
    /// Set while a multi-day backfill is walking a week, e.g. "Analyzing 2026-07-18 (2 of 5)…".
    @Published private(set) var batchProgress: String?

    private let store: Store
    let analysisStore: AnalysisStore
    private let compactor: DayCompactor
    private let frameExtractor: FrameExtractor

    init(store: Store, frameExtractor: FrameExtractor) throws {
        self.store = store
        self.analysisStore = try AnalysisStore()
        self.compactor = DayCompactor(store: store)
        self.frameExtractor = frameExtractor
    }

    // MARK: - Scheduling

    /// Called on a timer. Generates yesterday's digest once it's past the configured hour
    /// and the digest doesn't already exist. Idempotent.
    func runDailyIfDue() async {
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) else { return }
        let label = DayCompactor.dayBounds(yesterday).label
        let hour = cal.component(.hour, from: Date())

        guard hour >= K.analysisHour else { return }
        guard !analysisStore.hasDigest(day: label) else { return }
        await analyze(date: yesterday, notify: true)
    }

    // MARK: - Analysis

    struct DryRunResult {
        let day: String
        let promptChars: Int
        let approxTokens: Int
        let segments: Int
        let ambiguousSegments: Int
        let frames: Int
        let preview: String
    }

    /// Compacting a day reads all of its OCR text and then runs CPU-bound segmentation over
    /// it — seconds of work. This service is `@MainActor`, so it has to be pushed off
    /// explicitly; otherwise the 15-minute timer freezes the app with no window even open.
    private func compacted(for date: Date) async throws -> DayCompactor.DayData {
        let compactor = self.compactor
        return try await Task.detached(priority: .userInitiated) {
            try compactor.compact(for: date)
        }.value
    }

    /// Builds the compacted prompt without calling the API — lets you inspect volume/cost.
    func dryRun(date: Date) async throws -> DryRunResult {
        let data = try await compacted(for: date)
        let prompt = DayCompactor.renderPrompt(data)
        return DryRunResult(
            day: data.day, promptChars: prompt.count, approxTokens: prompt.count / 4,
            segments: data.segments.count,
            ambiguousSegments: data.segments.filter(\.isAmbiguous).count,
            frames: data.frameCount,
            preview: String(prompt.prefix(1200)))
    }

    @discardableResult
    func analyze(date: Date, notify: Bool) async -> DailyDigest? {
        guard !isRunning else { return nil }
        isRunning = true
        lastError = nil
        defer { isRunning = false }

        guard let active = LLMSettings.makeActiveProvider() else {
            lastError = "No API key set for \(LLMSettings.activeProvider.displayName) (Settings → AI Analysis)."
            return nil
        }

        do {
            let data = try await compacted(for: date)
            guard !data.segments.isEmpty else {
                lastError = "No recorded activity for \(data.day)."
                return nil
            }

            // Vision sampling: describe low-OCR/high-dwell screens; still-unclear ones
            // become questions for the user. Failures never abort the text analysis.
            let visuals = await sampleVision(data: data, provider: active.provider)

            let system = Self.systemPrompt(
                ledger: analysisStore.ledgerContext(),
                userExplanations: analysisStore.answersContext(),
                resolutions: analysisStore.resolutionsContext())
            let user = DayCompactor.renderPrompt(data, visuals: visuals)

            let jsonText = try await active.provider.completeJSON(
                system: system, user: user, schema: Self.outputSchema)

            guard let jsonData = jsonText.data(using: .utf8) else {
                lastError = "Model returned unreadable output."
                return nil
            }
            let analysis = try JSONDecoder().decode(DailyAnalysis.self, from: jsonData)

            var newlyConfirmed = try analysisStore.mergeObservations(analysis.observations, day: data.day)

            // A behavior just crossed the confirmation threshold — draft how to actually fix
            // it (script/Shortcut/snippet/process change), not just the one-line suggestion.
            // Never applied automatically; only ever written for the user to review.
            if !newlyConfirmed.isEmpty {
                await generateImplementations(for: newlyConfirmed, provider: active.provider)
                newlyConfirmed = newlyConfirmed.map { analysisStore.observation(id: $0.id) ?? $0 }
            }

            try analysisStore.saveDigest(
                day: data.day, summary: analysis.daySummary,
                focusAreas: analysis.focusAreas,
                newlyConfirmedKeys: newlyConfirmed.map(\.key))

            lastRunDay = data.day
            let digest = DailyDigest(
                id: 0, day: data.day, createdAt: Date().timeIntervalSince1970,
                summary: analysis.daySummary, focusAreas: analysis.focusAreas,
                newlyConfirmed: newlyConfirmed)

            // Obsidian journal export (one-way; failures never abort the analysis).
            if JournalExporter.isEnabled {
                do {
                    let urls = try JournalExporter.export(
                        digest: digest,
                        allObservations: analysisStore.allObservations(),
                        dayQuestions: analysisStore.questions(day: data.day))
                    Log.info("Journal: exported \(urls.count) file(s) to Obsidian")
                } catch {
                    Log.error("Journal export failed: \(error)")
                }
            }

            // Machine-readable feed for other systems (also one-way, also non-fatal).
            // Rewritten in full, so it picks up the day just stored along with any earlier
            // day that has since been re-analyzed.
            if FeedExporter.isEnabled {
                do {
                    let urls = try FeedExporter.export(store: analysisStore)
                    Log.info("Feed: wrote \(urls.count) file(s)")
                } catch {
                    Log.error("Feed export failed: \(error)")
                }
            }

            if notify {
                postNotification(for: digest)
            }
            Log.info("Analysis complete for \(data.day): \(analysis.observations.count) observations, \(newlyConfirmed.count) newly confirmed")
            return digest
        } catch {
            lastError = "\(error)"
            Log.error("Analysis failed: \(error)")
            return nil
        }
    }

    // MARK: - Backfill by calendar week

    /// ISO-8601 weeks, in the local time zone — weeks start Monday and belong to the year
    /// containing their Thursday, which is why the year here is `yearForWeekOfYear` and not
    /// simply the calendar year.
    /// `.autoupdatingCurrent`, not `.current`: this is a `static let`, so a snapshot would
    /// freeze at first touch and stop agreeing with `DayLabel` and SQLite the moment the
    /// system time zone changed — and a menu-bar app runs for weeks at a time.
    static let isoCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    struct WeekBacklog: Identifiable {
        let year: Int
        let week: Int
        let pendingDays: [String]
        var label: String { String(format: "%d-W%02d", year, week) }
        var id: String { label }
    }

    /// The seven dates of an ISO week, Monday first. Empty if that week doesn't exist.
    ///
    /// `Calendar.date(from:)` normalizes rather than rejecting, so it happily answers for
    /// week 0, week 99, or week 53 of a 52-week year by rolling into a neighbouring year.
    /// Silently analyzing a different week than the caller asked for is worse than doing
    /// nothing, so the result is round-tripped and discarded if it doesn't match.
    static func days(inISOWeek year: Int, week: Int) -> [Date] {
        var components = DateComponents()
        components.yearForWeekOfYear = year
        components.weekOfYear = week
        components.weekday = isoCalendar.firstWeekday
        guard week >= 1, week <= 53, let start = isoCalendar.date(from: components),
              isoWeek(of: start) == (year, week)
        else { return [] }
        return (0..<7).compactMap { isoCalendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func isoWeek(of date: Date) -> (year: Int, week: Int) {
        (isoCalendar.component(.yearForWeekOfYear, from: date),
         isoCalendar.component(.weekOfYear, from: date))
    }

    /// ISO weeks that still hold recorded days with no digest, newest first.
    ///
    /// Today is never listed: analyzing a day that isn't over yet would store a digest for a
    /// partial day, and the nightly run skips any day that already has one — so the complete
    /// version would never be generated.
    func weeksNeedingAnalysis() async -> [WeekBacklog] {
        let recorded = await store.read { (try? $0.recordedDays()) ?? [] }
        let today = DayLabel.today

        var pendingByWeek: [String: (year: Int, week: Int, days: [String])] = [:]
        for day in recorded where day != today {
            guard !analysisStore.hasDigest(day: day),
                  let date = DayLabel.date(from: day) else { continue }
            let (year, week) = Self.isoWeek(of: date)
            let key = String(format: "%d-W%02d", year, week)
            pendingByWeek[key, default: (year, week, [])].days.append(day)
        }

        return pendingByWeek.values
            .map { WeekBacklog(year: $0.year, week: $0.week, pendingDays: $0.days.sorted()) }
            .sorted { ($0.year, $0.week) > ($1.year, $1.week) }
    }

    /// Analyzes every day of an ISO week that has activity and no digest yet, oldest first —
    /// the ledger's "seen on N distinct days" rule reads days in order, so backfilling out of
    /// order would confirm patterns on the wrong date.
    @discardableResult
    func analyzeWeek(year: Int, week: Int) async -> [String] {
        let recorded = Set(await store.read { (try? $0.recordedDays()) ?? [] })
        let today = DayLabel.today
        let candidates = Self.days(inISOWeek: year, week: week)
            .map { (date: $0, label: DayLabel.string(from: $0)) }
            .filter { recorded.contains($0.label) && $0.label != today && !analysisStore.hasDigest(day: $0.label) }

        guard !candidates.isEmpty else { return [] }
        var analyzed: [String] = []
        var consecutiveFailures = 0
        defer { batchProgress = nil } // never leave the banner stuck if this is cancelled

        for (index, candidate) in candidates.enumerated() {
            batchProgress = "Analyzing \(candidate.label) (\(index + 1) of \(candidates.count))…"
            if await analyze(date: candidate.date, notify: false) != nil {
                analyzed.append(candidate.label)
                consecutiveFailures = 0
                continue
            }
            // A single failure is usually specific to that day — most often "No recorded
            // activity", when the day's frames were captured but never OCR'd. Keep going.
            // Two in a row means something global (no key, no credit, provider down), and
            // each further attempt costs a full day compaction before it fails.
            consecutiveFailures += 1
            if consecutiveFailures >= 2 {
                Log.info("Week backfill: stopping after 2 consecutive failures — \(lastError ?? "unknown")")
                break
            }
        }
        Log.info("Week backfill \(String(format: "%d-W%02d", year, week)): analyzed \(analyzed.count) of \(candidates.count) day(s)")
        return analyzed
    }

    // MARK: - Vision sampling

    private struct VisionOutput: Codable {
        struct Item: Codable {
            let index: Int
            let description: String
            let unclear: Bool
        }
        let descriptions: [Item]
    }

    /// Sends the day's most ambiguous screens (long dwell, little OCR text) to the active
    /// provider as images. Returns frameID → description for the timeline prompt; screens
    /// the model flags as unclear are queued as questions for the user. If the vision call
    /// fails entirely, the top few ambiguous segments become questions instead.
    private func sampleVision(data: DayCompactor.DayData, provider: LLMProvider) async -> [Int64: String] {
        let ambiguous = data.segments.filter(\.isAmbiguous)
            .sorted { $0.durationSeconds > $1.durationSeconds }
            .prefix(K.visionSampleLimit)
        guard !ambiguous.isEmpty else { return [:] }

        // Export a downscaled JPEG per segment (frame may be a PNG or inside a video).
        var sampled: [(segment: ActivitySegment, frameID: Int64, jpeg: Data)] = []
        for seg in ambiguous {
            guard let fid = seg.representativeFrameID,
                  let frame = await store.read({ try? $0.frameByID(fid) }) ?? nil,
                  let jpeg = await FrameJPEG.data(for: frame, extractor: frameExtractor)
            else { continue }
            sampled.append((seg, fid, jpeg))
        }
        guard !sampled.isEmpty else { return [:] }
        Log.info("Vision sampling: \(sampled.count) ambiguous segments for \(data.day)")

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let userText = """
        These are \(sampled.count) screenshots from a person's workday, numbered in order. \
        Each showed little readable text, so describe what activity is shown from the visual \
        layout. Times: \(sampled.enumerated().map { "image \($0.offset + 1) at \(timeFmt.string(from: $0.element.segment.start))" }.joined(separator: ", ")).
        """

        do {
            let jsonText = try await provider.completeJSON(
                system: Self.visionSystemPrompt, user: userText,
                images: sampled.map(\.jpeg), schema: Self.visionSchema)
            guard let jsonData = jsonText.data(using: .utf8) else { return [:] }
            let output = try JSONDecoder().decode(VisionOutput.self, from: jsonData)

            var visuals: [Int64: String] = [:]
            var questionsQueued = 0
            for item in output.descriptions {
                let idx = item.index - 1
                guard sampled.indices.contains(idx) else { continue }
                let (seg, fid, _) = sampled[idx]
                if item.unclear {
                    if questionsQueued < K.maxQuestionsPerDay {
                        analysisStore.addQuestion(
                            day: data.day, ts: seg.start.timeIntervalSince1970,
                            duration: seg.durationSeconds, frameID: fid,
                            hint: item.description.isEmpty ? nil : item.description)
                        questionsQueued += 1
                    }
                } else if !item.description.isEmpty {
                    visuals[fid] = item.description
                }
            }
            if questionsQueued > 0 {
                Log.info("Vision sampling: \(questionsQueued) segments queued as user questions")
            }
            return visuals
        } catch {
            Log.error("Vision sampling failed (\(error)) — queueing top segments as questions")
            for (seg, fid, _) in sampled.prefix(K.maxQuestionsPerDay) {
                analysisStore.addQuestion(
                    day: data.day, ts: seg.start.timeIntervalSince1970,
                    duration: seg.durationSeconds, frameID: fid, hint: nil)
            }
            return [:]
        }
    }

    // MARK: - Implementation drafting

    private struct ImplementationOutput: Codable {
        struct Item: Codable {
            let index: Int
            let toolCategory: String
            let implementation: String
            let caveat: String

            enum CodingKeys: String, CodingKey {
                case index, implementation, caveat
                case toolCategory = "tool_category"
            }
        }
        let implementations: [Item]
    }

    /// Drafts a concrete, ready-to-use implementation for each observation (a script, a
    /// Shortcut's steps, an editor snippet, a process change — whatever fits) and persists it.
    /// This is a draft only: nothing here is ever run or applied automatically, it's written
    /// for the user to review in Insights/the Obsidian journal and adopt by hand.
    func generateImplementations(for observations: [LedgerObservation], provider: LLMProvider) async {
        guard !observations.isEmpty else { return }
        do {
            let user = Self.implementationUserPrompt(observations)
            let jsonText = try await provider.completeJSON(
                system: Self.implementationSystemPrompt, user: user, schema: Self.implementationSchema)
            guard let jsonData = jsonText.data(using: .utf8) else { return }
            let output = try JSONDecoder().decode(ImplementationOutput.self, from: jsonData)
            for item in output.implementations {
                let idx = item.index - 1
                guard observations.indices.contains(idx) else { continue }
                analysisStore.saveImplementation(
                    id: observations[idx].id, category: item.toolCategory,
                    implementation: item.implementation, caveat: item.caveat)
            }
            Log.info("Implementation drafts generated for \(output.implementations.count) confirmed behavior(s)")
        } catch {
            Log.error("Implementation generation failed: \(error)")
        }
    }

    /// Manual entry point for the Insights "Draft implementation" button — used to retrofit
    /// ledger entries confirmed before this feature existed, or to regenerate one on demand.
    @discardableResult
    func generateImplementation(for observation: LedgerObservation) async -> Bool {
        guard let active = LLMSettings.makeActiveProvider() else {
            lastError = "No API key set for \(LLMSettings.activeProvider.displayName) (Settings → AI Analysis)."
            return false
        }
        await generateImplementations(for: [observation], provider: active.provider)
        return true
    }

    private static func implementationUserPrompt(_ observations: [LedgerObservation]) -> String {
        observations.enumerated().map { i, obs in
            """
            \(i + 1). Behavior: \(obs.behavior)
               Category: \(obs.category)
               Evidence: \(obs.evidence)
               Existing one-line suggestion: \(obs.suggestion)
               Seen \(obs.daysSeen) distinct days, \(obs.totalFrequency) total occurrences.
            """
        }.joined(separator: "\n\n")
    }

    private static let implementationSystemPrompt = """
        For each confirmed repeated low-value behavior below, write a concrete, ready-to-use \
        implementation the person can adopt themselves — not just what to do, but exactly how. \
        Prefer a copy-pasteable artifact when the behavior is toolable: a shell alias/function, \
        the exact steps for a macOS Shortcut, an editor snippet or keybinding, a browser \
        bookmarklet, a Raycast/Alfred snippet, a launchd/cron job, or whatever else best fits \
        THIS behavior and evidence — pick whichever tool is most natural for it, do not force a \
        single format. If the behavior isn't something a tool can fix (a habit or process \
        issue), give a specific, concrete process change instead of generic advice.

        Ground the implementation in the evidence given — reference the actual apps/steps seen, \
        not a generic template. Set caveat to a short warning if the implementation touches \
        system settings, credentials, deletes data, or is otherwise risky to apply blindly; \
        leave it an empty string otherwise. This implementation will only ever be shown to the \
        person for their own review — never assume it will run automatically, and never write \
        it as though you are the one applying it.
        """

    private static let implementationSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "implementations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "index": ["type": "integer"],
                        "tool_category": ["type": "string"],
                        "implementation": ["type": "string"],
                        "caveat": ["type": "string"],
                    ],
                    "required": ["index", "tool_category", "implementation", "caveat"],
                ],
            ],
        ],
        "required": ["implementations"],
    ]

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { Log.info("Notification permission not granted") }
        }
    }

    private func postNotification(for digest: DailyDigest) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        if digest.newlyConfirmed.isEmpty {
            content.title = "Kaze digest for \(digest.day)"
            content.body = digest.summary
        } else {
            content.title = "Kaze found \(digest.newlyConfirmed.count) workflow optimization\(digest.newlyConfirmed.count == 1 ? "" : "s")"
            content.body = digest.newlyConfirmed.map(\.suggestion).prefix(2).joined(separator: "\n")
        }
        let open = analysisStore.openQuestions().count
        if open > 0 {
            content.body += "\n\(open) unclear activit\(open == 1 ? "y needs" : "ies need") your explanation — open Insights."
        }
        let recurring = analysisStore.allObservations().filter(\.stillRecurring).count
        if recurring > 0 {
            content.body += "\n\(recurring) adopted fix\(recurring == 1 ? " isn't" : "es aren't") holding — behavior seen again."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "kaze-digest-\(digest.day)", content: content, trigger: nil)
        center.add(request)
    }

    // MARK: - Prompt & schema

    private static func systemPrompt(ledger: String, userExplanations: String, resolutions: String) -> String {
        """
        You analyze one day of a knowledge worker's on-screen activity (OCR'd screen text \
        plus audio transcript excerpts) to find small, repeated inefficiencies worth automating. \
        Some timeline entries carry a [visual: …] annotation — a description of that screen \
        from a sampled screenshot, used where OCR couldn't read the content.

        Do two things:
        1. Write a short factual summary of what the person worked on that day (2–4 sentences).
        2. Identify repeated LOW-VALUE behaviors — patterns that recur and could be replaced \
        by a hotkey, script, browser extension, template, or a cheaper/faster tool. Examples: \
        opening the same set of pages in sequence every morning (a polling loop that could be a \
        digest), mousing through a menu when a shortcut exists, retyping the same boilerplate, \
        frequent context-switching between the same apps, or paying for a tool with a free local \
        equivalent. For each, give concrete evidence from the timeline and a specific suggested fix.

        Only report a behavior if the timeline actually shows it repeating. Do not invent \
        patterns. Prefer a few high-confidence observations over many speculative ones. If the \
        day shows nothing noteworthy, return an empty observations list.

        Known patterns already tracked from prior days (match against these where the same \
        behavior recurs, using the same wording so they merge):
        \(ledger)

        The user has explained some previously-unclear activities themselves. Trust these \
        explanations and use them to interpret similar screens:
        \(userExplanations)

        Decisions the user already made on past suggestions:
        \(resolutions)
        For ADOPTED items: if today's timeline still shows that behavior, report it again with \
        the SAME wording (so recurrence is tracked) — the fix isn't holding. For IGNORED items: \
        never repeat the same suggestion; the stated reason explains what was wrong with it. \
        Only report that behavior again if you can propose a materially different fix that \
        respects the reason.
        """
    }

    static let visionSystemPrompt = """
    You label screenshots from a personal activity tracker. For each numbered screenshot, \
    describe in one or two sentences what work or activity is shown — the application, the \
    task, the content. These screens had little machine-readable text, so rely on visual \
    layout, imagery, and any UI you recognize. If you genuinely cannot tell what the person \
    is doing, set unclear to true and describe whatever you can see.
    """

    static let visionSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "descriptions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "index": ["type": "integer"],
                        "description": ["type": "string"],
                        "unclear": ["type": "boolean"],
                    ],
                    "required": ["index", "description", "unclear"],
                ],
            ],
        ],
        "required": ["descriptions"],
    ]

    /// JSON schema for structured output. All objects use additionalProperties:false + required
    /// (structured-output requirement); no string/number constraints (unsupported).
    static let outputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "day_summary": ["type": "string"],
            "focus_areas": ["type": "array", "items": ["type": "string"]],
            "observations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "behavior": ["type": "string"],
                        "category": [
                            "type": "string",
                            "enum": ["polling-loop", "manual-repetition", "tool-cost",
                                     "context-switching", "menu-vs-hotkey", "other"],
                        ],
                        "evidence": ["type": "string"],
                        "frequency": ["type": "integer"],
                        "suggestion": ["type": "string"],
                    ],
                    "required": ["behavior", "category", "evidence", "frequency", "suggestion"],
                ],
            ],
        ],
        "required": ["day_summary", "focus_areas", "observations"],
    ]
}
