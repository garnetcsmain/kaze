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

    /// Builds the compacted prompt without calling the API — lets you inspect volume/cost.
    func dryRun(date: Date) throws -> DryRunResult {
        let data = try compactor.compact(for: date)
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
            let data = try compactor.compact(for: date)
            guard !data.segments.isEmpty else {
                lastError = "No recorded activity for \(data.day)."
                return nil
            }

            // Vision sampling: describe low-OCR/high-dwell screens; still-unclear ones
            // become questions for the user. Failures never abort the text analysis.
            let visuals = await sampleVision(data: data, provider: active.provider)

            let system = Self.systemPrompt(
                ledger: analysisStore.ledgerContext(),
                userExplanations: analysisStore.answersContext())
            let user = DayCompactor.renderPrompt(data, visuals: visuals)

            let jsonText = try await active.provider.completeJSON(
                system: system, user: user, schema: Self.outputSchema)

            guard let jsonData = jsonText.data(using: .utf8) else {
                lastError = "Model returned unreadable output."
                return nil
            }
            let analysis = try JSONDecoder().decode(DailyAnalysis.self, from: jsonData)

            let newlyConfirmed = try analysisStore.mergeObservations(analysis.observations, day: data.day)
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
                  let frame = try? store.frameByID(fid),
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
        content.sound = .default
        let request = UNNotificationRequest(identifier: "kaze-digest-\(digest.day)", content: content, trigger: nil)
        center.add(request)
    }

    // MARK: - Prompt & schema

    private static func systemPrompt(ledger: String, userExplanations: String) -> String {
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
