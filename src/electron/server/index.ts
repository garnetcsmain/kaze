import { Hono } from "hono";
import { cors } from "hono/cors";
import cache from "memory-cache";
import { join } from "path";
import fs from "fs";
import { Database } from "better-sqlite3";
import type { Frame } from "../backend/schema";
import {
	getDecodingTempDir,
	getRecordingsDir,
	getScreenshotsDir,
	getAudioChunksDir,
	getDatabaseDir,
	waitForFileExists
} from "../utils/index.js";
import { immediatelyExtractFrameFromVideo } from "../utils/index.js";
import { existsSync } from "fs";

const app = new Hono();

app.use("*", cors());

app.use(async (c, next) => {
	const key = cache.get("server:APIKey");
	if (key && c.req.header("x-api-key") !== key) {
		c.res = undefined;
		c.res = c.json({ error: "Invalid API key" }, 401);
	}
	await next();
});

app.get("/ping", (c) => c.text("pong"));

function getLatestFrames(db: Database, limit = 50): Frame[] {
	return db
		.prepare(
			`
    SELECT id, createdAt, imgFilename, videoPath, videoFrameIndex 
    FROM frame
    ORDER BY createdAt DESC
    LIMIT ?
  `
		)
		.all(limit) as Frame[];
}

function getFramesUntilID(db: Database, untilID: number, limit = 50): Frame[] {
	return db
		.prepare(
			`
    SELECT id, createdAt, imgFilename, videoPath, videoFrameIndex 
    FROM frame
	WHERE id < ?
    ORDER BY createdAt DESC
    LIMIT ?
  `
		)
		.all(untilID, limit) as Frame[];
}

app.get("/timeline", async (c) => {
	const query = c.req.query();
	const limit = parseInt(query.limit) || undefined;
	const db = cache.get("server:dbConnection");
	if (query.untilID) {
		return c.json(getFramesUntilID(db, parseInt(query.untilID), limit));
	} else {
		return c.json(getLatestFrames(db, limit));
	}
});

app.get("/frame/:id", async (c) => {
	const { id } = c.req.param();
	const db: Database = cache.get("server:dbConnection");

	const frame = db
		.prepare(
			`
				SELECT imgFilename, videoPath, videoFrameIndex, createdAt
				FROM frame 
				WHERE id = ?
			`
		)
		.get(id) as Frame | undefined;

	if (!frame) return c.json({ error: "Frame not found" }, 404);

	const decodingTempDir = getDecodingTempDir();
	const screenshotsDir = getScreenshotsDir();
	const videoFilename = frame.videoPath;
	const frameIndex = frame.videoFrameIndex;
	const imageFilename = frame.imgFilename;
	const bareVideoFilename = videoFilename?.replace(".mp4", "") || null;
	const decodedImage = frameIndex
		? `${bareVideoFilename}_${frameIndex.toString().padStart(4, "0")}.bmp`
		: null;
	let returnImagePath = "";

	let needToBeDecoded = videoFilename !== null && frameIndex !== null && !frame.imgFilename;
	if (decodedImage && fs.existsSync(join(getDecodingTempDir(), decodedImage))) {
		needToBeDecoded = false;
		returnImagePath = join(decodingTempDir, decodedImage);
	} else if (imageFilename && fs.existsSync(join(screenshotsDir, imageFilename))) {
		returnImagePath = join(screenshotsDir, imageFilename);
	}

	if (needToBeDecoded) {
		const videoExists = fs.existsSync(join(getRecordingsDir(), videoFilename!));

		if (!videoExists) {
			return c.json({ error: "Video not found" }, { status: 404 });
		}

		const decodedFilename = immediatelyExtractFrameFromVideo(
			videoFilename!,
			frameIndex!,
			decodingTempDir
		);
		const decodedPath = join(decodingTempDir, decodedFilename);

		await waitForFileExists(decodedPath);

		if (existsSync(decodedPath)) {
			const imageBuffer = fs.readFileSync(decodedPath);
			setTimeout(() => {
				fs.unlinkSync(decodedPath);
			}, 1000);
			return new Response(imageBuffer, {
				status: 200,
				headers: {
					"Content-Type": "image/bmp"
				}
			});
		} else {
			return c.json({ error: "Frame cannot be decoded" }, { status: 500 });
		}
	} else {
		const imageBuffer = fs.readFileSync(returnImagePath);
		const imageMimeType = imageFilename?.endsWith(".png") ? "image/png" : "image/jpeg";
		return new Response(imageBuffer, {
			status: 200,
			headers: {
				"Content-Type": imageMimeType
			}
		});
	}
});

