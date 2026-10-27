import { app, BrowserWindow, dialog, ipcMain, Menu } from 'electron';
import type { MenuItemConstructorOptions } from 'electron';
import { isSupported, parseHandshake } from './handshake.js';
import { StudioInfo, fetchStudioInfo } from './studioInfo.js';
import * as path from 'path';
import { spawn, ChildProcess } from 'child_process';
import { closeSync, mkdirSync, openSync } from 'node:fs';
import { homedir } from 'node:os';
import {
  resolveSchedulerToken,
  runningSchedulerPid,
  stopAll,
  stopResultText,
} from './services.js';

let mainWindow: BrowserWindow | null = null;
let schedulerProcess: ChildProcess | null = null;
let studioInfo: StudioInfo | null = null;

// Generate a random token for this session
function generateToken(): string {
  return Math.random().toString(36).substring(2, 15) +
         Math.random().toString(36).substring(2, 15);
}

const SCHEDULER_PORT = 28433;
const SESSION_TOKEN = generateToken();

// The scheduler serves HTTPS with a self-signed loopback certificate.
// Accept it for loopback only; remote origins keep normal validation.
app.on('certificate-error', (event, _webContents, url, _error, _certificate, callback) => {
  let host = '';
  try { host = new URL(url).hostname; } catch { /* malformed: reject below */ }
  if (host === '127.0.0.1' || host === 'localhost') {
    event.preventDefault();
    callback(true);
    return;
  }
  callback(false);
});

// ── Local prefs (theme/lang/font size) persisted under userData ──────────
function prefsFile(): string {
  return path.join(app.getPath('userData'), 'prefs.json');
}

function readPrefs(): unknown {
  try {
    return JSON.parse(require('node:fs').readFileSync(prefsFile(), 'utf8'));
  } catch {
    return null;
  }
}

function writePrefs(prefs: unknown): void {
  try {
    const fs = require('node:fs');
    const file = prefsFile();
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(prefs), 'utf8');
    fs.renameSync(tmp, file); // atomic replace
  } catch (e) {
    console.error('[prefs] write failed:', (e as Error).message);
  }
}

// Resolve the scheduler launcher: packaged builds keep the scheduler dist
// under resources/scheduler (see electron-builder extraResources and
// scripts/sync-scheduler.mjs); development uses the sibling checkout.
// The bundled node runtime (resources/node) when packaged; the system
// `node` in development.  win ships node.exe, mac/linux node.
function schedulerRuntime(): string | null {
  if (!app.isPackaged) return null;
  const dir = path.join(process.resourcesPath, 'node');
  for (const name of process.platform === 'win32' ? ['node.exe', 'node'] : ['node', 'node.exe']) {
    const candidate = path.join(dir, name);
    try {
      if (require('node:fs').existsSync(candidate)) return candidate;
    } catch { /* keep scanning */ }
  }
  return null;
}

function schedulerEntry(): string {
  if (process.env.TRHA_SCHEDULER_PATH) return process.env.TRHA_SCHEDULER_PATH;
  if (app.isPackaged) {
    return path.join(process.resourcesPath, 'scheduler', 'cli.js');
  }
  return path.join(__dirname, '../../../../scheduler/dist/cli.js');
}

// Start (or reuse) the scheduler.
//
// **Reuse**: if a scheduler is already running on this machine it is shared
// with the TUI and Web shells.  Desktop does not spawn a second one and does
// not take it over.
//
// **Ownership**: a scheduler spawned here is detached and does not use the
// stdin lease, so quitting Desktop (which only closes the shell) leaves it
// running for the other shells.  `Services → Stop kernel and scheduler…`
// is the explicit way to stop it.
function schedulerLogFd(): number {
  const dir = path.join(homedir(), '.trha', 'logs');
  mkdirSync(dir, { recursive: true });
  return openSync(path.join(dir, 'desktop-scheduler.log'), 'a');
}

