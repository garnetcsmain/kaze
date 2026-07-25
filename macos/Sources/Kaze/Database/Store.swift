import Foundation

/// All application queries in one place. Replaces the Electron app's Hono HTTP API —
/// the UI and services call these directly instead of going through localhost.
final class Store {
    let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    private func frame(from row: SQLRow) -> Frame? {
        guard let id = row.int("id"), let createdAt = row.double("createdAt") else { return nil }
        return Frame(
            id: id,
            createdAt: createdAt,
            imgFilename: row.string("imgFilename"),
            videoPath: row.string("videoPath"),
            videoFrameIndex: row.int("videoFrameIndex"),
            encodeStatus: row.int("encodeStatus") ?? 0
        )
    }

    // MARK: - Frames / capture

    func insertFrame(createdAt: Double, imgFilename: String) throws {
        try db.execute("INSERT INTO frame (imgFilename, createdAt) VALUES (?, ?)", [imgFilename, createdAt])
    }

    func frameByID(_ id: Int64) throws -> Frame? {
        try db.query("SELECT * FROM frame WHERE id = ?", [id]).first.flatMap(frame(from:))
    }

    /// Timeline page, newest first (parity with GET /timeline).
    func timeline(limit: Int = 50, untilID: Int64? = nil) throws -> [Frame] {
        let rows: [SQLRow]
        if let untilID {
            rows = try db.query(
                "SELECT * FROM frame WHERE id < ? ORDER BY createdAt DESC LIMIT ?", [untilID, limit])
        } else {
            rows = try db.query("SELECT * FROM frame ORDER BY createdAt DESC LIMIT ?", [limit])
        }
        return rows.compactMap(frame(from:))
    }

    // MARK: - Encoding pipeline

    func pendingFramesForEncoding() throws -> [Frame] {
        try db.query(
            "SELECT * FROM frame WHERE encodeStatus = 0 AND imgFilename IS NOT NULL ORDER BY createdAt"
        ).compactMap(frame(from:))
    }

    func deleteFrame(_ id: Int64) throws {
        try db.execute("DELETE FROM frame WHERE id = ?", [id])
    }

    /// Creates an encoding task for the given frames and marks them queued.
    func createEncodingTask(frameIDs: [Int64]) throws -> Int64 {
        try db.transaction { exec, _ in
            _ = try exec("INSERT INTO encoding_task (status, createdAt) VALUES (0, ?)", [Date().timeIntervalSince1970])
            let taskID = self.dbLastInsertRowIDUnsafe()
            for frameID in frameIDs {
                _ = try exec("INSERT INTO encoding_task_data (encodingTaskID, frame) VALUES (?, ?)", [taskID, frameID])
                _ = try exec("UPDATE frame SET encodeStatus = 1 WHERE id = ?", [frameID])
            }
            return taskID
        }
    }

    // last_insert_rowid must be read inside the transaction; the C call is connection-scoped
    // and our transaction body runs on the connection's serial queue, so this is safe.
    private func dbLastInsertRowIDUnsafe() -> Int64 { db.lastInsertRowIDLocked() }

    func pendingEncodingTasks() throws -> [EncodingTaskRow] {
        try db.query("SELECT id FROM encoding_task WHERE status = 0 ORDER BY id").compactMap { row in
            row.int("id").map(EncodingTaskRow.init)
        }
    }

    func setEncodingTaskStatus(_ taskID: Int64, status: Int) throws {
        try db.execute("UPDATE encoding_task SET status = ? WHERE id = ?", [status, taskID])
    }

    /// Recover tasks stuck in status=1 after a crash (fixes a known Electron bug).
    func resetStuckWork() throws {
        try db.execute("UPDATE encoding_task SET status = 0 WHERE status = 1")
        try db.execute("UPDATE audio_chunk SET transcribeStatus = 0 WHERE transcribeStatus = 1")
    }

    func framesForEncodingTask(_ taskID: Int64) throws -> [Frame] {
        try db.query(
            """
            SELECT frame.* FROM encoding_task_data
            JOIN frame ON frame.id = encoding_task_data.frame
            WHERE encoding_task_data.encodingTaskID = ?
            ORDER BY frame.createdAt
            """, [taskID]
        ).compactMap(frame(from:))
    }

