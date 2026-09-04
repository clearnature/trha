import { app, BrowserWindow, ipcMain } from 'electron';
import * as path from 'path';
import { spawn, ChildProcess } from 'child_process';

let mainWindow: BrowserWindow | null = null;
let schedulerProcess: ChildProcess | null = null;

// Generate a random token for this session
function generateToken(): string {
  return Math.random().toString(36).substring(2, 15) +
         Math.random().toString(36).substring(2, 15);
}

const SESSION_TOKEN = generateToken();
const SCHEDULER_PORT = 3456;

// Start the scheduler as a child process
function startScheduler(): Promise<void> {
  return new Promise((resolve, reject) => {
    const schedulerPath = path.join(__dirname, '../../../../scheduler/dist/Server/index.js');

    schedulerProcess = spawn('node', [schedulerPath], {
      env: {
        ...process.env,
        GH_HARNESS_TOKEN: SESSION_TOKEN,
        GH_HARNESS_PORT: String(SCHEDULER_PORT),
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    schedulerProcess.stdout?.on('data', (data) => {
      const msg = data.toString();
      console.log(`[Scheduler] ${msg}`);
      if (msg.includes('listening')) {
        resolve();
      }
    });

    schedulerProcess.stderr?.on('data', (data) => {
      console.error(`[Scheduler Error] ${data.toString()}`);
    });

    schedulerProcess.on('error', (err) => {
      console.error('Failed to start scheduler:', err);
      resolve(); // Don't block app startup
    });

    schedulerProcess.on('exit', (code) => {
      console.log(`Scheduler exited with code ${code}`);
      schedulerProcess = null;
    });

    // Timeout: if scheduler doesn't start in 5s, continue anyway
    setTimeout(() => resolve(), 5000);
  });
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'trha Desktop',
  });

  if (process.env.NODE_ENV === 'development') {
    mainWindow.loadURL('http://localhost:3000');
    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// IPC Handlers
ipcMain.handle('get-token', () => SESSION_TOKEN);
ipcMain.handle('get-scheduler-port', () => SCHEDULER_PORT);
ipcMain.handle('get-app-version', () => app.getVersion());

// App lifecycle
app.whenReady().then(async () => {
  await startScheduler();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (schedulerProcess) {
    schedulerProcess.kill();
    schedulerProcess = null;
  }
  if (process.platform !== 'darwin') app.quit();
});
