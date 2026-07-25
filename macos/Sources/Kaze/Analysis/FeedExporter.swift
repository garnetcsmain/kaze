import Foundation

/// Machine-readable export of the analysis output, for feeding another system — a second
/// brain, an indexer, a notebook. Separate from `JournalExporter`, which writes prose for a
/// human reading an Obsidian vault: this one is stable, parseable, and carries no emoji,
/// frontmatter or Markdown.
///
/// Two newline-delimited JSON files, each line a complete record:
///  - `kaze-insights.jsonl`     — one record per analyzed day
///  - `kaze-observations.jsonl` — one record per ledger observation, as it currently stands
///
/// Both are rewritten in full on every export rather than appended to. Days get re-analyzed
/// and observations accumulate days-seen and adopt/ignore decisions, so appending would
/// leave a consumer to reconcile several versions of the same record. A full rewrite keeps
/// the file a straight snapshot: one line per day, one line per observation, no duplicates.
/// At a year of history that is a few hundred lines, so the cost is irrelevant.
enum FeedExporter {
    private static let enabledKey = "kaze.feed.enabled"
    private static let pathKey = "kaze.feed.path"

    static let insightsFilename = "kaze-insights.jsonl"
    static let observationsFilename = "kaze-observations.jsonl"
    static let questionsFilename = "kaze-questions.jsonl"

    /// Bumped whenever a field changes meaning, so a consumer can branch on it.
    static let schemaVersion = 1

    // MARK: - Settings

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var path: String? {
        get {
            let v = UserDefaults.standard.string(forKey: pathKey)
            return (v?.isEmpty == false) ? v : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: pathKey) }
    }

    // MARK: - Records

    /// One analyzed day. `newlyConfirmedKeys` holds keys rather than embedded records: the
    /// ledger keeps mutating (days seen, adopt/ignore, drafted implementation), so copying
    /// observations in here would publish a second, silently-drifting version of each one.
    /// Join against the observations file on `key`.
    ///
    /// `generatedAt` advances whenever a day is re-analyzed, so a consumer can tell a record
    /// has been revised.
    struct DayRecord: Codable {
        let schema: Int
        let type: String
        let day: String            // "YYYY-MM-DD", local
        let generatedAt: String    // ISO 8601
        let summary: String
        let focusAreas: [String]
        let newlyConfirmedKeys: [String]
    }

    struct ObservationRecord: Codable {
        let schema: Int
        let type: String
        let key: String            // stable across days — use it to merge on the consumer side
        let behavior: String
        let category: String
        let suggestion: String
        let evidence: String
        let daysSeen: Int
        let totalFrequency: Int
        let firstSeen: String      // ISO 8601
        let lastSeen: String
        let confirmed: Bool
        /// Hidden in the UI. Still exported, as a tombstone — a consumer that already
        /// ingested this behavior needs to be told it was retracted, not just stop seeing it.
        let dismissed: Bool
        let resolution: String?    // "adopted" | "ignored" | null
        let resolutionReason: String?
        let resolutionAt: String?  // ISO 8601
        /// Adopted, yet still showing up in analyses run after the grace window — the fix
        /// isn't holding.
        let stillRecurring: Bool
        let implementation: String?
        let implementationCategory: String?
        let implementationCaveat: String?
    }

    /// An activity neither OCR nor vision could identify, with the user's explanation if
    /// they gave one. Answered questions are the highest-signal records in the feed — they
    /// are the user's own words about what they were doing.
    struct QuestionRecord: Codable {
        let schema: Int
        let type: String
        let day: String            // "YYYY-MM-DD", local
        let at: String             // ISO 8601
        let durationMinutes: Int
        let hint: String?
        let answer: String?
        let answeredAt: String?    // ISO 8601
    }

    // MARK: - Export

    /// Writes both files. `folderOverride` bypasses the stored setting (headless hook, tests).
    @discardableResult
    static func export(store: AnalysisStore, folderOverride: String? = nil) throws -> [URL] {
        guard let folder = folderOverride ?? path else {
            throw NSError(domain: K.bundleID, code: 31,
                          userInfo: [NSLocalizedDescriptionKey: "No feed folder configured"])
        }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // stable diffs, so re-export is a no-op in git

        // No limit. These files are a full snapshot, not an append log, so a cap wouldn't
        // trim old records — it would delete them from a consumer treating this as truth.
        // Oldest first: reading top-to-bottom gives chronological order.
        let digests = store.recentDigests(limit: .max).sorted { $0.day < $1.day }
        let dayLines = try digests.map { digest in
            try line(DayRecord(
                schema: schemaVersion,
                type: "day",
                day: digest.day,
                generatedAt: iso(digest.createdAt),
                summary: digest.summary,
                focusAreas: digest.focusAreas,
                newlyConfirmedKeys: digest.newlyConfirmed.map(\.key)), encoder)
        }

        // Dismissed entries included on purpose — see ObservationRecord.dismissed.
        let observations = store.allObservations(includeDismissed: true)
            .sorted { $0.lastSeen < $1.lastSeen }
        let observationLines = try observations.map { try line(observationRecord($0), encoder) }

        let questionLines = try store.allQuestions().map { question in
            try line(QuestionRecord(
                schema: schemaVersion,
                type: "question",
                day: question.day,
                at: iso(question.ts),
                durationMinutes: Int(question.durationSeconds / 60),
                hint: question.hint,
                answer: question.answer,
                answeredAt: question.answeredAt.map(iso)), encoder)
        }

        let insightsURL = dir.appendingPathComponent(insightsFilename)
        let observationsURL = dir.appendingPathComponent(observationsFilename)
        let questionsURL = dir.appendingPathComponent(questionsFilename)
        try write(dayLines, to: insightsURL)
        try write(observationLines, to: observationsURL)
        try write(questionLines, to: questionsURL)
        Log.info("Feed: \(dayLines.count) day(s), \(observationLines.count) observation(s), \(questionLines.count) question(s) -> \(dir.path)")
        return [insightsURL, observationsURL, questionsURL]
    }

    // MARK: - Helpers

    private static func observationRecord(_ obs: LedgerObservation) -> ObservationRecord {
        ObservationRecord(
            schema: schemaVersion,
            type: "observation",
            key: obs.key,
            behavior: obs.behavior,
            category: obs.category,
            suggestion: obs.suggestion,
            evidence: obs.evidence,
            daysSeen: obs.daysSeen,
            totalFrequency: obs.totalFrequency,
            firstSeen: iso(obs.firstSeen),
            lastSeen: iso(obs.lastSeen),
            confirmed: obs.confirmed,
            dismissed: obs.dismissed,
            resolution: obs.resolution,
            resolutionReason: obs.resolutionReason,
            resolutionAt: obs.resolutionAt.map(iso),
            stillRecurring: obs.stillRecurring,
            implementation: obs.implementation,
            implementationCategory: obs.implementationCategory,
            implementationCaveat: obs.implementationCaveat)
    }

    private static func line(_ value: some Encodable, _ encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(value)
        // JSONEncoder never emits raw newlines inside a value, so one record is one line.
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ lines: [String], to url: URL) throws {
        // Trailing newline: standard for JSONL, and makes `cat`/append-from-outside behave.
        let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func iso(_ timestamp: Double) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
