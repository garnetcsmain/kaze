import { app, BrowserWindow, screen } from "electron";
import { join } from "path";
import { __dirname } from "./dirname.js";
import windowStateManager from "electron-window-state";
import { hideDock, showDock } from "./utils/index.js";

function loadURL(window: BrowserWindow, path = "", vitePort: string) {
	const dev = !app.isPackaged;
	if (dev) {
		window.loadURL(`http://localhost:${vitePort}/#${path}`).catch((e) => {
			console.log("Error loading URL:", e);
		});
	} else {
		window
			.loadFile(join(__dirname, "../renderer/index.html"), {
				hash: path
			})
			.catch((e) => {
				console.log("Error loading URL:", e);
			});
	}
}

let isQuitting = false;

export function setQuitting(value: boolean) {
	isQuitting = value;
}

export function createSettingsWindow(vitePort: string, closeCallBack: () => void) {
	const windowState = windowStateManager({
		defaultWidth: 650,
		defaultHeight: 550
	});
	const enableFrame = process.platform === "darwin";
	let icon;
	switch (process.platform) {
		case "darwin":
			icon = undefined;
			break;
		case "win32":
			icon = join(__dirname, "assets/icon.ico");
			break;
		case "linux":
			icon = join(__dirname, "assets/icon.png");
			break;
		default:
			icon = undefined;
	}
	const window = new BrowserWindow({
		width: 650,
		height: 550,
		webPreferences: {
			nodeIntegration: true,
			contextIsolation: true,
			preload: join(__dirname, "preload/settings.cjs")
		},
		titleBarStyle: "hiddenInset",
		resizable: false,
		show: false,
		frame: enableFrame,
		icon: icon
	});
	windowState.manage(window);
	window.on("show", () => {
		showDock();
	});
	window.on("close", (e) => {
		if (!isQuitting) {
			e.preventDefault();
			window.hide();
			windowState.saveState(window);
			closeCallBack();
		}
	});
	window.once("close", () => {
		window.hide();
		hideDock();
	});
	loadURL(window, "settings", vitePort);
	return window;
}

export function createLibraryWindow(vitePort: string, closeCallBack: () => void) {
	const enableFrame = process.platform === "darwin";
	const window = new BrowserWindow({
		width: 660,
		height: 580,
		webPreferences: {
			nodeIntegration: true,
			contextIsolation: true,
			preload: join(__dirname, "preload/library.cjs")
		},
		titleBarStyle: "hiddenInset",
		resizable: false,
		show: false,
		frame: enableFrame,
		title: "Kaze Library"
	});
	window.on("show", () => {
		showDock();
	});
	window.on("close", (e) => {
		if (!isQuitting) {
			e.preventDefault();
			window.hide();
			closeCallBack();
		}
	});
	loadURL(window, "library", vitePort);
	return window;
}

export function createMainWindow(vitePort: string, closeCallBack: () => void) {
	const display = screen.getPrimaryDisplay();
	const { width, height } = display.bounds;
	const winWidth = Math.round(width * 0.8);
	const winHeight = Math.round(height * 0.8);
	const enableFrame = process.platform === "darwin";
	const windowState = windowStateManager({
		defaultWidth: winWidth,
		defaultHeight: winHeight
	});

	const window = new BrowserWindow({
		width: winWidth,
		height: winHeight,
		center: true,
		frame: enableFrame,
		titleBarStyle: "hiddenInset",
		resizable: true,
		fullscreenable: true,
		webPreferences: {
			nodeIntegration: true,
			contextIsolation: true,
			preload: join(__dirname, "preload/rewind.cjs")
		},
		show: false,
		title: "Kaze"
	});

	windowState.manage(window);

	window.on("show", () => {
		showDock();
	});
	window.on("close", (e) => {
		if (!isQuitting) {
			e.preventDefault();
			window.hide();
			windowState.saveState(window);
			closeCallBack();
		}
	});

	loadURL(window, "rewind", vitePort);
	return window;
}
