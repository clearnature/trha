import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('electronAPI', {
  // Auth
  getToken: () => ipcRenderer.invoke('get-token'),
  getSchedulerPort: () => ipcRenderer.invoke('get-scheduler-port'),
  getAppVersion: () => ipcRenderer.invoke('get-app-version'),
  getStudioInfo: () => ipcRenderer.invoke('get-studio-info'),
  getPrefs: () => ipcRenderer.invoke('get-prefs'),
  setPrefs: (prefs: unknown) => ipcRenderer.invoke('set-prefs', prefs),
  platform: process.platform,
});
