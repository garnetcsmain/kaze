import Foundation

/// Schema v4 — byte-for-byte compatible with the Electron app (src/electron/backend/init.ts),
/// so an existing main.db is used as-is and old recordings remain visible.
enum Schema {
    static let currentVersion = 4

    /// Opens the database, initializing a fresh schema or validating an existing one.
    /// Databases older than v4 must be migrated by running the Electron app once.
    static func open() throws -> SQLiteDB {
        let db = try SQLiteDB(path: Paths.dbFile.path)
        _ = try? db.execute("PRAGMA journal_mode=WAL")

        let hasConfig = try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='config'"
        ).isEmpty == false

        if !hasConfig {
            try createFreshSchema(db)
            Log.info("Initialized fresh database (schema v4)")
            return db
        }

        let version = try db.query("SELECT value FROM config WHERE key = 'version'")
            .first?.string("value").flatMap(Int.init) ?? 0
        guard version == currentVersion else {
            db.close()
            throw SQLiteError(message: "Database schema is v\(version), expected v\(currentVersion). Run the Electron app once to migrate, or move \(Paths.dbFile.path) aside.")
        }
        return db
    }

    // MARK: - Indexes

    /// Neither this app nor the Electron one ever created an index, so every lookup was a
    /// full table scan. On a real recording history that is fatal: the correlated
    /// `recognition_data.frameID` subqueries behind the OCR and screenshot-cleanup tasks
    /// measured ~230s each against an 88k-frame / 1.7GB database, and because every
    /// `SQLiteDB` call is serialized through one queue, any UI read queued behind them —
    /// which is what froze the Library and Rewind windows.
    ///
    /// Indexes are not part of the v4 *logical* schema, so they are applied idempotently on
    /// every launch instead of via a version bump: the file stays byte-compatible with the
    /// Electron app, and the `config.version` check above is untouched.
    static let indexStatements = [
        // The critical one: turns EXISTS/NOT EXISTS on recognition_data from a full scan
        // of the largest table (per candidate frame) into a b-tree seek.
        "CREATE INDEX IF NOT EXISTS idx_recognition_data_frameID ON recognition_data(frameID)",

        // Timeline paging, retention sweeps and orphan cleanup all order/filter by time.
        "CREATE INDEX IF NOT EXISTS idx_frame_createdAt ON frame(createdAt)",
        // Retention's GROUP BY videoPath and the library's "delete this video" cleanup.
        "CREATE INDEX IF NOT EXISTS idx_frame_videoPath ON frame(videoPath)",
        // Partial indexes over the handful of frames whose PNG is still on disk — these stay
        // tiny (tens of rows) no matter how large the history grows. They serve the OCR
        // backlog, the encoding backlog and the library's live status counters.
        "CREATE INDEX IF NOT EXISTS idx_frame_pending_ocr ON frame(createdAt) WHERE imgFilename IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_frame_pending_encode ON frame(encodeStatus) WHERE imgFilename IS NOT NULL",

        // Encoding pipeline.
        "CREATE INDEX IF NOT EXISTS idx_encoding_task_status ON encoding_task(status)",
        "CREATE INDEX IF NOT EXISTS idx_encoding_task_data_task ON encoding_task_data(encodingTaskID)",

        // Audio + transcription lookups (joins and retention filters).
        "CREATE INDEX IF NOT EXISTS idx_transcription_audioChunkID ON transcription(audioChunkID)",
        "CREATE INDEX IF NOT EXISTS idx_audio_chunk_status ON audio_chunk(transcribeStatus)",
        "CREATE INDEX IF NOT EXISTS idx_audio_chunk_startedAt ON audio_chunk(startedAt)",
    ]

    /// Creates any missing index. Cheap once they exist (a catalog lookup per statement),
    /// but the first run on a large existing database can take a while — call it off the
    /// main thread, before the scheduler starts.
    static func ensureIndexes(_ db: SQLiteDB) throws {
        let existing = Set(
            try db.query("SELECT name FROM sqlite_master WHERE type = 'index'")
                .compactMap { $0.string("name") })
        // "CREATE INDEX IF NOT EXISTS <name> ON …" — the name is the 6th token.
        let missing = indexStatements.filter { statement in
            guard let name = statement.split(separator: " ").dropFirst(5).first else { return true }
            return !existing.contains(String(name))
        }
        guard !missing.isEmpty else { return }

        Log.info("Creating \(missing.count) missing database index(es)…")
        let started = Date()
        for statement in missing {
            try db.execute(statement)
        }
        Log.info(String(format: "Database indexes ready in %.1fs", Date().timeIntervalSince(started)))
    }

    // MARK: - Search index

    /// Maintenance this app applies on top of the v4 baseline. Tracked under its own `config`
    /// key so `config.version` stays 4 and the file remains readable by the Electron app.
    private static let maintenanceKey = "nativeMaintenance"
    private static let maintenanceVersion = 1

    private static let searchTableStatement = """
        CREATE VIRTUAL TABLE IF NOT EXISTS text_search USING fts5(
            source,
            sourceID UNINDEXED,
            frameID UNINDEXED,
            audioChunkID UNINDEXED,
            text
        )
        """

    /// Each search row is stored at a rowid derived from the row it indexes — `id * 2` for
    /// OCR text, `id * 2 + 1` for transcriptions — so the delete triggers can address it
    /// directly.
    ///
    /// The v4 triggers instead located it with `WHERE source = 'ocr' AND sourceID = OLD.id`.
    /// `text_search` is an FTS5 virtual table and `sourceID` is UNINDEXED, so that clause has
    /// no usable index and SQLite scans the whole search index once per deleted row —
    /// measured at ~3.9s each against a 12-day history. Retention deletes thousands of rows
    /// in a single transaction, which would hold the shared database queue for hours and
    /// freeze the app exactly the way the unindexed OCR queries did. By rowid it is ~0.001s.
    private static let searchTriggerStatements = [
        """
        CREATE TRIGGER IF NOT EXISTS recognition_data_after_insert
        AFTER INSERT ON recognition_data
        BEGIN
            INSERT INTO text_search (rowid, source, sourceID, frameID, audioChunkID, text)
            VALUES (NEW.id * 2, 'ocr', NEW.id, NEW.frameID, NULL, NEW.text);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS recognition_data_after_update
        AFTER UPDATE ON recognition_data
        BEGIN
            DELETE FROM text_search WHERE rowid = OLD.id * 2;
            INSERT INTO text_search (rowid, source, sourceID, frameID, audioChunkID, text)
            VALUES (NEW.id * 2, 'ocr', NEW.id, NEW.frameID, NULL, NEW.text);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS recognition_data_after_delete
        AFTER DELETE ON recognition_data
        BEGIN
            DELETE FROM text_search WHERE rowid = OLD.id * 2;
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS transcription_after_insert
        AFTER INSERT ON transcription
        BEGIN
            INSERT INTO text_search (rowid, source, sourceID, frameID, audioChunkID, text)
            VALUES (NEW.id * 2 + 1, 'audio', NEW.id, NULL, NEW.audioChunkID, NEW.text);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS transcription_after_update
        AFTER UPDATE ON transcription
        BEGIN
            DELETE FROM text_search WHERE rowid = OLD.id * 2 + 1;
            INSERT INTO text_search (rowid, source, sourceID, frameID, audioChunkID, text)
            VALUES (NEW.id * 2 + 1, 'audio', NEW.id, NULL, NEW.audioChunkID, NEW.text);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS transcription_after_delete
        AFTER DELETE ON transcription
        BEGIN
            DELETE FROM text_search WHERE rowid = OLD.id * 2 + 1;
        END
        """,
    ]

    /// Renumbers an existing search index onto the rowid scheme above. One-off and atomic:
    /// the index is rebuilt from `recognition_data` and `transcription`, which are the
    /// authority for this text, so any rows stranded by earlier deletes are dropped too.
    /// Takes about a minute per 90k frames — call it off the main thread.
    static func ensureFastSearchDeletes(_ db: SQLiteDB) throws {
        let applied = try db.query("SELECT value FROM config WHERE key = ?", [maintenanceKey])
            .first?.string("value").flatMap(Int.init) ?? 0
        guard applied < maintenanceVersion else { return }

        Log.info("Rebuilding the search index so old recordings can be deleted without scanning it…")
        let started = Date()
        try db.transaction { exec, _ in
            for name in ["recognition_data", "transcription"] {
                for event in ["insert", "update", "delete"] {
                    _ = try exec("DROP TRIGGER IF EXISTS \(name)_after_\(event)", [])
                }
            }
            _ = try exec("DROP TABLE IF EXISTS text_search", [])
            _ = try exec(searchTableStatement, [])
            _ = try exec("""
                INSERT INTO text_search (rowid, source, sourceID, frameID, audioChunkID, text)
                SELECT id * 2, 'ocr', id, frameID, NULL, text FROM recognition_data
                """, [])
            _ = try exec("""
                INSERT INTO text_search (rowid, source, sourceID, frameID, audioChunkID, text)
                SELECT id * 2 + 1, 'audio', id, NULL, audioChunkID, text FROM transcription
                """, [])
            for statement in searchTriggerStatements {
                _ = try exec(statement, [])
            }
            _ = try exec(
                "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)",
                [maintenanceKey, String(maintenanceVersion)])
            return ()
        }
        Log.info(String(format: "Search index rebuilt in %.1fs", Date().timeIntervalSince(started)))
    }

    private static func createFreshSchema(_ db: SQLiteDB) throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS frame (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                createdAt REAL,
                imgFilename TEXT,
                segmentID INTEGER REFERENCES segments(id),
                videoPath TEXT,
                videoFrameIndex INTEGER,
                collectionID INTEGER,
                encodeStatus INTEGER DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS recognition_data (
                id INTEGER PRIMARY KEY,
                frameID INTEGER REFERENCES frame(id),
                data TEXT,
                text TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS segments (
                id INTEGER PRIMARY KEY,
                startedAt REAL,
                endedAt REAL,
                title TEXT,
                appName TEXT,
                appPath TEXT,
                text TEXT,
                type TEXT,
                appBundleID TEXT,
                url TEXT
            )
            """,
            searchTableStatement,
            """
            CREATE TABLE IF NOT EXISTS config (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS encoding_task (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                createdAt REAL,
                status INTEGER DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS encoding_task_data (
                encodingTaskID INTEGER REFERENCES encoding_task(id),
                frame ID INTEGER PRIMARY KEY REFERENCES frame(id)
            )
            """,
            """
            CREATE TRIGGER IF NOT EXISTS delete_encoding_task
            AFTER UPDATE OF status ON encoding_task
            WHEN NEW.status = 2
            BEGIN
                DELETE FROM encoding_task_data WHERE encodingTaskID = NEW.id;
                DELETE FROM encoding_task WHERE id = NEW.id;
            END
            """,
            """
            CREATE TABLE IF NOT EXISTS audio_chunk (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL,
                startedAt REAL NOT NULL,
                endedAt REAL,
                duration REAL,
                transcribeStatus INTEGER DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS transcription (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                audioChunkID INTEGER NOT NULL REFERENCES audio_chunk(id),
                startOffset REAL NOT NULL,
                endOffset REAL NOT NULL,
                text TEXT NOT NULL,
                language TEXT
            )
            """,
            "INSERT OR REPLACE INTO config (key, value) VALUES ('version', '4')",
            // Fresh databases are already on the rowid scheme, so they never need the rebuild.
            "INSERT OR REPLACE INTO config (key, value) VALUES ('\(maintenanceKey)', '\(maintenanceVersion)')",
        ]
        // Search triggers come last: they reference tables created above.
        for sql in statements + searchTriggerStatements {
            try db.execute(sql)
        }
    }
}
