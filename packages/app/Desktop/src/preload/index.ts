import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('electronAPI', {
  // Auth
  getToken: () => ipcRenderer.invoke('get-token'),
  getSchedulerPort: () => ipcRenderer.invoke('get-scheduler-port'),
  getAppVersion: () => ipcRenderer.invoke('get-app-version'),
  platform: process.platform,
});
