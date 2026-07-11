import {
	app,
	BrowserWindow,
	ipcMain,
	Menu,
	nativeImage,
	Tray
} from "electron";
import contextMenu from "electron-context-menu";
import { join } from "path";
import initI18n from "./i18n.js";
import { createMainWindow, createSettingsWindow, createLibraryWindow, setQuitting } from "./createWindow.js";
import { shell } from "electron";
import { initDatabase } from "./backend/init.js";
import { Database } from "better-sqlite3";
import { takeScreenshot } from "./backend/screenshot.js";
import { __dirname } from "./dirname.js";
import { hideDock, showDock } from "./utils/index.js";
import {
	checkFramesForEncoding,
	deleteUnnecessaryScreenshots,
	processEncodingTasks,
	flushPendingFrames
} from "./backend/encoding.js";
import honoApp from "./server/index.js";
import { serve } from "@hono/node-server";
import { findAvailablePort } from "./utils/index.js";
import cache from "memory-cache";
import { generate as generateAPIKey } from "@alikia/random-key";
import { Scheduler } from "./backend/scheduler.js";
import { startAudioCapture, stopAudioCapture } from "./backend/audio-capture.js";
import { processTranscriptionTasks, cleanupTranscribedAudio } from "./backend/transcription.js";
import { TRANSCRIPTION_CHECK_INTERVAL, AUDIO_CLEANUP_INTERVAL } from "./backend/consts.js";
import { cleanupOldRecordings } from "./backend/retention.js";

const i18n = initI18n();

const t = i18n.t.bind(i18n);
const port = process.env.PORT || "5173";
const dev = !app.isPackaged;
const scheduler = new Scheduler();

let tray: null | Tray = null;
let dbConnection: null | Database = null;

let mainWindow: BrowserWindow | null;
let settingsWindow: BrowserWindow | null;
let libraryWindow: BrowserWindow | null;
let audioRecording = true;
let screenRecording = true;

function buildTrayMenu() {
	return Menu.buildFromTemplate([
		{
			label: t("tray.showMainWindow"),
			click: () => {
				showDock();
				mainWindow!.show();
				mainWindow!.focus();
			}
		},
		{
			label: t("tray.showSettingsWindow"),
			click: () => {
				settingsWindow!.show();
			}
		},
		{
			label: t("tray.showLibrary"),
			click: () => {
				libraryWindow!.show();
			}
		},
		{ type: "separator" },
		{
			label: screenRecording ? t("tray.stopScreenRecording") : t("tray.startScreenRecording"),
			click: () => {
				if (screenRecording) {
					scheduler.pauseTask("screenshot");
					flushPendingFrames();
					scheduler.pauseTask("check-encoding");
					scheduler.pauseTask("process-encoding");
					scheduler.pauseTask("delete-screenshots");
				} else {
					scheduler.resumeTask("screenshot");
					scheduler.resumeTask("check-encoding");
					scheduler.resumeTask("process-encoding");
					scheduler.resumeTask("delete-screenshots");
				}
				screenRecording = !screenRecording;
				tray!.setContextMenu(buildTrayMenu());
			}
		},
		{
			label: audioRecording ? t("tray.stopAudioRecording") : t("tray.startAudioRecording"),
			click: () => {
				if (audioRecording) {
					stopAudioCapture();
				} else {
					startAudioCapture();
				}
				audioRecording = !audioRecording;
				tray!.setContextMenu(buildTrayMenu());
			}
		},
		{ type: "separator" },
		{
			label: t("tray.quit"),
			click: () => {
				app.quit();
			}
		}
	]);
}

function createTray() {
	const pathRoot: string = dev ? "./src/electron/assets/" : join(__dirname, "./assets/");
	const icon = nativeImage.createFromPath(pathRoot + "TrayIconTemplate@2x.png");
	icon.resize({ width: 32, height: 32 });
	tray = new Tray(pathRoot + "TrayIcon.png");
	tray.setImage(icon);
	tray.setContextMenu(buildTrayMenu());
	tray.setToolTip("Kaze");
}

contextMenu({
	showLookUpSelection: true,
	showSearchWithGoogle: true,
	showCopyImage: true
});

app.once("ready", () => {
	hideDock();
});
app.on("activate", () => {});

app.on("ready", () => {
	createTray();
	findAvailablePort(12412).then((port) => {
		generateAPIKey().then((key) => {
			cache.put("server:port", port);
			if (!dev) {
				cache.put("server:APIKey", key);
			}
			serve({ fetch: honoApp.fetch, port: port });

			// Send API info to renderer
			settingsWindow?.webContents.send("api-info", {
				port,
				apiKey: key
			});
			console.log(`App server running on port ${port}`);
		});
	});
	initDatabase().then((db) => {
		scheduler.addTask("screenshot", takeScreenshot, 2000);
		scheduler.addTask("check-encoding", checkFramesForEncoding, 5000);
		scheduler.addTask("process-encoding", processEncodingTasks, 10000, "LOW_POWER");
		scheduler.addTask("delete-screenshots", deleteUnnecessaryScreenshots, 20000);
		scheduler.addTask("process-transcription", processTranscriptionTasks, TRANSCRIPTION_CHECK_INTERVAL);
		// Audio files kept after transcription — user can delete manually from library
		dbConnection = db;
		cache.put("server:dbConnection", dbConnection);
		cleanupOldRecordings();
		startAudioCapture();
	});
	mainWindow = createMainWindow(port, () => {});
	settingsWindow = createSettingsWindow(port, () => {});
	libraryWindow = createLibraryWindow(port, () => {});
});

app.on("before-quit", () => {
	setQuitting(true);
});

app.on("will-quit", () => {
	scheduler.stop();
	stopAudioCapture();
	flushPendingFrames();
	cleanupOldRecordings();
	dbConnection?.close();
});

ipcMain.on("close-settings", () => {
	settingsWindow?.hide();
});

ipcMain.on("close-library", () => {
	libraryWindow?.hide();
});

ipcMain.on("open-folder", (_event, folderPath: string) => {
	shell.openPath(folderPath);
});

ipcMain.handle("request-api-info", () => {
	return {
		port: cache.get("server:port"),
		apiKey: cache.get("server:APIKey")
	};
});