    /// Marks a task done: assigns videoPath/videoFrameIndex to each frame in order.
    /// Setting status=2 fires the delete_encoding_task trigger which removes the task rows.
    func completeEncodingTask(_ taskID: Int64, videoPath: String, orderedFrameIDs: [Int64]) throws {
        try db.transaction { exec, _ in
            for (index, frameID) in orderedFrameIDs.enumerated() {
                _ = try exec(
                    "UPDATE frame SET videoPath = ?, videoFrameIndex = ?, encodeStatus = 2 WHERE id = ?",
                    [videoPath, index, frameID])
            }
            _ = try exec("UPDATE encoding_task SET status = 2 WHERE id = ?", [taskID])
            return ()
        }
    }

    /// Frames whose PNG can be deleted: encoded AND already OCR'd (OCR gates deletion so text isn't lost).
    /// Batched — the task reruns every `screenshotCleanupInterval`, so a backlog still drains,
    /// but no single run can hold the shared database queue for an unbounded time.
    func framesReadyForScreenshotDeletion(limit: Int = K.screenshotCleanupBatchSize) throws -> [Frame] {
        try db.query(
            """
            SELECT * FROM frame
            WHERE encodeStatus = 2 AND imgFilename IS NOT NULL
              AND EXISTS (SELECT 1 FROM recognition_data WHERE recognition_data.frameID = frame.id)
            ORDER BY createdAt
            LIMIT ?
            """, [limit]
        ).compactMap(frame(from:))
    }

    func clearFrameImage(_ frameID: Int64) throws {
        try db.execute("UPDATE frame SET imgFilename = NULL WHERE id = ?", [frameID])
    }

    // MARK: - OCR

    func framesNeedingOCR(limit: Int) throws -> [Frame] {
        try db.query(
            """
            SELECT * FROM frame
            WHERE imgFilename IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM recognition_data WHERE recognition_data.frameID = frame.id)
            ORDER BY createdAt
            LIMIT ?
            """, [limit]
        ).compactMap(frame(from:))
    }

    func insertRecognition(frameID: Int64, dataJSON: String?, text: String) throws {
        try db.execute(
            "INSERT INTO recognition_data (frameID, data, text) VALUES (?, ?, ?)",
            [frameID, dataJSON, text])
    }

    // MARK: - Audio / transcription

    func insertAudioChunk(filename: String, startedAt: Double, duration: Double) throws {
        try db.execute(
            "INSERT INTO audio_chunk (filename, startedAt, endedAt, duration, transcribeStatus) VALUES (?, ?, ?, ?, 0)",
            [filename, startedAt, startedAt + duration, duration])
    }

    func pendingAudioChunks() throws -> [PendingAudioChunk] {
        try db.query(
            "SELECT id, filename, startedAt FROM audio_chunk WHERE transcribeStatus = 0 ORDER BY startedAt"
        ).compactMap { row in
            guard let id = row.int("id"), let filename = row.string("filename"),
                  let startedAt = row.double("startedAt") else { return nil }
            return PendingAudioChunk(id: id, filename: filename, startedAt: startedAt)
        }
    }

    func setTranscribeStatus(_ chunkID: Int64, status: Int) throws {
        try db.execute("UPDATE audio_chunk SET transcribeStatus = ? WHERE id = ?", [status, chunkID])
    }

    func insertTranscriptions(chunkID: Int64, segments: [(start: Double, end: Double, text: String, language: String?)]) throws {
        try db.transaction { exec, _ in
            for seg in segments {
                _ = try exec(
                    "INSERT INTO transcription (audioChunkID, startOffset, endOffset, text, language) VALUES (?, ?, ?, ?, ?)",
                    [chunkID, seg.start, seg.end, seg.text, seg.language])
            }
            _ = try exec("UPDATE audio_chunk SET transcribeStatus = 2 WHERE id = ?", [chunkID])
            return ()
        }
    }

    /// Transcriptions overlapping [from, to] in absolute unix seconds (parity with GET /transcriptions).
    func transcriptions(from: Double, to: Double, limit: Int = 100) throws -> [TranscriptionSegment] {
        try db.query(
            """
            SELECT t.id, t.text, t.language, t.startOffset, t.endOffset, t.audioChunkID, a.startedAt
            FROM transcription t
            JOIN audio_chunk a ON a.id = t.audioChunkID
            WHERE (a.startedAt + t.startOffset) BETWEEN ? AND ?
            ORDER BY (a.startedAt + t.startOffset)
            LIMIT ?
            """, [from, to, limit]
        ).compactMap(transcriptionSegment(from:))
    }

