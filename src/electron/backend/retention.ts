import fs from "fs";
import { join } from "path";
import { getRecordingsDir, getAudioChunksDir, getDatabase, logger } from "../utils/index.js";
import { RETENTION_DAYS } from "./consts.js";

const RETENTION_MS = RETENTION_DAYS * 24 * 60 * 60 * 1000;

export function cleanupOldRecordings(): void {
	const db = getDatabase();
	if (!db) return;

	const cutoff = Date.now() - RETENTION_MS;
	const cutoffSeconds = cutoff / 1000;

	// Delete old video recordings
	cleanupOldVideos(db, cutoffSeconds);

	// Delete old audio chunks (even if not yet transcribed)
	cleanupOldAudio(db, cutoffSeconds);

	// Delete old frames from the database
	cleanupOldFrames(db, cutoffSeconds);
}

function cleanupOldVideos(db: ReturnType<typeof getDatabase>, cutoffSeconds: number): void {
	if (!db) return;

	const recordingsDir = getRecordingsDir();

	// Find encoding tasks whose frames are all older than the cutoff
	const oldTasks = db.prepare(`
		SELECT DISTINCT et.id
		FROM encoding_task et
		JOIN encoding_task_data etd ON etd.encodingTaskID = et.id
		JOIN frame f ON etd.frame = f.id
		WHERE et.status = 2
		GROUP BY et.id
		HAVING MAX(f.createdAt) < ?
	`).all(cutoffSeconds) as { id: number }[];

	for (const task of oldTasks) {
		const videoPath = join(recordingsDir, `${task.id}.mp4`);
		if (fs.existsSync(videoPath)) {
			try {
				fs.unlinkSync(videoPath);
				logger.info("Deleted old video: %s", `${task.id}.mp4`);
			} catch (err) {
				logger.error("Failed to delete video %s: %s", `${task.id}.mp4`, (err as Error).message);
			}
		}

		// Null out videoPath on associated frames so we don't try to decode from a deleted video
		db.prepare(`
			UPDATE frame SET videoPath = NULL, videoFrameIndex = NULL
			WHERE id IN (SELECT frame FROM encoding_task_data WHERE encodingTaskID = ?)
		`).run(task.id);

		// Clean up encoding task data
		db.prepare(`DELETE FROM encoding_task_data WHERE encodingTaskID = ?`).run(task.id);
		db.prepare(`DELETE FROM encoding_task WHERE id = ?`).run(task.id);
	}

	if (oldTasks.length > 0) {
		logger.info("Retention cleanup: removed %d old video(s)", oldTasks.length);
	}
}

function cleanupOldAudio(db: ReturnType<typeof getDatabase>, cutoffSeconds: number): void {
	if (!db) return;

	const audioDir = getAudioChunksDir();

	const oldChunks = db.prepare(`
		SELECT id, filename FROM audio_chunk WHERE startedAt < ?
	`).all(cutoffSeconds) as { id: number; filename: string }[];

	for (const chunk of oldChunks) {
		// Delete the WAV file if it still exists
		const wavPath = join(audioDir, chunk.filename);
		if (fs.existsSync(wavPath)) {
			try {
				fs.unlinkSync(wavPath);
			} catch (err) {
				logger.error("Failed to delete audio chunk %s: %s", chunk.filename, (err as Error).message);
			}
		}

		// Delete associated transcriptions
		db.prepare(`DELETE FROM transcription WHERE audioChunkID = ?`).run(chunk.id);
		// Delete the audio chunk record
		db.prepare(`DELETE FROM audio_chunk WHERE id = ?`).run(chunk.id);
	}

	if (oldChunks.length > 0) {
		logger.info("Retention cleanup: removed %d old audio chunk(s)", oldChunks.length);
	}
}

function cleanupOldFrames(db: ReturnType<typeof getDatabase>, cutoffSeconds: number): void {
	if (!db) return;

	// Delete frames older than the cutoff that have no video (already cleaned up) and no screenshot
	const deleted = db.prepare(`
		DELETE FROM frame
		WHERE createdAt < ?
		  AND videoPath IS NULL
		  AND imgFilename IS NULL
	`).run(cutoffSeconds);

	if (deleted.changes > 0) {
		logger.info("Retention cleanup: removed %d orphaned frame record(s)", deleted.changes);
	}
}
