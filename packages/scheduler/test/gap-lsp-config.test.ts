// lsp.ts 的配置与错误路（不需要真实语言服务器）：
//   · file 缺失 → 明确报错
//   · TRHA_LSP_CONFIG 坏 JSON / 无匹配扩展名的服务器
//   · TRHA_LSP_COMMAND 强制一个不存在的二进制 → spawn 失败被吃成字符串错误
// 全部走 rejects 断言——错误被 lspQuery 抛出、由调用方（runStandardTool）兜成 ERROR 字符串，
// 这是设计契约：lsp 永不炸进程。
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { lspQuery, shutdownLsp, lspStatus } from '../src/Server/lsp.js';

let dir = '';

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'lsp-cfg-'));
  delete process.env.TRHA_LSP_COMMAND;
  delete process.env.TRHA_LSP_CONFIG;
  delete process.env.TRHA_LSP_ROOT;
});

afterEach(async () => {
  delete process.env.TRHA_LSP_COMMAND;
  delete process.env.TRHA_LSP_CONFIG;
  delete process.env.TRHA_LSP_ROOT;
  shutdownLsp();
  await rm(dir, { recursive: true, force: true });
});

describe('lsp — 配置与错误路（无真实服务器）', () => {
  it('file 缺失 → file is required', async () => {
    await expect(lspQuery({ file: '', operation: 'hover' })).rejects.toThrow('file is required');
  });

  it('TRHA_LSP_CONFIG 坏 JSON → 拒绝（错误被调用方兜底，不炸进程）', async () => {
    const cfg = path.join(dir, 'bad.json');
    await writeFile(cfg, '{servers:');
    process.env.TRHA_LSP_CONFIG = cfg;
    await expect(
      lspQuery({ file: path.join(dir, 'a.ts'), operation: 'hover' }),
    ).rejects.toThrow();
  });

  it('TRHA_LSP_CONFIG 合法但没有任何服务器 → 拒绝（空服务器表）', async () => {
    const cfg = path.join(dir, 'empty.json');
    await writeFile(cfg, JSON.stringify({ servers: {} }));
    process.env.TRHA_LSP_CONFIG = cfg;
    await expect(
      lspQuery({ file: path.join(dir, 'a.ts'), operation: 'hover' }),
    ).rejects.toThrow();
  });

  it('TRHA_LSP_CONFIG 服务器不覆盖该扩展名 → 拒绝', async () => {
    const cfg = path.join(dir, 'py.json');
    await writeFile(cfg, JSON.stringify({
      servers: { py: { command: 'pyright-langserver --stdio', extensions: ['.py'] } },
    }));
    process.env.TRHA_LSP_CONFIG = cfg;
    await expect(
      lspQuery({ file: path.join(dir, 'a.rs'), operation: 'hover' }),
    ).rejects.toThrow();
  });

  it('TRHA_LSP_COMMAND 强制不存在的二进制 → spawn 失败被吃成错误', async () => {
    process.env.TRHA_LSP_COMMAND = 'definitely-missing-lsp-binary --stdio';
    await expect(
      lspQuery({ file: path.join(dir, 'a.ts'), operation: 'hover' }),
    ).rejects.toThrow();
  });

  it('lspStatus / shutdownLsp 可安全反复调用', () => {
    expect(() => { shutdownLsp(); shutdownLsp(); }).not.toThrow();
    expect(lspStatus()).toBeDefined();
  });
});
