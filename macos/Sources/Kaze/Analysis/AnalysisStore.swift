import Foundation

/// Persistent home for the observations ledger and daily digests.
/// Uses a SEPARATE analysis.db so the shared v4 main.db (also read by the Electron app)
/// is never modified. Cloud sync (phase 3) will push from these tables, not raw recordings.
final class AnalysisStore {
    let db: SQLiteDB

    static var dbFile: URL { Paths.dataDir.appendingPathComponent("analysis.db") }

    /// `path` is overridable so self-tests can run against a throwaway database.
    init(path: URL = AnalysisStore.dbFile) throws {
        db = try SQLiteDB(path: path.path)
        _ = try? db.execute("PRAGMA journal_mode=WAL")
        try createSchema()
    }

    private func createSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS observation (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                key TEXT UNIQUE NOT NULL,
                behavior TEXT NOT NULL,
                category TEXT,
                suggestion TEXT,
                evidence TEXT,
                daysSeen INTEGER DEFAULT 1,
                totalFrequency INTEGER DEFAULT 0,
                firstSeen REAL,
                lastSeen REAL,
                confirmed INTEGER DEFAULT 0,
                dismissed INTEGER DEFAULT 0,
                confirmedNotified INTEGER DEFAULT 0
            )
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS digest (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                day TEXT UNIQUE NOT NULL,
                createdAt REAL,
                summary TEXT,
                focusAreas TEXT,
                newlyConfirmed TEXT
            )
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS question (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                day TEXT NOT NULL,
                ts REAL NOT NULL,
                durationSeconds REAL,
                frameID INTEGER,
                hint TEXT,
                answer TEXT,
                answeredAt REAL,
                createdAt REAL,
                UNIQUE(day, ts)
            )
            """)
    }

    // MARK: - Digests

    func hasDigest(day: String) -> Bool {
        ((try? db.query("SELECT 1 FROM digest WHERE day = ?", [day]))?.isEmpty == false)
    }

    func recentDigests(limit: Int = 30) -> [DailyDigest] {
        let rows = (try? db.query(
            "SELECT * FROM digest ORDER BY day DESC LIMIT ?", [limit])) ?? []
        return rows.compactMap { row in
            guard let id = row.int("id"), let day = row.string("day") else { return nil }
            let focus = (row.string("focusAreas")).flatMap { decodeStrings($0) } ?? []
            let confirmedKeys = (row.string("newlyConfirmed")).flatMap { decodeStrings($0) } ?? []
            return DailyDigest(
                id: id, day: day, createdAt: row.double("createdAt") ?? 0,
                summary: row.string("summary") ?? "",
                focusAreas: focus, newlyConfirmed: observations(forKeys: confirmedKeys))
        }
    }

    /// Resolves ledger entries by their merge keys (used to rehydrate a digest's
    /// newly-confirmed list for display and journal export).
    func observations(forKeys keys: [String]) -> [LedgerObservation] {
        keys.compactMap { key in
            ((try? db.query("SELECT * FROM observation WHERE key = ?", [key])) ?? [])
                .first.flatMap(ledger(from:))
        }
    }

    func saveDigest(day: String, summary: String, focusAreas: [String], newlyConfirmedKeys: [String]) throws {
        let focusJSON = encodeStrings(focusAreas)
        let confirmedJSON = encodeStrings(newlyConfirmedKeys)
        try db.execute("""
            INSERT INTO digest (day, createdAt, summary, focusAreas, newlyConfirmed)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET
                createdAt=excluded.createdAt, summary=excluded.summary,
                focusAreas=excluded.focusAreas, newlyConfirmed=excluded.newlyConfirmed
            """, [day, Date().timeIntervalSince1970, summary, focusJSON, confirmedJSON])
    }

    // MARK: - Ledger

    /// Merges one day's observations into the ledger. Returns entries that crossed the
    /// confirmation threshold on THIS merge (the morning digest's "new suggestions").
    func mergeObservations(_ observations: [DailyAnalysis.Observation], day: String) throws -> [LedgerObservation] {
        let now = Date().timeIntervalSince1970
        var newlyConfirmed: [LedgerObservation] = []

        for obs in observations {
            let key = Self.normalize(obs.behavior)
            guard !key.isEmpty else { continue }

            let existing = try db.query("SELECT * FROM observation WHERE key = ?", [key]).first
            if let existing, let id = existing.int("id") {
                let wasConfirmed = (existing.int("confirmed") ?? 0) == 1
                let daysSeen = Int(existing.int("daysSeen") ?? 1) + 1
                let total = Int(existing.int("totalFrequency") ?? 0) + obs.frequency
                let confirmed = daysSeen >= K.observationConfirmThreshold
                try db.execute("""
                    UPDATE observation SET
                        behavior=?, category=?, suggestion=?, evidence=?,
                        daysSeen=?, totalFrequency=?, lastSeen=?, confirmed=?
                    WHERE id=?
                    """, [obs.behavior, obs.category, obs.suggestion, obs.evidence,
                          daysSeen, total, now, confirmed ? 1 : 0, id])
                if confirmed && !wasConfirmed {
                    if let row = try db.query("SELECT * FROM observation WHERE id = ?", [id]).first,
                       let led = ledger(from: row) {
                        newlyConfirmed.append(led)
                    }
                }
            } else {
                let confirmed = K.observationConfirmThreshold <= 1
                try db.execute("""
                    INSERT INTO observation
                        (key, behavior, category, suggestion, evidence, daysSeen, totalFrequency, firstSeen, lastSeen, confirmed)
                    VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
                    """, [key, obs.behavior, obs.category, obs.suggestion, obs.evidence,
                          obs.frequency, now, now, confirmed ? 1 : 0])
            }
        }
        return newlyConfirmed
    }

    func allObservations(includeDismissed: Bool = false) -> [LedgerObservation] {
        let sql = includeDismissed
            ? "SELECT * FROM observation ORDER BY confirmed DESC, daysSeen DESC, lastSeen DESC"
            : "SELECT * FROM observation WHERE dismissed = 0 ORDER BY confirmed DESC, daysSeen DESC, lastSeen DESC"
        return ((try? db.query(sql)) ?? []).compactMap(ledger(from:))
    }

    /// Compact context passed back to the model each day so it can match against, rather
    /// than re-derive, known patterns.
    func ledgerContext(limit: Int = 40) -> String {
        let rows = allObservations().prefix(limit)
        guard !rows.isEmpty else { return "(empty — no prior observations)" }
        return rows.map { o in
            "- [\(o.daysSeen)d\(o.confirmed ? ", confirmed" : "")] \(o.behavior)"
        }.joined(separator: "\n")
    }

    func setDismissed(_ id: Int64, _ dismissed: Bool) {
        _ = try? db.execute("UPDATE observation SET dismissed = ? WHERE id = ?", [dismissed ? 1 : 0, id])
    }

    private func ledger(from row: SQLRow) -> LedgerObservation? {
        guard let id = row.int("id"), let key = row.string("key"),
              let behavior = row.string("behavior") else { return nil }
        return LedgerObservation(
            id: id, key: key, behavior: behavior,
            category: row.string("category") ?? "",
            suggestion: row.string("suggestion") ?? "",
            evidence: row.string("evidence") ?? "",
            daysSeen: Int(row.int("daysSeen") ?? 1),
            totalFrequency: Int(row.int("totalFrequency") ?? 0),
            firstSeen: row.double("firstSeen") ?? 0,
            lastSeen: row.double("lastSeen") ?? 0,
            confirmed: (row.int("confirmed") ?? 0) == 1,
            dismissed: (row.int("dismissed") ?? 0) == 1)
    }

    // MARK: - Questions (unclear activity → ask the user)

    /// Queues an activity the pipeline couldn't identify. Deduped by (day, ts) so re-running
    /// a day's analysis never duplicates questions.
    func addQuestion(day: String, ts: Double, duration: Double, frameID: Int64?, hint: String?) {
        _ = try? db.execute("""
            INSERT OR IGNORE INTO question (day, ts, durationSeconds, frameID, hint, createdAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [day, ts, duration, frameID, hint, Date().timeIntervalSince1970])
    }

    func openQuestions(limit: Int = 20) -> [OpenQuestion] {
        ((try? db.query(
            "SELECT * FROM question WHERE answer IS NULL ORDER BY ts DESC LIMIT ?", [limit])) ?? [])
            .compactMap(question(from:))
    }

    /// All questions (answered and open) for one day — used by the journal export.
    func questions(day: String) -> [OpenQuestion] {
        ((try? db.query(
            "SELECT * FROM question WHERE day = ? ORDER BY ts", [day])) ?? [])
            .compactMap(question(from:))
    }

    func answerQuestion(_ id: Int64, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? db.execute("UPDATE question SET answer = ?, answeredAt = ? WHERE id = ?",
                            [trimmed, Date().timeIntervalSince1970, id])
    }

    func dismissQuestion(_ id: Int64) {
        _ = try? db.execute("DELETE FROM question WHERE id = ? AND answer IS NULL", [id])
    }

    /// Recent user explanations, injected into future analysis prompts so understanding
    /// accrues across days ("the idea is to have something after a few days").
    func answersContext(limit: Int = 20) -> String {
        let rows = (try? db.query("""
            SELECT day, ts, durationSeconds, answer FROM question
            WHERE answer IS NOT NULL ORDER BY answeredAt DESC LIMIT ?
            """, [limit])) ?? []
        guard !rows.isEmpty else { return "(none yet)" }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        return rows.compactMap { row -> String? in
            guard let day = row.string("day"), let ts = row.double("ts"),
                  let answer = row.string("answer") else { return nil }
            let mins = Int((row.double("durationSeconds") ?? 0) / 60)
            let time = timeFmt.string(from: Date(timeIntervalSince1970: ts))
            return "- [\(day) \(time), ~\(mins)m] \(answer)"
        }.joined(separator: "\n")
    }

    private func question(from row: SQLRow) -> OpenQuestion? {
        guard let id = row.int("id"), let day = row.string("day"), let ts = row.double("ts")
        else { return nil }
        return OpenQuestion(
            id: id, day: day, ts: ts,
            durationSeconds: row.double("durationSeconds") ?? 0,
            frameID: row.int("frameID"),
            hint: row.string("hint"),
            answer: row.string("answer"),
            answeredAt: row.double("answeredAt"))
    }

    // MARK: - Helpers

    /// Normalize a behavior string into a stable merge key (lowercased, alnum words only).
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let words = lowered.split { !$0.isLetter && !$0.isNumber }
        return words.prefix(12).joined(separator: " ")
    }

    private func encodeStrings(_ arr: [String]) -> String {
        (try? String(data: JSONEncoder().encode(arr), encoding: .utf8) ?? "[]") ?? "[]"
    }

    private func decodeStrings(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}
