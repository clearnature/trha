// Browser tools: a real headless Chrome over CDP, against a local page.
//
// The assertion that matters is that this renders *and executes* the page
// (so it is a browser, not an HTTP fetch): the fixture's text only exists after
// JavaScript runs.

import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'vitest';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import path from 'node:path';
import { runStandardTool, type StandardToolHost } from '../src/Server/standardTools.js';
import { browserCloseAll, browserEvaluate } from '../src/Server/browser.js';

const PAGE = `<!doctype html><html><head><title>CDP fixture</title></head>
<body><h1 id="h">Static heading</h1><div id="out"></div>
<script>document.getElementById('out').textContent = 'rendered by script';</script>
</body></html>`;

let server: http.Server;
let base = '';
let dir = '';

const host = (): StandardToolHost => ({ workspace: dir, state: {}, jobs: new Map(), sessionId: 's' });

beforeAll(async () => {
  server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(PAGE);
  });
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/`;
});

afterAll(() => { server.close(); });

beforeEach(async () => { dir = await mkdtemp(path.join(tmpdir(), 'trha-browser-')); });
afterEach(async () => {
  await browserCloseAll();
  await rm(dir, { recursive: true, force: true });
});

describe('browser tools', () => {
  it('navigates, runs the page script, and returns rendered text', async () => {
    const out = await runStandardTool('browser_navigate', { url: base }, host());
    expect(out).toContain('CDP fixture');
    expect(out).toContain('Static heading');
    // only present after JS executes
    expect(out).toContain('rendered by script');
  });

  it('extracts a selector', async () => {
    await runStandardTool('browser_navigate', { url: base }, host());
    const text = await runStandardTool('browser_extract', { selector: '#out' }, host());
    expect(text).toBe('rendered by script');
  });

  it('writes a real PNG screenshot into the workspace', async () => {
    await runStandardTool('browser_navigate', { url: base }, host());
    const out = await runStandardTool('browser_screenshot', { path: 'shot.png' }, host());
    expect(out).toMatch(/^OK: screenshot/);
    const bytes = await readFile(path.join(dir, 'shot.png'));
    expect(bytes.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a');   // PNG magic
    expect(bytes.byteLength).toBeGreaterThan(1000);
  });

  it('rejects a non-http url instead of launching a browser', async () => {
    const out = await runStandardTool('browser_navigate', { url: 'file:///etc/passwd' }, host());
    expect(out).toMatch(/^ERROR: url must be http/);
  });
});

describe('browser isolation between sessions', () => {
  let dirA = '';
  let dirB = '';
  const hostFor = (sessionId: string, workspace: string): StandardToolHost =>
    ({ workspace, state: {}, jobs: new Map(), sessionId });

  beforeAll(async () => {
    dirA = await mkdtemp(path.join(tmpdir(), 'trha-ba-'));
    dirB = await mkdtemp(path.join(tmpdir(), 'trha-bb-'));
  });
  afterAll(async () => {
    await browserCloseAll();
    await rm(dirA, { recursive: true, force: true });
    await rm(dirB, { recursive: true, force: true });
  });

  it('gives each session its own tab, so a navigate in one cannot change the other', async () => {
    const a = hostFor('session-A', dirA);
    const b = hostFor('session-B', dirB);

    await runStandardTool('browser_navigate', { url: `${base}?who=A` }, a);
    await runStandardTool('browser_navigate', { url: `${base}?who=B` }, b);

    // B navigating after A must not move A's page
    const seenByA = await runStandardTool('browser_extract', { selector: '#out' }, a);
    const seenByB = await runStandardTool('browser_extract', { selector: '#out' }, b);
    const urlA = await browserEvaluate('session-A', 'location.href');
    const urlB = await browserEvaluate('session-B', 'location.href');
    expect(seenByA).toBe('rendered by script');
    expect(seenByB).toBe('rendered by script');
    expect(urlA).toContain('who=A');
    expect(urlB).toContain('who=B');
  });

  it('closing one session leaves the other page alive', async () => {
    const a = hostFor('session-C', dirA);
    const b = hostFor('session-D', dirB);
    await runStandardTool('browser_navigate', { url: `${base}?who=C` }, a);
    await runStandardTool('browser_navigate', { url: `${base}?who=D` }, b);

    expect(await runStandardTool('browser_close', {}, a)).toMatch(/closed for this session/);

    // B still has its page; A gets a fresh one on next use
    expect(await browserEvaluate('session-D', 'location.href')).toContain('who=D');
    await runStandardTool('browser_navigate', { url: `${base}?who=C2` }, a);
    expect(await browserEvaluate('session-C', 'location.href')).toContain('who=C2');
  });
});
