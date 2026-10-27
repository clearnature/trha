// Headless Chrome over CDP, one tab per agent session.
//
// A single shared page looked fine in tests and was wrong in practice: session A
// navigating to a.com while B navigates to b.com means B's extract reads A's
// page. Each scheduler session now gets its own target (tab) inside one browser
// process, and all commands/events are routed by the CDP session id that
// `Target.attachToTarget {flatten: true}` returns.
//
// Browser: TRHA_BROWSER (default chromium).

import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { confineWritePath } from './toolGuard.js';

interface Page {
  targetId: string;
  cdpSession: string;
}

interface Browser {
  child: ChildProcess;
  ws: WebSocket;
  nextId: number;
  pending: Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>;
  /** scheduler session id -> its tab */
  pages: Map<string, Page>;
  /** cdp session id -> resolve, for the pending load event */
  loadWaiters: Map<string, () => void>;
  profile: string;
}

let browser: Browser | undefined;
let starting: Promise<Browser> | undefined;

/**
 * Binaries tried in order.  The old default was a bare `chromium`, which is
 * absent on Debian/Ubuntu images that ship `chromium-browser` (a wrapper) or a
 * preinstalled Google Chrome under /opt — so every browser_* tool failed there
 * with "browser did not start (chromium)".  TRHA_BROWSER, when set, is the only
 * candidate: an explicit override must fail loudly instead of silently using
 * something else.
 */
export function browserCandidates(): string[] {
  const forced = process.env.TRHA_BROWSER?.trim();
  if (forced) return [forced];
  if (process.platform === 'win32') {
    return [
      'chrome.exe',
      'msedge.exe',
      'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    ];
  }
  if (process.platform === 'darwin') {
    return [
      'google-chrome',
      'chromium',
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
    ];
  }
  return [
    'chromium',
    'chromium-browser',
    'google-chrome',
    'google-chrome-stable',
    '/opt/google/chrome/chrome',
  ];
}

/** An ephemeral loopback port for the CDP endpoint. */
async function freePort(): Promise<number> {
  const net = await import('node:net');
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close(() => resolve(port));
    });
  });
}

/** Identical for every candidate: only the port and profile differ. */
const launchArgs = (port: number, profile: string): string[] => [
  '--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, 'about:blank',
];

/** Poll the CDP endpoint until it answers, the attempt fails, or time is up. */
async function waitForCdp(port: number, failed: () => string | undefined, timeoutMs: number): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const err = failed();
    if (err) throw new Error(err);
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      const info = (await res.json()) as { webSocketDebuggerUrl?: string };
      if (info.webSocketDebuggerUrl) return info.webSocketDebuggerUrl;
    } catch { /* not up yet */ }
    await new Promise(r => setTimeout(r, 150));
  }
  throw new Error(`no CDP endpoint on port ${port} after ${timeoutMs} ms`);
}

async function launch(): Promise<Browser> {
  const failures: string[] = [];
  for (const bin of browserCandidates()) {
    // Fresh port and profile per attempt: a half-started browser from an earlier
    // candidate must not make the next one look broken.
    const port = await freePort();
    const profile = await mkdtemp(path.join(tmpdir(), 'trha-chrome-'));
    const child = spawn(bin, launchArgs(port, profile), { stdio: ['ignore', 'ignore', 'pipe'] });
    child.stderr?.on('data', () => { /* chrome is chatty; ignore */ });

    let launchError: string | undefined;
    child.on('error', e => { launchError = e.message; });
    child.on('exit', code => {
      if (code !== null && code !== 0 && !launchError) launchError = `exited (${code})`;
    });

    // Browser-level endpoint: targets are created through it, so one connection
    // serves every session's tab.
    let wsUrl = '';
    try {
      wsUrl = await waitForCdp(port, () => launchError, 6_000);
    } catch (e) {
      child.kill('SIGKILL');
      await rm(profile, { recursive: true, force: true }).catch(() => {});
      failures.push(`${bin}: ${(e as Error).message}`);
      continue;
    }

    const ws = new WebSocket(wsUrl);
    const b: Browser = { child, ws, nextId: 1, pending: new Map(), pages: new Map(), loadWaiters: new Map(), profile };
    try {
      await new Promise<void>((resolve, reject) => {
        ws.addEventListener('open', () => resolve(), { once: true });
        ws.addEventListener('error', () => reject(new Error('browser websocket failed')), { once: true });
      });
    } catch (e) {
      child.kill('SIGKILL');
      await rm(profile, { recursive: true, force: true }).catch(() => {});
      failures.push(`${bin}: ${(e as Error).message}`);
      continue;
    }
    ws.addEventListener('message', event => {
      const msg = JSON.parse(String((event as MessageEvent).data)) as {
        id?: number; method?: string; sessionId?: string; result?: unknown; error?: { message: string };
      };
      if (msg.method === 'Page.loadEventFired' && msg.sessionId) {
        b.loadWaiters.get(msg.sessionId)?.();
        return;
      }
      if (msg.id === undefined) return;
      const waiter = b.pending.get(msg.id);
      if (!waiter) return;
      b.pending.delete(msg.id);
      if (msg.error) waiter.reject(new Error(msg.error.message));
      else waiter.resolve(msg.result);
    });
    // Only the *live* browser may clear the singleton: an earlier candidate's
    // SIGKILLed child exits later and must not blank the one that worked.
    child.on('exit', () => { if (browser?.child === child) browser = undefined; });
    browser = b;
    return b;
  }
  throw new Error(
    `no usable browser (tried ${failures.join('; ')}) — install Chrome/Chromium or set TRHA_BROWSER to one`,
  );
}

