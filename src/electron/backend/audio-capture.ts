import { spawn, ChildProcess } from "child_process";
import { createInterface } from "readline";
import { getAudioChunksDir, getDatabase, logger } from "../utils/index.js";
import { getAudioCapturePath } from "../utils/index.js";
import { AUDIO_CHUNK_DURATION } from "./consts.js";

let captureProcess: ChildProcess | null = null;
let restartCount = 0;
let intentionallyStopped = false;
const MAX_RESTARTS = 5;

export function startAudioCapture(): void {
	if (captureProcess) {
		logger.info("Audio capture already running");
		return;
	}

	intentionallyStopped = false;

	const audioDir = getAudioChunksDir();
	const binaryPath = getAudioCapturePath();

	logger.info("Starting audio capture: %s", binaryPath);

	const proc = spawn(binaryPath, [
		"--output-dir", audioDir,
		"--chunk-duration", String(AUDIO_CHUNK_DURATION)
	]);

	captureProcess = proc;

	const rl = createInterface({ input: proc.stdout! });
	rl.on("line", (line: string) => {
		if (line.startsWith("CHUNK:")) {
			const filepath = line.slice(6);
			onChunkReady(filepath);
		}
	});

	proc.stderr?.on("data", (data: Buffer) => {
		const msg = data.toString().trim();
		if (msg.startsWith("ERROR:")) {
			logger.error("audio-capture: %s", msg);
		} else {
			logger.info("audio-capture: %s", msg);
		}
	});

	proc.on("exit", (code) => {
		captureProcess = null;
		logger.info("audio-capture exited with code %d", code);

		if (!intentionallyStopped && code !== 0 && restartCount < MAX_RESTARTS) {
			restartCount++;
			logger.info("Restarting audio capture (attempt %d/%d)", restartCount, MAX_RESTARTS);
			setTimeout(() => startAudioCapture(), 2000);
		}
	});

	proc.on("error", (err) => {
		captureProcess = null;
		logger.error("audio-capture spawn error: %s", err.message);
	});
}

export function stopAudioCapture(): void {
	intentionallyStopped = true;
	if (captureProcess) {
		logger.info("Stopping audio capture");
		captureProcess.kill("SIGTERM");
		// Don't null captureProcess here — let the "exit" handler do it
		// so the readline listener can still receive the final CHUNK: line
	}
}

function onChunkReady(filepath: string) {
	const db = getDatabase();
	if (!db) return;

	const filename = filepath.split("/").pop()!;
	// Filename format: "2026-03-10_17-30-45.wav"
	const timestampStr = filename.replace(".wav", "");
	const [datePart, timePart] = timestampStr.split("_");
	const isoString = `${datePart}T${timePart.replace(/-/g, ":")}`;
	const startedAt = Math.floor(new Date(isoString).getTime() / 1000);
	const endedAt = startedAt + AUDIO_CHUNK_DURATION;

	try {
		db.prepare(`
			INSERT INTO audio_chunk (filename, startedAt, endedAt, duration, transcribeStatus)
			VALUES (?, ?, ?, ?, 0)
		`).run(filename, startedAt, endedAt, AUDIO_CHUNK_DURATION);

		logger.info("Audio chunk recorded: %s", filename);
	} catch (err) {
		logger.error("Failed to insert audio chunk: %s", (err as Error).message);
	}
}
