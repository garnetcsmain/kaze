import { execFile } from "child_process";
import fs from "fs";
import { join } from "path";
import type { AudioChunk } from "./schema";
import { getAudioChunksDir, getDatabase, logger } from "../utils/index.js";
import { getWhisperPath, getWhisperModelPath } from "../utils/index.js";
import cache from "memory-cache";

const CONCURRENCY = 1;

interface WhisperSegment {
	offsets: {
		from: number;
		to: number;
	};
	text: string;
}

interface WhisperOutput {
	transcription: WhisperSegment[];
	result: {
		language: string;
	};
}

function getTasksProcessing(): number[] {
	return (cache.get("backend:transcriptionTasksProcessing") as number[]) || [];
}

export function processTranscriptionTasks(): void {
	const db = getDatabase();
	if (!db) return;

	let tasksProcessing = getTasksProcessing();
	if (tasksProcessing.length >= CONCURRENCY) return;

	const chunks = db.prepare(`
		SELECT id, filename, startedAt, endedAt, duration
		FROM audio_chunk
		WHERE transcribeStatus = 0
		ORDER BY startedAt
		LIMIT ?
	`).all(CONCURRENCY - tasksProcessing.length) as AudioChunk[];

	for (const chunk of chunks) {
		const chunkId = chunk.id;
		const audioDir = getAudioChunksDir();
		const wavPath = join(audioDir, chunk.filename);

		if (!fs.existsSync(wavPath)) {
			logger.warn("Audio chunk file missing, marking as error: %s", chunk.filename);
			db.prepare(`UPDATE audio_chunk SET transcribeStatus = 3 WHERE id = ?`).run(chunkId);
			continue;
		}

		// Mark as processing
		db.prepare(`UPDATE audio_chunk SET transcribeStatus = 1 WHERE id = ?`).run(chunkId);
		cache.put("backend:transcriptionTasksProcessing", [...tasksProcessing, chunkId]);

		const whisperPath = getWhisperPath();
		const modelPath = getWhisperModelPath();
		const jsonOutputPath = wavPath.replace(".wav", "");

		execFile(whisperPath, [
			"-m", modelPath,
			"-f", wavPath,
			"-l", "auto",
			"--output-json",
			"--output-file", jsonOutputPath,
			"--no-prints"
		], (error) => {
			if (error) {
				logger.error("Whisper error for chunk %d: %s", chunkId, error.message);
				db.prepare(`UPDATE audio_chunk SET transcribeStatus = 3 WHERE id = ?`).run(chunkId);
			} else {
				const jsonPath = jsonOutputPath + ".json";
				try {
					const raw = fs.readFileSync(jsonPath, "utf-8");
					const output: WhisperOutput = JSON.parse(raw);
					const segments = output.transcription;
					const language = output.result?.language || null;

					const insertStmt = db.prepare(`
						INSERT INTO transcription (audioChunkID, startOffset, endOffset, text, language)
						VALUES (?, ?, ?, ?, ?)
					`);

					const insertMany = db.transaction((segs: WhisperSegment[]) => {
						for (const seg of segs) {
							const text = seg.text.trim();
							if (!text) continue;
							insertStmt.run(
								chunkId,
								seg.offsets.from / 1000,
								seg.offsets.to / 1000,
								text,
								language
							);
						}
					});

					insertMany(segments);

					// Mark as done
					db.prepare(`UPDATE audio_chunk SET transcribeStatus = 2 WHERE id = ?`).run(chunkId);
					logger.info("Transcribed chunk %d: %d segments", chunkId, segments.length);

					// Clean up JSON output
					fs.unlinkSync(jsonPath);
				} catch (parseErr) {
					logger.error("Failed to parse whisper output for chunk %d: %s", chunkId, (parseErr as Error).message);
					db.prepare(`UPDATE audio_chunk SET transcribeStatus = 3 WHERE id = ?`).run(chunkId);
				}
			}

			// Remove from processing list
			tasksProcessing = getTasksProcessing();
			cache.put(
				"backend:transcriptionTasksProcessing",
				tasksProcessing.filter((id) => id !== chunkId)
			);
		});
	}
}

export function cleanupTranscribedAudio(): void {
	const db = getDatabase();
	if (!db) return;

	const audioDir = getAudioChunksDir();
	const chunks = db.prepare(`
		SELECT id, filename
		FROM audio_chunk
		WHERE transcribeStatus = 2
	`).all() as AudioChunk[];

	for (const chunk of chunks) {
		const wavPath = join(audioDir, chunk.filename);
		if (fs.existsSync(wavPath)) {
			try {
				fs.unlinkSync(wavPath);
			} catch (err) {
				logger.error("Failed to delete audio chunk %s: %s", chunk.filename, (err as Error).message);
			}
		}
	}
}
