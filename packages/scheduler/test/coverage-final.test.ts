// 覆盖率收尾补丁：fake-mcp 的 error 应答路（mcp.ts 的 error-reject 分支）
// + Plugins/watcher.computePlan（纯函数：added/removed/changed 三分类）。
import { afterEach, describe, expect, it } from 'vitest';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  listMcpResources,
  shutdownMcp,
  mcpStatus,
} from '../src/Server/mcp.js';
import { computePlan } from '../src/Plugins/watcher.js';
import type { FileState } from '../src/Plugins/watcher.js';

let dir = '';

afterEach(() => {
  delete process.env.FAKE_MCP_FAIL;
  delete process.env.TRHA_MCP_CONFIG;
  shutdownMcp();
});

describe('mcp：server 返回 error response（cfg.env 注入失败模式）', () => {
  it('resources/list 回 error → MCP fs: boom 被拒（不炸进程）', async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'mcp-fail-'));
    const cfg = path.join(dir, 'mcp.json');
    await writeFile(cfg, JSON.stringify({
      servers: {
        fs: {
          command: 'node',
          args: [path.resolve('test/helpers/fake-mcp.mjs')],
          env: { FAKE_MCP_FAIL: '1' },
        },
      },
    }));
    process.env.TRHA_MCP_CONFIG = cfg;
    // fake-mcp 在 FAKE_MCP_FAIL=1 时对 resources/list 回 error → mcp.ts 走
    // `waiter.reject(new Error('MCP fs: boom'))` 路径（error-reject 分支）
    await expect(listMcpResources()).rejects.toThrow('MCP fs: boom');
    // 客户端仍在（pending 清空，client 保留），后续状态可查
    const st = await mcpStatus();
    expect(st.connected).toContain('fs');
  });
});

describe('Plugins/watcher.computePlan（纯函数三分分类）', () => {
  const st = (mtimeMs: number, pluginName?: string): FileState => ({ mtimeMs, pluginName });

  it('新增：磁盘有、已知无 → added', () => {
    const known = new Map<string, FileState>();
    const seen = new Map<string, FileState>([['/p/a.js', st(5)]]);
    expect(computePlan(known, seen)).toEqual({
      added: ['/p/a.js'], removed: [], changed: [],
    });
  });

  it('移除：已知有、磁盘无 → removed（按 pluginName）', () => {
    const known = new Map<string, FileState>([['/p/old.js', st(1, 'old-plugin')]]);
    const seen = new Map<string, FileState>();
    expect(computePlan(known, seen)).toEqual({
      added: [], removed: ['old-plugin'], changed: [],
    });
  });

  it('变更：mtime 前进 → changed；mtime 不变 → 忽略', () => {
    const known = new Map<string, FileState>([
      ['/p/touched.js', st(10, 'touched')],
      ['/p/same.js', st(20, 'same')],
    ]);
    const seen = new Map<string, FileState>([
      ['/p/touched.js', st(30)],
      ['/p/same.js', st(20)],
    ]);
    expect(computePlan(known, seen)).toEqual({
      added: [], removed: [], changed: ['/p/touched.js'],
    });
  });
});
