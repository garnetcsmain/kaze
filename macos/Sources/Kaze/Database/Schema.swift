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
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS text_search USING fts5(
                source,
                sourceID UNINDEXED,
                frameID UNINDEXED,
                audioChunkID UNINDEXED,
                text
            )
            """,
            """
            CREATE TRIGGER IF NOT EXISTS recognition_data_after_insert
            AFTER INSERT ON recognition_data
            BEGIN
                INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
                VALUES ('ocr', NEW.id, NEW.frameID, NULL, NEW.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS recognition_data_after_update
            AFTER UPDATE ON recognition_data
            BEGIN
                DELETE FROM text_search WHERE source = 'ocr' AND sourceID = OLD.id;
                INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
                VALUES ('ocr', NEW.id, NEW.frameID, NULL, NEW.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS recognition_data_after_delete
            AFTER DELETE ON recognition_data
            BEGIN
                DELETE FROM text_search WHERE source = 'ocr' AND sourceID = OLD.id;
            END
            """,
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
            """
            CREATE TRIGGER IF NOT EXISTS transcription_after_insert
            AFTER INSERT ON transcription
            BEGIN
                INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
                VALUES ('audio', NEW.id, NULL, NEW.audioChunkID, NEW.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS transcription_after_update
            AFTER UPDATE ON transcription
            BEGIN
                DELETE FROM text_search WHERE source = 'audio' AND sourceID = OLD.id;
                INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
                VALUES ('audio', NEW.id, NULL, NEW.audioChunkID, NEW.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS transcription_after_delete
            AFTER DELETE ON transcription
            BEGIN
                DELETE FROM text_search WHERE source = 'audio' AND sourceID = OLD.id;
            END
            """,
            "INSERT OR REPLACE INTO config (key, value) VALUES ('version', '4')",
        ]
        for sql in statements {
            try db.execute(sql)
        }
    }
}
