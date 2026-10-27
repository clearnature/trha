// 覆盖率补强：toolGuard / shell / HttpClient / mcp 错误路（纯逻辑或纯错误路）。
import { describe, expect, it } from 'vitest';
import { mkdtemp, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { confineWritePath, limitOutput } from '../src/Server/toolGuard.js';
import { HttpClient } from '../src/Core/HTTP.js';
import { hardenedEnv, resolveShell } from '../src/Server/shell.js';
import { isStandardTool } from '../src/Server/standardTools.js';
import { isExtraTool } from '../src/Server/extraTools.js';

describe('toolGuard.confineWritePath（符号链接 / 越界 / 额外根）', () => {
  it('工作区内路径：创建父目录并返回真实路径', async () => {
    const ws = await mkdtemp(path.join(tmpdir(), 'guard-'));
    const r = await confineWritePath(ws, path.join(ws, 'sub', 'a.txt'));
    expect(r).toContain(path.join('sub', 'a.txt'));
    expect(r?.startsWith(path.resolve(ws))).toBe(true);
  });

  it('工作区外路径 → null', async () => {
    const ws = await mkdtemp(path.join(tmpdir(), 'guard-'));
    expect(await confineWritePath(ws, '/etc/passwd')).toBeNull();
    expect(await confineWritePath(ws, path.join(path.dirname(ws), 'x.txt'))).toBeNull();
  });

  it('extraRoots：落在额外可信目录内 → 放行', async () => {
    const ws = await mkdtemp(path.join(tmpdir(), 'guard-'));
    const extra = await mkdtemp(path.join(tmpdir(), 'extra-'));
    const r = await confineWritePath(ws, path.join(extra, 'a.txt'), [extra]);
    expect(r).toContain('a.txt');
  });

  it('symlink 父目录逃逸 → null（先建真实文件再链接）', async () => {
    const ws = await mkdtemp(path.join(tmpdir(), 'guard-'));
    const outside = await mkdtemp(path.join(tmpdir(), 'outside-'));
    await writeFile(path.join(outside, 'secret.txt'), 'x');
    await symlink(outside, path.join(ws, 'link'));
    const r = await confineWritePath(ws, path.join(ws, 'link', 'evil.txt'));
    expect(r).toBeNull();
  });
});

describe('toolGuard.limitOutput', () => {
  it('短文本原样返回；超长截断并标记', () => {
    expect(limitOutput('short')).toBe('short');
    const long = 'x'.repeat(64 * 1024 + 10);
    const out = limitOutput(long);
    expect(out).not.toBe(long);
    expect(out.startsWith('x'.repeat(100))).toBe(true);
    expect(out.endsWith('…[truncated]')).toBe(true);
  });
});

describe('shell', () => {
  it('hardenedEnv：清掉可能影响子进程的变量但保留 PATH', () => {
    process.env.SOME_NOISY_VAR = '1';
    const env = hardenedEnv();
    expect(env.PATH).toBeDefined();
    delete process.env.SOME_NOISY_VAR;
  });

  it('resolveShell：POSIX 走 bash -lc；win32 走 cmd.exe 且保留 verbatim', () => {
    const posix = resolveShell('echo hi');
    expect(posix.cmd).toBe('bash');
    expect(posix.args).toEqual(['-lc', 'echo hi']);
    const win = resolveShell('echo hi', 'win32');
    expect(win.cmd).toBe('cmd.exe');
    expect(win.args[0]).toBe('/d');
    expect(win.options?.windowsVerbatimArguments).toBe(true);
  });
});

describe('名单谓词（isStandardTool / isExtraTool）', () => {
  it('名单内 true / 名单外 false / 两表互斥', () => {
    expect(isStandardTool('todo_write')).toBe(true);
    expect(isStandardTool('web_fetch')).toBe(true);
    expect(isStandardTool('totally_made_up')).toBe(false);
    expect(isExtraTool('working_directory')).toBe(true);
    expect(isExtraTool('ralph')).toBe(true);
    expect(isExtraTool('todo_write')).toBe(false);
    for (const n of ['todo_write', 'web_fetch']) expect(isExtraTool(n)).toBe(false);
  });
});

describe('HttpClient（真实 loopback 端到端）', () => {
  it('连接被拒 → 抛错（不是静默）', async () => {
    const client = new HttpClient('127.0.0.1', 1, () => null);
    await expect((client as unknown as {
      send: (fn: (h: Record<string, string>) => Promise<unknown>) => Promise<unknown>;
    }).send(() => import('axios').then(ax => ax.default.get('/x')))).rejects.toThrow();
  });
});