    func recentTranscriptions(limit: Int = 30) throws -> [TranscriptionSegment] {
        try db.query(
            """
            SELECT t.id, t.text, t.language, t.startOffset, t.endOffset, t.audioChunkID, a.startedAt
            FROM transcription t
            JOIN audio_chunk a ON a.id = t.audioChunkID
            ORDER BY (a.startedAt + t.startOffset) DESC
            LIMIT ?
            """, [limit]
        ).compactMap(transcriptionSegment(from:))
    }

    private func transcriptionSegment(from row: SQLRow) -> TranscriptionSegment? {
        guard let id = row.int("id"), let text = row.string("text"),
              let startOffset = row.double("startOffset"), let endOffset = row.double("endOffset"),
              let chunkID = row.int("audioChunkID"), let startedAt = row.double("startedAt")
        else { return nil }
        return TranscriptionSegment(
            id: id, text: text, language: row.string("language"),
            timestamp: startedAt + startOffset, endTimestamp: startedAt + endOffset,
            audioChunkID: chunkID)
    }

    func deleteTranscription(_ id: Int64) throws {
        try db.execute("DELETE FROM transcription WHERE id = ?", [id])
    }

    // MARK: - Search (parity with GET /search)

    func search(_ rawQuery: String, limit: Int = 20) throws -> [SearchHit] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Quote each token so user input can't break FTS5 query syntax; prefix-match the last token.
        let tokens = trimmed.split(separator: " ").map { token -> String in
            "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let match = tokens.joined(separator: " ") + "*"

        let rows = try db.query(
            """
            SELECT source, sourceID, frameID, audioChunkID,
                   snippet(text_search, 4, '<mark>', '</mark>', '...', 30) AS snip
            FROM text_search
            WHERE text_search MATCH ?
            ORDER BY rank
            LIMIT ?
            """, [match, limit])

        return try rows.compactMap { row -> SearchHit? in
            guard let source = row.string("source"), let sourceID = row.int("sourceID") else { return nil }
            let frameID = row.int("frameID")
            let chunkID = row.int("audioChunkID")
            var createdAt: Double?
            if source == "ocr", let frameID {
                createdAt = try db.query("SELECT createdAt FROM frame WHERE id = ?", [frameID])
                    .first?.double("createdAt")
            } else if source == "audio" {
                createdAt = try db.query(
                    """
                    SELECT (a.startedAt + t.startOffset) AS ts
                    FROM transcription t JOIN audio_chunk a ON a.id = t.audioChunkID
                    WHERE t.id = ?
                    """, [sourceID]
                ).first?.double("ts")
            }
            return SearchHit(
                source: source, sourceID: sourceID, frameID: frameID,
                audioChunkID: chunkID, snippet: row.string("snip") ?? "", createdAt: createdAt)
        }
    }

    // MARK: - Library

    func activityStatus() throws -> ActivityStatus {
        var status = ActivityStatus()
        status.encoding = (try db.query("SELECT COUNT(*) AS c FROM encoding_task WHERE status = 1")
            .first?.int("c") ?? 0) > 0
        status.framesWaiting = Int(try db.query(
            "SELECT COUNT(*) AS c FROM frame WHERE encodeStatus = 0 AND imgFilename IS NOT NULL"
        ).first?.int("c") ?? 0)
        status.transcribing = (try db.query(
            "SELECT COUNT(*) AS c FROM audio_chunk WHERE transcribeStatus = 1").first?.int("c") ?? 0) > 0
        status.audioWaiting = Int(try db.query(
            "SELECT COUNT(*) AS c FROM audio_chunk WHERE transcribeStatus = 0").first?.int("c") ?? 0)
        return status
    }

    /// DB-side cleanup when a video file is deleted from the library (parity with DELETE /library/file).
    func deleteVideoRecords(filename: String) throws {
        try db.transaction { exec, _ in
            _ = try exec(
                "UPDATE frame SET videoPath = NULL, videoFrameIndex = NULL WHERE videoPath = ?", [filename])
            if let taskID = Int64(filename.replacingOccurrences(of: ".mp4", with: "")) {
                _ = try exec("DELETE FROM encoding_task_data WHERE encodingTaskID = ?", [taskID])
                _ = try exec("DELETE FROM encoding_task WHERE id = ?", [taskID])
            }
            return ()
        }
    }

    func deleteAudioRecords(filename: String) throws {
        try db.transaction { exec, query in
            let chunkIDs = try query("SELECT id FROM audio_chunk WHERE filename = ?", [filename])
                .compactMap { $0.int("id") }
            for id in chunkIDs {
                _ = try exec("DELETE FROM transcription WHERE audioChunkID = ?", [id])
                _ = try exec("DELETE FROM audio_chunk WHERE id = ?", [id])
            }
            return ()
        }
    }