async function ensure(): Promise<Browser> {
  if (browser) return browser;
  starting ??= launch().finally(() => { starting = undefined; });
  return starting;
}

/** Send a command, optionally inside one tab's CDP session. */
function send(b: Browser, method: string, params: Record<string, unknown> = {}, cdpSession?: string): Promise<unknown> {
  const id = b.nextId++;
  return new Promise((resolve, reject) => {
    b.pending.set(id, { resolve, reject });
    const timer = setTimeout(() => {
      if (b.pending.delete(id)) reject(new Error(`CDP ${method} timed out`));
    }, 20_000);
    timer.unref?.();
    b.ws.send(JSON.stringify({ id, method, params, ...(cdpSession ? { sessionId: cdpSession } : {}) }));
  });
}

/** The calling session's tab, created on first use. */
async function pageFor(scope: string): Promise<{ b: Browser; page: Page }> {
  const b = await ensure();
  const existing = b.pages.get(scope);
  if (existing) return { b, page: existing };

  const created = (await send(b, 'Target.createTarget', { url: 'about:blank' })) as { targetId: string };
  const attached = (await send(b, 'Target.attachToTarget', {
    targetId: created.targetId, flatten: true,
  })) as { sessionId: string };
  const page: Page = { targetId: created.targetId, cdpSession: attached.sessionId };
  b.pages.set(scope, page);
  await send(b, 'Page.enable', {}, page.cdpSession);
  return { b, page };
}

export interface BrowserPage {
  url: string;
  title: string;
  text: string;
}

/** Navigate this session's tab and return the rendered text. */
export async function browserNavigate(scope: string, url: string): Promise<BrowserPage> {
  if (!/^https?:\/\//i.test(url)) throw new Error('url must be http(s)');
  const { b, page } = await pageFor(scope);
  await send(b, 'Page.navigate', { url }, page.cdpSession);
  // Wait for this tab's load event only: another session's navigation must not
  // release this waiter.
  await new Promise<void>(resolve => {
    let settled = false;
    const done = (): void => {
      if (settled) return;
      settled = true;
      b.loadWaiters.delete(page.cdpSession);
      resolve();
    };
    b.loadWaiters.set(page.cdpSession, done);
    setTimeout(done, 10_000).unref?.();
  });
  const evaluated = (await send(b, 'Runtime.evaluate', {
    expression: 'JSON.stringify({title: document.title, text: document.body ? document.body.innerText : ""})',
    returnByValue: true,
  }, page.cdpSession)) as { result?: { value?: string } };
  const parsed = JSON.parse(evaluated.result?.value ?? '{}') as { title?: string; text?: string };
  return { url, title: parsed.title ?? '', text: parsed.text ?? '' };
}

/** Evaluate JS in this session's tab and return its string value. */
export async function browserEvaluate(scope: string, expression: string): Promise<string> {
  const { b, page } = await pageFor(scope);
  const evaluated = (await send(b, 'Runtime.evaluate', {
    expression, returnByValue: true, awaitPromise: true,
  }, page.cdpSession)) as { result?: { value?: unknown } };
  const v = evaluated.result?.value;
  return typeof v === 'string' ? v : JSON.stringify(v ?? null);
}

/** Extract one CSS selector's text, or the whole body when omitted. */
export async function browserExtract(scope: string, selector?: string): Promise<string> {
  const expression = selector
    ? `(() => { const el = document.querySelector(${JSON.stringify(selector)}); return el ? el.innerText : ''; })()`
    : 'document.body ? document.body.innerText : ""';
  return browserEvaluate(scope, expression);
}

/** Screenshot this session's tab into the workspace (writes stay confined). */
export async function browserScreenshot(scope: string, workspace: string, relPath?: string): Promise<string> {
  const { b, page } = await pageFor(scope);
  const shot = (await send(b, 'Page.captureScreenshot', { format: 'png' }, page.cdpSession)) as { data?: string };
  const data = shot.data ?? '';
  if (!data) throw new Error('screenshot returned no data');
  const requested = path.resolve(workspace, relPath ?? `.trha-shot-${Date.now()}.png`);
  const target = await confineWritePath(workspace, requested);
  if (!target) throw new Error('screenshot path escapes the workspace');
  await writeFile(target, Buffer.from(data, 'base64'));
  return target;
}

/** Close one session's tab (the browser stays up for the others). */
export async function browserClose(scope: string): Promise<void> {
  const b = browser;
  if (!b) return;
  const page = b.pages.get(scope);
  if (!page) return;
  b.pages.delete(scope);
  try { await send(b, 'Target.closeTarget', { targetId: page.targetId }); } catch { /* gone already */ }
}

/** Close every tab and the browser process. */
export async function browserCloseAll(): Promise<void> {
  const b = browser;
  browser = undefined;
  if (!b) return;
  for (const page of b.pages.values()) {
    try { await send(b, 'Target.closeTarget', { targetId: page.targetId }); } catch { /* ignore */ }
  }
  b.pages.clear();
  try { b.ws.close(); } catch { /* ignore */ }
  try { b.child.kill('SIGTERM'); } catch { /* ignore */ }
  void rm(b.profile, { recursive: true, force: true }).catch(() => {});
}
