import path from "path";
import fs from "fs";
import { getUserDataDir, getLegacyUserDataDir } from "../platform/index.js";
import { __dirname } from "../../dirname.js";

// Note: can't use the pino logger here — logging/index.ts calls getLogDir() (which calls
// createDataDir()) at module-load time, before its own logger is initialized, so importing
// it here would create a circular dependency and throw on first launch.
export function createDataDir() {
	const dataDir = getUserDataDir();
	if (!fs.existsSync(dataDir)) {
		const legacyDir = getLegacyUserDataDir();
		if (fs.existsSync(legacyDir)) {
			console.log(`Migrating user data from legacy OpenRewind dir to Kaze dir: ${legacyDir} -> ${dataDir}`);
			fs.mkdirSync(path.dirname(dataDir), { recursive: true });
			try {
				fs.renameSync(legacyDir, dataDir);
			} catch (err) {
				console.warn(`Rename failed (${err}), falling back to copy`);
				fs.cpSync(legacyDir, dataDir, { recursive: true });
				fs.rmSync(legacyDir, { recursive: true, force: true });
			}
		} else {
			fs.mkdirSync(dataDir, { recursive: true });
		}
	}
	return dataDir;
}

export function createTempDir() {
	const tempDir = path.join(getUserDataDir(), "temp");
	if (!fs.existsSync(tempDir)) {
		fs.mkdirSync(tempDir, { recursive: true });
	}
	return tempDir;
}

export function getDatabaseDir() {
	const dataDir = createDataDir();
	return path.join(dataDir, "main.db");
}

export function getScreenshotsDir() {
	const tempDir = createTempDir();
	const screenshotsDir = path.join(tempDir, "screenshots");
	if (!fs.existsSync(screenshotsDir)) {
		fs.mkdirSync(screenshotsDir, { recursive: true });
	}
	return screenshotsDir;
}

export function getRecordingsDir() {
	const dataDir = createDataDir();
	const recordingsDir = path.join(dataDir, "recordings");
	if (!fs.existsSync(recordingsDir)) {
		fs.mkdirSync(recordingsDir, { recursive: true });
	}
	return path.join(dataDir, "recordings");
}

export function getEncodingTempDir() {
	const tempDir = createTempDir();
	const encodingTempDir = path.join(tempDir, "encoding");
	if (!fs.existsSync(encodingTempDir)) {
		fs.mkdirSync(encodingTempDir, { recursive: true });
	}
	return encodingTempDir;
}

export function getDecodingTempDir() {
	const tempDir = createTempDir();
	const decodingTempDir = path.join(tempDir, "decoding");
	if (!fs.existsSync(decodingTempDir)) {
		fs.mkdirSync(decodingTempDir, { recursive: true });
	}
	return decodingTempDir;
}

export function getAudioChunksDir() {
	const dataDir = createDataDir();
	const audioDir = path.join(dataDir, "audio");
	if (!fs.existsSync(audioDir)) {
		fs.mkdirSync(audioDir, { recursive: true });
	}
	return audioDir;
}

export function getLogDir() {
	const dataDir = createDataDir();
	const logDir = path.join(dataDir, "logs");
	if (!fs.existsSync(logDir)) {
		fs.mkdirSync(logDir, { recursive: true });
	}
	return logDir;
}

export function getBinDir() {
	return path.join(__dirname, "bin");
}

export async function waitForFileExists(filePath: string, timeout: number = 10000): Promise<void> {
	return new Promise((resolve, reject) => {
		fs.access(filePath, fs.constants.F_OK, (err) => {
			if (!err) {
				resolve();
				return;
			}

			const dir = path.dirname(filePath);
			const filename = path.basename(filePath);

			const watcher = fs.watch(dir, (eventType, watchedFilename) => {
				if (eventType === "rename" && watchedFilename === filename) {
					fs.access(filePath, fs.constants.F_OK, (err) => {
						if (!err) {
							clearTimeout(timeoutId);
							watcher.close();
							resolve();
						}
					});
				}
			});

			watcher.on("error", (err) => {
				clearTimeout(timeoutId);
				watcher.close();
				reject(err);
			});

			const timeoutId = setTimeout(() => {
				watcher.close();
				reject(new Error(`Timeout: File ${filePath} did not exist within ${timeout}ms`));
			}, timeout);
		});
	});
}