app.get("/search", (c) => {
	const query = c.req.query();
	const q = query.q;
	const limit = parseInt(query.limit) || 20;

	if (!q) return c.json({ error: "Missing query parameter 'q'" }, 400);

	const db: Database = cache.get("server:dbConnection");

	const results = db.prepare(`
		SELECT source, sourceID, frameID, audioChunkID,
			snippet(text_search, 4, '<mark>', '</mark>', '...', 30) AS snippet
		FROM text_search
		WHERE text_search MATCH ?
		ORDER BY rank
		LIMIT ?
	`).all(q, limit) as {
		source: string;
		sourceID: number;
		frameID: number | null;
		audioChunkID: number | null;
		snippet: string;
	}[];

	// Enrich results with timestamps
	const enriched = results.map((r) => {
		if (r.source === "ocr" && r.frameID) {
			const frame = db.prepare(`SELECT createdAt FROM frame WHERE id = ?`).get(r.frameID) as { createdAt: number } | undefined;
			return { ...r, createdAt: frame?.createdAt || null };
		} else if (r.source === "audio" && r.audioChunkID) {
			const chunk = db.prepare(`SELECT startedAt FROM audio_chunk WHERE id = ?`).get(r.audioChunkID) as { startedAt: number } | undefined;
			const transcription = db.prepare(`SELECT startOffset FROM transcription WHERE id = ?`).get(r.sourceID) as { startOffset: number } | undefined;
			return {
				...r,
				createdAt: chunk && transcription ? chunk.startedAt + transcription.startOffset : chunk?.startedAt || null
			};
		}
		return { ...r, createdAt: null };
	});

	return c.json(enriched);
});

app.get("/transcriptions", (c) => {
	const query = c.req.query();
	const from = parseFloat(query.from);
	const to = parseFloat(query.to);
	const limit = parseInt(query.limit) || 100;

	if (isNaN(from) || isNaN(to)) {
		return c.json({ error: "Missing or invalid 'from' and 'to' query parameters (unix timestamps)" }, 400);
	}

	const db: Database = cache.get("server:dbConnection");

	const results = db.prepare(`
		SELECT t.id, t.audioChunkID, t.startOffset, t.endOffset, t.text, t.language,
			ac.startedAt, ac.filename
		FROM transcription t
		JOIN audio_chunk ac ON t.audioChunkID = ac.id
		WHERE (ac.startedAt + t.startOffset) >= ?
		  AND (ac.startedAt + t.startOffset) <= ?
		ORDER BY ac.startedAt + t.startOffset
		LIMIT ?
	`).all(from, to, limit) as {
		id: number;
		audioChunkID: number;
		startOffset: number;
		endOffset: number;
		text: string;
		language: string | null;
		startedAt: number;
		filename: string;
	}[];

	return c.json(results.map((r) => ({
		id: r.id,
		text: r.text,
		language: r.language,
		timestamp: r.startedAt + r.startOffset,
		endTimestamp: r.startedAt + r.endOffset,
		audioChunkID: r.audioChunkID
	})));
});

app.get("/library/stats", (c) => {
	const recordingsDir = getRecordingsDir();
	const audioDir = getAudioChunksDir();
	const dbPath = getDatabaseDir();

	function getDirectoryFiles(dirPath: string) {
		if (!fs.existsSync(dirPath)) return [];
		return fs.readdirSync(dirPath)
			.filter((f) => !f.startsWith("."))
			.map((filename) => {
				const filePath = join(dirPath, filename);
				const stat = fs.statSync(filePath);
				return {
					name: filename,
					size: stat.size,
					createdAt: stat.mtimeMs
				};
			})
			.sort((a, b) => b.createdAt - a.createdAt);
	}

	const videoFiles = getDirectoryFiles(recordingsDir);
	const audioFiles = getDirectoryFiles(audioDir);

	const dbSize = fs.existsSync(dbPath) ? fs.statSync(dbPath).size : 0;

	const videoTotal = videoFiles.reduce((sum, f) => sum + f.size, 0);
	const audioTotal = audioFiles.reduce((sum, f) => sum + f.size, 0);

	return c.json({
		videos: {
			path: recordingsDir,
			files: videoFiles,
			totalSize: videoTotal,
			count: videoFiles.length
		},
		audio: {
			path: audioDir,
			files: audioFiles,
			totalSize: audioTotal,
			count: audioFiles.length
		},
		database: {
			path: dbPath,
			size: dbSize
		},
		totalSize: videoTotal + audioTotal + dbSize
	});
});