    // MARK: - Retention (parity with backend/retention.ts)

    func videosOlderThan(cutoff: Double) throws -> [String] {
        try db.query(
            """
            SELECT DISTINCT videoPath FROM frame
            WHERE videoPath IS NOT NULL
            GROUP BY videoPath
            HAVING MAX(createdAt) < ?
            """, [cutoff]
        ).compactMap { $0.string("videoPath") }
    }

    /// Distinct local days that still have frames — the days analysis can still be run on,
    /// since retention eventually takes the OCR text with the frames.
    func recordedDays() throws -> [String] {
        try db.query(
            "SELECT DISTINCT date(createdAt, 'unixepoch', 'localtime') AS day FROM frame ORDER BY day DESC"
        ).compactMap { $0.string("day") }
    }

    /// Videos whose last frame predates `cutoff`, with that timestamp — the caller needs it
    /// to work out which day a video belongs to.
    func videosLastSeenBefore(_ cutoff: Double) throws -> [(path: String, lastAt: Double)] {
        try db.query(
            """
            SELECT videoPath, MAX(createdAt) AS lastAt FROM frame
            WHERE videoPath IS NOT NULL
            GROUP BY videoPath
            HAVING MAX(createdAt) < ?
            """, [cutoff]
        ).compactMap { row in
            guard let path = row.string("videoPath"), let lastAt = row.double("lastAt") else { return nil }
            return (path: path, lastAt: lastAt)
        }
    }

    func clearVideoReferences(videoPath: String) throws {
        try db.execute(
            "UPDATE frame SET videoPath = NULL, videoFrameIndex = NULL WHERE videoPath = ?", [videoPath])
    }

    func audioChunksOlderThan(cutoff: Double) throws -> [PendingAudioChunk] {
        try db.query(
            "SELECT id, filename, startedAt FROM audio_chunk WHERE startedAt < ?", [cutoff]
        ).compactMap { row in
            guard let id = row.int("id"), let filename = row.string("filename"),
                  let startedAt = row.double("startedAt") else { return nil }
            return PendingAudioChunk(id: id, filename: filename, startedAt: startedAt)
        }
    }

    func deleteAudioChunkCascade(_ id: Int64) throws {
        try db.transaction { exec, _ in
            _ = try exec("DELETE FROM transcription WHERE audioChunkID = ?", [id])
            _ = try exec("DELETE FROM audio_chunk WHERE id = ?", [id])
            return ()
        }
    }

    /// Deleted in batches, one transaction each, so a sweep cut short by quit keeps the work
    /// it already committed instead of rolling all of it back and starting over next launch.
    func deleteOrphanedFrames(cutoff: Double, batchSize: Int = 500) throws {
        while true {
            let deleted = try db.transaction { exec, query -> Int in
                let ids = try query(
                    """
                    SELECT id FROM frame
                    WHERE createdAt < ? AND videoPath IS NULL AND imgFilename IS NULL
                    LIMIT ?
                    """, [cutoff, batchSize]
                ).compactMap { $0.int("id") }
                for id in ids {
                    _ = try exec("DELETE FROM recognition_data WHERE frameID = ?", [id])
                    _ = try exec("DELETE FROM frame WHERE id = ?", [id])
                }
                return ids.count
            }
            if deleted < batchSize { return }
        }
    }
}

// MARK: - Off-main access

// `SQLiteDB` funnels every call through its own serial queue, so a `Store` is already safe
// to use from any thread — these conformances state that explicitly.
extension SQLiteDB: @unchecked Sendable {}
extension Store: @unchecked Sendable {}

extension Store {
    /// A dedicated thread for these reads rather than the Swift concurrency pool: the work
    /// blocks inside SQLiteDB's queue, and parking cooperative threads that way can starve
    /// the pool when a query is slow.
    private static let readQueue = DispatchQueue(label: "kaze.db.read", qos: .userInitiated)

    /// Runs a read away from the calling thread.
    ///
    /// Every `Store` call blocks its thread until the shared database queue is free, so
    /// calling one directly from a `@MainActor` model freezes the entire app for as long as
    /// whatever the background pipeline is doing takes. Awaiting this instead lets the main
    /// actor suspend: the window keeps drawing and simply fills in when the read lands.
    func read<T: Sendable>(_ body: @escaping @Sendable (Store) -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: body(self)) }
        }
    }
}
