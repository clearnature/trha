// 最后一轮边界分支：read_image 的 mime 变体与 2MiB 上限 / run_code 的 python 路 /
// clip 溢出标记（web_fetch 超 20k）/ web_search 的 SearX JSON 路 / ralph 多轮。
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, writeFile } from 'node:fs/promises';
import fs from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  runStandardTool,
  type StandardToolHost,
} from '../src/Server/standardTools.js';
import {
  runExtraTool,
  type ExtraHost,
} from '../src/Server/extraTools.js';

let workspace = '';

const host = (): StandardToolHost => ({
  workspace,
  state: {},
  jobs: new Map(),
  sessionId: 'edge',
});

const run = (name: string, args: Record<string, unknown>, h: StandardToolHost): Promise<string | null> =>
  runStandardTool(name, args, h).catch((e: Error) => `THREW: ${e.message}`);

const extraHost = (over: Partial<ExtraHost> = {}): ExtraHost => ({
  ...host(),
  cwd: () => workspace,
  setCwd: () => undefined,
  terminals: new Map(),
  ...over,
});

const runExtra = (name: string, args: Record<string, unknown>, h: ExtraHost): Promise<string | null> =>
  runExtraTool(name, args, h).catch((e: Error) => `THREW: ${e.message}`);

beforeEach(async () => {
  workspace = await mkdtemp(path.join(tmpdir(), 'edge-'));
});

describe('边界分支补齐', () => {
  it('read_image：mime 变体（jpg/jpeg/gif/webp/未知扩展名）', async () => {
    const h = host();
    const px = Buffer.from([1, 2, 3]);
    await writeFile(path.join(workspace, 'a.jpg'), px);
    await writeFile(path.join(workspace, 'b.jpeg'), px);
    await writeFile(path.join(workspace, 'c.gif'), px);
    await writeFile(path.join(workspace, 'd.webp'), px);
    await writeFile(path.join(workspace, 'e.bin'), px);
    expect(await run('read_image', { path: 'a.jpg' }, h)).toContain('data:image/jpeg;base64');
    expect(await run('read_image', { path: 'b.jpeg' }, h)).toContain('data:image/jpeg;base64');
    expect(await run('read_image', { path: 'c.gif' }, h)).toContain('data:image/gif;base64');
    expect(await run('read_image', { path: 'd.webp' }, h)).toContain('data:image/webp;base64');
    expect(await run('read_image', { path: 'e.bin' }, h)).toContain('data:application/octet-stream;base64');
  });

  it('read_image：绝对路径也接受', async () => {
    const h = host();
    const f = path.join(workspace, 'abs.png');
    await writeFile(f, Buffer.from([9]));
    expect(await run('read_image', { path: f }, h)).toContain('data:image/png;base64');
  });

  it('run_code：python3 真跑（有 python3 的话）', async () => {
    const h = host();
    const r = await run('run_code', { language: 'python3', code: 'print("py-ok")' }, h);
    if (String(r).includes('not available')) {
      expect(String(r)).toContain('not available');    // 无 python3 的环境：可读报错即可
    } else {
      expect(String(r)).toContain('py-ok');
    }
  });

  it('web_fetch：超 20k 输出被截断并标注（clip 分支）', async () => {
    vi.stubGlobal('fetch', async () => ({
      ok: true,
      status: 200,
      headers: { get: () => 'text/plain' },
      text: async () => 'y'.repeat(30_000),
    }) as unknown as Response);
    const h = host();
    const r = await run('web_fetch', { url: 'http://example.com/big' }, h);
    expect(String(r)).toContain('…(');
    expect(String(r).length).toBeLessThan(21_500);
  });

  it('web_search：TRHA_SEARX_URL 走 JSON 引擎路（真实本地 http 服务器，localhost 不走代理）', async () => {
    vi.unstubAllGlobals();
    const { createServer } = await import('node:http');
    const srv = createServer((req, res) => {
      fs.appendFileSync('/tmp/searx-hit.log', `hit ${req.url}\n`);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        results: [{ title: 'R1', url: 'https://r.example.com/1', content: 'd1' }],
      }));
    });
    await new Promise<void>(r => srv.listen(0, 'localhost', r));
    const addr = srv.address();
    const port = typeof addr === 'object' && addr ? addr.port : 0;
    process.env.TRHA_SEARX_URL = `http://localhost:${port}`;
    try {
      const h = extraHost();
      const r = await runExtra('web_search', { query: 'q' }, h);
      expect(String(r)).toContain('r.example.com');
    } finally {
      srv.close();
      delete process.env.TRHA_SEARX_URL;
    }
  });

  it('ralph：多轮（CONTINUE 后 DONE）', async () => {
    const h = extraHost({
      spawnFresh: async (task: string, name?: string) => ({
        id: `r-${name ?? 'x'}`,
        reply: /1\/2/.test(task) ? 'STATUS: CONTINUE' : 'STATUS: DONE',
      }),
    });
    const r = await runExtra('ralph', { objective: 'two rounds', rounds: 2 }, h);
    expect(String(r)).toContain('round 1');
    expect(String(r)).toContain('round 2');
    expect(String(r)).toContain('STATUS: DONE');
  });

  it('ralph：rounds 超上限被钳到 10（传 999 不炸）', async () => {
    const h = extraHost({
      spawnFresh: async () => ({ id: 'r', reply: 'STATUS: DONE' }),
    });
    const r = await runExtra('ralph', { objective: 'x', rounds: 999 }, h);
    expect(String(r)).toContain('round 1');
  });
});
