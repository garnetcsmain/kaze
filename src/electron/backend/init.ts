import * as path from "path";
import { Database } from "better-sqlite3";
import DB from "better-sqlite3";
import { __dirname } from "../dirname.js";
import { getBinDir, getDatabaseDir } from "../utils/index.js";
import { migrate } from "./migrate/index.js";

function getLibSimpleExtensionPath() {
	switch (process.platform) {
		case "win32":
			return path.join(getBinDir(), "libsimple", "simple.dll");
		case "darwin":
			return path.join(getBinDir(), "libsimple", "libsimple.dylib");
		case "linux":
			return path.join(getBinDir(), "libsimple", "libsimple.so");
		default:
			throw new Error("Unsupported platform");
	}
}

function databaseInitialized(db: Database) {
	return (
		db.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name='frame';`).get() !==
		undefined
	);
}

function init(db: Database) {
	db.exec(`
        CREATE TABLE IF NOT EXISTS frame (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            createdAt REAL,
            imgFilename TEXT,
            segmentID INTEGER NULL,
            videoPath TEXT NULL,
            videoFrameIndex INTEGER NULL,
            collectionID INTEGER NULL,
            encodeStatus INTEGER DEFAULT 0,
            FOREIGN KEY (segmentID) REFERENCES segments (id)
        );
    `);

	db.exec(`
        CREATE TABLE IF NOT EXISTS recognition_data (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            frameID INTEGER,
            data TEXT,
            text TEXT,
            FOREIGN KEY (frameID) REFERENCES frame (id)
        );
    `);

	db.exec(`
        CREATE TABLE IF NOT EXISTS segments(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            startedAt REAL,
            endedAt REAL,
            title TEXT,
            appName TEXT,
            appPath TEXT,
            text TEXT,
            type TEXT,
            appBundleID TEXT NULL,
            url TEXT NULL
        );
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

	db.exec(`
		CREATE TABLE config (
			key TEXT PRIMARY KEY,
			value TEXT
		);
	`);

	db.exec(`
		CREATE TABLE IF NOT EXISTS encoding_task (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			createdAt REAL,
			status INT DEFAULT 0
		);
	`);

	db.exec(`
		CREATE TABLE IF NOT EXISTS encoding_task_data (
			encodingTaskID INTEGER,
			frame ID INTEGER PRIMARY KEY,
			FOREIGN KEY (encodingTaskID) REFERENCES encoding_task(id),
			FOREIGN KEY (frame) REFERENCES frame(id)
		);				
	`);

	db.exec(`
		CREATE TRIGGER IF NOT EXISTS delete_encoding_task
		AFTER UPDATE OF status
		ON encoding_task
		BEGIN
		  DELETE FROM encoding_task_data
		  WHERE encodingTaskID = OLD.id AND NEW.status = 2;

		  DELETE FROM encoding_task
		  WHERE id = OLD.id AND NEW.status = 2;
		END;
	`);

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

	db.exec(`
		INSERT INTO config (key, value) VALUES ('version', '4');
	`);
}

export async function initDatabase() {
	const dbPath = getDatabaseDir();
	const db = new DB(dbPath);
	const libSimpleExtensionPath = getLibSimpleExtensionPath();

	db.loadExtension(libSimpleExtensionPath);

	if (!databaseInitialized(db)) {
		init(db);
	} else {
		migrate(db);
	}

	db.exec("PRAGMA journal_mode=WAL;");

	return db;
}
