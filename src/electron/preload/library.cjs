const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("libraryWindow", {
	close: () => {
		ipcRenderer.send("close-library", {});
	},
	openFolder: (folderPath) => {
		ipcRenderer.send("open-folder", folderPath);
	}
});

contextBridge.exposeInMainWorld("appGlobal", {
	requestApiInfo: () => ipcRenderer.invoke("request-api-info")
});