app.get("/library/transcriptions", (c) => {
	const db: Database = cache.get("server:dbConnection");
	if (!db) return c.json({ transcriptions: [], count: 0 });

	const limit = parseInt(c.req.query("limit") || "30");

	const rows = db.prepare(`
		SELECT t.id, t.text, t.language, t.startOffset, t.endOffset,
			ac.startedAt, ac.id as chunkId
		FROM transcription t
		JOIN audio_chunk ac ON t.audioChunkID = ac.id
		ORDER BY (ac.startedAt + t.startOffset) DESC
		LIMIT ?
	`).all(limit) as {
		id: number;
		text: string;
		language: string | null;
		startOffset: number;
		endOffset: number;
		startedAt: number;
		chunkId: number;
	}[];

	const count = (db.prepare(`SELECT COUNT(*) as count FROM transcription`).get() as { count: number }).count;

	return c.json({
		transcriptions: rows.map((r) => ({
			id: r.id,
			text: r.text,
			language: r.language,
			timestamp: (r.startedAt + r.startOffset) * 1000,
			chunkId: r.chunkId
		})),
		count
	});
});

app.delete("/library/transcription/:id", (c) => {
	const db: Database = cache.get("server:dbConnection");
	if (!db) return c.json({ error: "No database" }, 500);

	const id = parseInt(c.req.param("id"));
	if (isNaN(id)) return c.json({ error: "Invalid id" }, 400);

	db.prepare(`DELETE FROM transcription WHERE id = ?`).run(id);
	return c.json({ ok: true });
});

app.get("/library/status", (c) => {
	const db: Database = cache.get("server:dbConnection");
	if (!db) return c.json({ activities: [] });

	const activities: { key: string; count?: number }[] = [];

	// Check encoding in progress
	const encodingInProgress = db.prepare(
		`SELECT COUNT(*) as count FROM encoding_task WHERE status = 1`
	).get() as { count: number };
	if (encodingInProgress.count > 0) {
		activities.push({ key: "encoding" });
	}

	// Check frames waiting to be encoded
	const framesWaiting = db.prepare(
		`SELECT COUNT(*) as count FROM frame WHERE encodeStatus = 0 AND imgFilename IS NOT NULL`
	).get() as { count: number };
	if (framesWaiting.count > 0) {
		activities.push({ key: "frames-waiting", count: framesWaiting.count });
	}

	// Check transcription in progress
	const transcribingNow = db.prepare(
		`SELECT COUNT(*) as count FROM audio_chunk WHERE transcribeStatus = 1`
	).get() as { count: number };
	if (transcribingNow.count > 0) {
		activities.push({ key: "transcribing" });
	}

	// Check audio waiting for transcription
	const audioWaiting = db.prepare(
		`SELECT COUNT(*) as count FROM audio_chunk WHERE transcribeStatus = 0`
	).get() as { count: number };
	if (audioWaiting.count > 0) {
		activities.push({ key: "audio-waiting", count: audioWaiting.count });
	}

	return c.json({ activities });
});

app.delete("/library/file", async (c) => {
	const body = await c.req.json<{ type: string; filename: string }>();
	const { type, filename } = body;

	if (!filename || !type) {
		return c.json({ error: "Missing type or filename" }, 400);
	}

	// Prevent path traversal
	if (filename.includes("/") || filename.includes("..")) {
		return c.json({ error: "Invalid filename" }, 400);
	}

	const dir = type === "video" ? getRecordingsDir() : getAudioChunksDir();
	const filePath = join(dir, filename);

	if (!fs.existsSync(filePath)) {
		return c.json({ error: "File not found" }, 404);
	}

	try {
		fs.unlinkSync(filePath);

		// Clean up DB records
		const db: Database = cache.get("server:dbConnection");
		if (db) {
			if (type === "video") {
				// Find encoding task ID from video filename (e.g. "5.mp4" → task id 5)
				const taskId = parseInt(filename.replace(".mp4", ""), 10);
				if (!isNaN(taskId)) {
					db.prepare(`UPDATE frame SET videoPath = NULL, videoFrameIndex = NULL WHERE videoPath = ?`).run(filename);
					db.prepare(`DELETE FROM encoding_task_data WHERE encodingTaskID = ?`).run(taskId);
					db.prepare(`DELETE FROM encoding_task WHERE id = ?`).run(taskId);
				}
			} else if (type === "audio") {
				const chunk = db.prepare(`SELECT id FROM audio_chunk WHERE filename = ?`).get(filename) as { id: number } | undefined;
				if (chunk) {
					db.prepare(`DELETE FROM transcription WHERE audioChunkID = ?`).run(chunk.id);
					db.prepare(`DELETE FROM audio_chunk WHERE id = ?`).run(chunk.id);
				}
			}
		}

		return c.json({ ok: true });
	} catch (err) {
		return c.json({ error: (err as Error).message }, 500);
	}
});

export default app;
