interface Window {
	versions: {
		electron: () => string;
		chrome: () => string;
		node: () => string;
		osRaw: () => string;
		osDisplay: () => string;
	};
	electron: {
		getScreenshot: () => Promise<string>;
	};
	settingsWindow: {
		close: () => void;
	};
	libraryWindow: {
		close: () => void;
		openFolder: (folderPath: string) => void;
	};
}
