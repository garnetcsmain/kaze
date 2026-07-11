import { Database } from "better-sqlite3";

export function migrateToV4(db: Database) {
	db.exec(`
		CREATE TABLE IF NOT EXISTS audio_chunk (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			filename TEXT NOT NULL,
			startedAt REAL NOT NULL,
			endedAt REAL,
			duration REAL,
			transcribeStatus INTEGER DEFAULT 0
		);
	`);

	db.exec(`
		CREATE TABLE IF NOT EXISTS transcription (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			audioChunkID INTEGER NOT NULL,
			startOffset REAL NOT NULL,
			endOffset REAL NOT NULL,
			text TEXT NOT NULL,
			language TEXT,
			FOREIGN KEY (audioChunkID) REFERENCES audio_chunk(id)
		);
	`);

	// Rebuild text_search FTS5 table with source tracking
	db.exec(`
		DROP TRIGGER IF EXISTS recognition_data_after_insert;
		DROP TRIGGER IF EXISTS recognition_data_after_update;
		DROP TRIGGER IF EXISTS recognition_data_after_delete;
		DROP TABLE IF EXISTS text_search;
	`);

	db.exec(`
		CREATE VIRTUAL TABLE IF NOT EXISTS text_search USING fts5(
			source,
			sourceID UNINDEXED,
			frameID UNINDEXED,
			audioChunkID UNINDEXED,
			text
		);
	`);

	// Re-create OCR triggers
	db.exec(`
		CREATE TRIGGER IF NOT EXISTS recognition_data_after_insert AFTER INSERT ON recognition_data
		BEGIN
			INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
			VALUES ('ocr', NEW.id, NEW.frameID, NULL, NEW.text);
		END;
	`);

	db.exec(`
		CREATE TRIGGER IF NOT EXISTS recognition_data_after_update AFTER UPDATE ON recognition_data
		BEGIN
			DELETE FROM text_search WHERE source = 'ocr' AND sourceID = OLD.id;
			INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
			VALUES ('ocr', NEW.id, NEW.frameID, NULL, NEW.text);
		END;
	`);

	db.exec(`
		CREATE TRIGGER IF NOT EXISTS recognition_data_after_delete AFTER DELETE ON recognition_data
		BEGIN
			DELETE FROM text_search WHERE source = 'ocr' AND sourceID = OLD.id;
		END;
	`);

	// Transcription triggers
	db.exec(`
		CREATE TRIGGER IF NOT EXISTS transcription_after_insert AFTER INSERT ON transcription
		BEGIN
			INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
			VALUES ('audio', NEW.id, NULL, NEW.audioChunkID, NEW.text);
		END;
	`);

	db.exec(`
		CREATE TRIGGER IF NOT EXISTS transcription_after_update AFTER UPDATE ON transcription
		BEGIN
			DELETE FROM text_search WHERE source = 'audio' AND sourceID = OLD.id;
			INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
			VALUES ('audio', NEW.id, NULL, NEW.audioChunkID, NEW.text);
		END;
	`);

	db.exec(`
		CREATE TRIGGER IF NOT EXISTS transcription_after_delete AFTER DELETE ON transcription
		BEGIN
			DELETE FROM text_search WHERE source = 'audio' AND sourceID = OLD.id;
		END;
	`);

	// Re-populate FTS5 from existing recognition_data
	db.exec(`
		INSERT INTO text_search (source, sourceID, frameID, audioChunkID, text)
			SELECT 'ocr', id, frameID, NULL, text FROM recognition_data;
	`);

	db.exec(`
		UPDATE config SET value = '4' WHERE key = 'version';
	`);
}
