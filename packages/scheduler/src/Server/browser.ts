// Minimal browser tool over Chrome DevTools Protocol.
//
// Ported semantics from deepseek-harness's stagehand/browser tools at the layer
// that matters for a coding agent: open a page, read its text, take a
// screenshot, close. No DOM-level "act" DSL — that needs a planner we do not
// have — but what is here is a real browser, not an HTTP fetch.
//
// Browser: TRHA_BROWSER (default: first of chromium / google-chrome).
// Each call reuses one headless instance; `browser_close` stops it.

import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

interface Cdp {
  child: ChildProcess;
  ws: WebSocket;
  nextId: number;
  pending: Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>;
  profile: string;
}

let session: Cdp | undefined;
let starting: Promise<Cdp> | undefined;

const browserBin = (): string => process.env.TRHA_BROWSER ?? 'chromium';

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

async function launch(): Promise<Cdp> {
  const port = await freePort();
  const profile = await mkdtemp(path.join(tmpdir(), 'trha-chrome-'));
  const child = spawn(browserBin(), [
    '--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
    `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  child.stderr?.on('data', () => { /* chrome is chatty; ignore */ });
  // Without this a bad TRHA_BROWSER waits the full 15 s for a port that will
  // never open; the spawn error is the real answer.
  let launchError: string | undefined;
  child.on('error', e => { launchError = e.message; });
  child.on('exit', code => {
    if (code !== null && code !== 0 && !launchError) launchError = `browser exited (${code})`;
  });

  const deadline = Date.now() + 15_000;
  let wsUrl = '';
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/list`);
      const list = (await res.json()) as Array<{ type?: string; webSocketDebuggerUrl?: string }>;
      const page = list.find(t => t.type === 'page' && t.webSocketDebuggerUrl);
      if (page?.webSocketDebuggerUrl) { wsUrl = page.webSocketDebuggerUrl; break; }
    } catch { /* not up yet */ }
    if (launchError) break;
    await new Promise(r => setTimeout(r, 150));
  }
  if (!wsUrl) {
    child.kill('SIGKILL');
    await rm(profile, { recursive: true, force: true }).catch(() => {});
    throw new Error(`browser did not start (${browserBin()})${launchError ? `: ${launchError}` : ''}`);
  }

  const ws = new WebSocket(wsUrl);
  const cdp: Cdp = { child, ws, nextId: 1, pending: new Map(), profile };
  await new Promise<void>((resolve, reject) => {
    ws.addEventListener('open', () => resolve(), { once: true });
    ws.addEventListener('error', () => reject(new Error('browser websocket failed')), { once: true });
  });
  ws.addEventListener('message', event => {
    const msg = JSON.parse(String((event as MessageEvent).data)) as {
      id?: number; result?: unknown; error?: { message: string };
    };
    if (msg.id === undefined) return;
    const waiter = cdp.pending.get(msg.id);
    if (!waiter) return;
    cdp.pending.delete(msg.id);
    if (msg.error) waiter.reject(new Error(msg.error.message));
    else waiter.resolve(msg.result);
  });
  child.on('exit', () => { session = undefined; });
  session = cdp;
  return cdp;
}

async function ensure(): Promise<Cdp> {
  if (session) return session;
  starting ??= launch().finally(() => { starting = undefined; });
  return starting;
}

function send(cdp: Cdp, method: string, params: Record<string, unknown> = {}): Promise<unknown> {
  const id = cdp.nextId++;
  return new Promise((resolve, reject) => {
    cdp.pending.set(id, { resolve, reject });
    const timer = setTimeout(() => {
      if (cdp.pending.delete(id)) reject(new Error(`CDP ${method} timed out`));
    }, 20_000);
    timer.unref?.();
    cdp.ws.send(JSON.stringify({ id, method, params }));
  });
}

export interface BrowserPage {
  url: string;
  title: string;
  text: string;
}

/** Navigate and return the rendered text (what a reader would see). */
export async function browserNavigate(url: string): Promise<BrowserPage> {
  if (!/^https?:\/\//i.test(url)) throw new Error('url must be http(s)');
  const cdp = await ensure();
  await send(cdp, 'Page.enable');
  await send(cdp, 'Page.navigate', { url });
  // Wait for the load event, then let the microtask queue settle.
  await new Promise<void>(resolve => {
    const onMsg = (event: MessageEvent): void => {
      const msg = JSON.parse(String(event.data)) as { method?: string };
      if (msg.method === 'Page.loadEventFired') {
        cdp.ws.removeEventListener('message', onMsg);
        resolve();
      }
    };
    cdp.ws.addEventListener('message', onMsg);
    setTimeout(() => {
      cdp.ws.removeEventListener('message', onMsg);
      resolve();
    }, 10_000).unref?.();
  });
  const evaluated = (await send(cdp, 'Runtime.evaluate', {
    expression: 'JSON.stringify({title: document.title, text: document.body ? document.body.innerText : ""})',
    returnByValue: true,
  })) as { result?: { value?: string } };
  const parsed = JSON.parse(evaluated.result?.value ?? '{}') as { title?: string; text?: string };
  return { url, title: parsed.title ?? '', text: parsed.text ?? '' };
}

/** Evaluate a JS expression in the current page and return its string value. */
export async function browserEvaluate(expression: string): Promise<string> {
  const cdp = await ensure();
  const evaluated = (await send(cdp, 'Runtime.evaluate', {
    expression, returnByValue: true, awaitPromise: true,
  })) as { result?: { value?: unknown } };
  const v = evaluated.result?.value;
  return typeof v === 'string' ? v : JSON.stringify(v ?? null);
}

/** Extract one CSS selector's text, or the whole body when omitted. */
export async function browserExtract(selector?: string): Promise<string> {
  const cdp = await ensure();
  const expression = selector
    ? `(() => { const el = document.querySelector(${JSON.stringify(selector)}); return el ? el.innerText : ''; })()`
    : 'document.body ? document.body.innerText : ""';
  const evaluated = (await send(cdp, 'Runtime.evaluate', {
    expression, returnByValue: true,
  })) as { result?: { value?: string } };
  return (evaluated.result?.value ?? '').toString();
}

/** Screenshot into the workspace; returns the absolute path written. */
export async function browserScreenshot(workspace: string, relPath?: string): Promise<string> {
  const cdp = await ensure();
  const shot = (await send(cdp, 'Page.captureScreenshot', { format: 'png' })) as { data?: string };
  const data = shot.data ?? '';
  if (!data) throw new Error('screenshot returned no data');
  const target = path.resolve(workspace, relPath ?? `.trha-shot-${Date.now()}.png`);
  await writeFile(target, Buffer.from(data, 'base64'));
  return target;
}

export function browserClose(): void {
  if (!session) return;
  const { child, ws, profile } = session;
  session = undefined;
  try { ws.close(); } catch { /* ignore */ }
  try { child.kill('SIGTERM'); } catch { /* ignore */ }
  void rm(profile, { recursive: true, force: true }).catch(() => {});
}