function startScheduler(): Promise<void> {
  const running = runningSchedulerPid();
  if (running) {
    console.error(`[scheduler] reusing running scheduler (pid ${running})`);
    schedulerProcess = null;
    return Promise.resolve();
  }

  return new Promise((resolve, reject) => {
    const schedulerPath = schedulerEntry();
    const logFd = schedulerLogFd();

    schedulerProcess = spawn(schedulerRuntime() ?? 'node', [schedulerPath], {
      // Detached: closing Desktop must not take the shared services with it.
      detached: true,
      env: {
        ...process.env,
        TRHA_TOKEN: SESSION_TOKEN,
        TRHA_PORT: String(SCHEDULER_PORT),
        // Session persistence (G2). Without this the scheduler runs in
        // memory-only mode and a restart loses live conversations.
        TRHA_STATE_DIR: process.env.TRHA_STATE_DIR ?? path.join(app.getPath('userData'), 'sessions'),
        // Kernel endpoint. 19433 is the `trha serve --kernel-port` default and
        // is deliberately distinct from SCHEDULER_PORT (28433).
        TRHA_LLM_HOST: process.env.TRHA_LLM_HOST ?? '127.0.0.1',
        TRHA_LLM_PORT: process.env.TRHA_LLM_PORT ?? '19433',
        // Plugin directory scan + hot reload (otherwise undefined => disabled).
        TRHA_PLUGINS_DIR: process.env.TRHA_PLUGINS_DIR ?? path.join(app.getPath('userData'), 'plugins'),
      },
      // stdout: handshake only (read below); stderr: log file (survives us).
      stdio: ['ignore', 'pipe', logFd],
    });
    closeSync(logFd);

    let stdoutHead = '';
    let settled = false;
    const settle = (err: Error | null) => {
      if (settled) return;
      settled = true;
      if (err) {
        console.error('[scheduler] refusing to start:', err.message);
        schedulerProcess?.kill();
        schedulerProcess = null;
        reject(err);
      } else {
        resolve();
      }
    };

    schedulerProcess.stdout?.on('data', (data) => {
      stdoutHead += data.toString();
      if (settled) return;
      const nl = stdoutHead.indexOf('\n');
      if (nl === -1) return;
      const handshake = parseHandshake(stdoutHead.slice(0, nl));
      if (!handshake) {
        settle(new Error(`unexpected scheduler stdout: ${stdoutHead.slice(0, 120)}`));
      } else if (!isSupported(handshake)) {
        settle(new Error(`unsupported scheduler handshake v${handshake.v} (${handshake.name})`));
      } else {
        // The handshake is the only line we need from this child; detach so
        // closing Desktop does not close its pipes or take it down.
        schedulerProcess?.unref();
        settle(null);
      }
      // beyond the handshake line, stdout is ignored (contract: one line only)
    });

    schedulerProcess.stderr?.on('data', (data) => {
      console.error(`[scheduler] ${data.toString().trimEnd()}`);
    });

    schedulerProcess.on('error', (err) => {
      console.error('Failed to start scheduler:', err);
      settle(null); // don't block app startup on spawn errors
    });

    schedulerProcess.on('exit', (_code) => {
      schedulerProcess = null;
    });

    // Timeout: if the scheduler does not handshake in 5s, fail loudly.
    setTimeout(() => {
      if (!settled) settle(new Error('scheduler handshake timeout (5s)'));
    }, 5000);
  });
}

// After the handshake, fetch the version surface for the UI (P4).  Fires
// and forgets: a failure only logs on stderr.
async function refreshStudioInfo(): Promise<void> {
  try {
    studioInfo = await fetchStudioInfo(SCHEDULER_PORT);
    console.error(`[studio] kernel ${studioInfo.current}${studioInfo.pinned ? ` pinned=${studioInfo.pinned}` : ''}`);
  } catch (e) {
    console.error('[studio] version fetch failed:', (e as Error).message);
  }
}

// stdin lease is gone on purpose: Desktop owns only its own window.  Shared
// services are stopped explicitly from the Services menu (or `trha stop`).

function buildMenu(): void {
  const template: MenuItemConstructorOptions[] = [
    {
      label: 'Services',
      submenu: [
        {
          label: 'Stop kernel and scheduler…',
          accelerator: 'CommandOrControl+Shift+Q',
          click: () => {
            void confirmAndStop();
          },
        },
        { type: 'separator' },
        { role: 'quit', label: 'Quit Desktop' },
      ],
    },
    { role: 'editMenu' },
    { role: 'viewMenu' },
    { role: 'windowMenu' },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// The Desktop equivalent of the TUI's `/stop confirm`: one confirmation, stop
// both services, then close the shell.
async function confirmAndStop(): Promise<void> {
  const { response } = await dialog.showMessageBox({
    type: 'warning',
    buttons: ['Cancel', 'Stop services'],
    defaultId: 0,
    cancelId: 0,
    message: 'Stop the kernel and scheduler?',
    detail:
      'Both background services stop and other shells (TUI, Web) disconnect. '
      + 'Quitting Desktop alone leaves them running.',
  });
  if (response !== 1) return;
  const results = await stopAll();
  await dialog.showMessageBox({
    type: 'info',
    message: 'Services',
    detail: results.map(stopResultText).join('\n'),
  });
  app.quit();
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
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
ipcMain.handle('get-token', () => resolveSchedulerToken() ?? SESSION_TOKEN);
ipcMain.handle('get-scheduler-port', () => SCHEDULER_PORT);
ipcMain.handle('get-app-version', () => app.getVersion());
ipcMain.handle('get-studio-info', () => studioInfo);
ipcMain.handle('get-prefs', () => readPrefs());
ipcMain.handle('set-prefs', (_e, prefs) => { writePrefs(prefs); });

// App lifecycle
app.whenReady().then(async () => {
  buildMenu();
  await startScheduler();
  void refreshStudioInfo();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

// Quit closes this shell only: the scheduler and kernel keep serving the TUI
// and Web shells.  `Services → Stop kernel and scheduler…` stops them.

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
