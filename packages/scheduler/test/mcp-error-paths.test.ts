// mcp.ts 错误与边界路（不需要真实服务器）：
//   · 坏 JSON 配置 / 缺 servers 键 / server 缺 command
//   · command 指向不存在的二进制 → spawn 错误被工具层兜住
//   · server 往 stdout 打非 JSON 行 → 被忽略，请求照常成功
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  listMcpResources,
  shutdownMcp,
  mcpStatus,
} from '../src/Server/mcp.js';

const FAKE = path.resolve('test/helpers/fake-mcp.mjs');
let dir = '';

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'mcp-err-'));
  delete process.env.TRHA_MCP_CONFIG;
});

afterAll(() => {
  delete process.env.TRHA_MCP_CONFIG;
  shutdownMcp();
});

const writeCfg = async (body: string): Promise<string> => {
  const cfg = path.join(dir, `cfg-${Math.random().toString(36).slice(2)}.json`);
  await writeFile(cfg, body);
  process.env.TRHA_MCP_CONFIG = cfg;
  return cfg;
};

describe('mcp 配置错误路', () => {
  it('坏 JSON → 视作无配置 → no MCP servers configured', async () => {
    await writeCfg('{servers:');
    await expect(listMcpResources()).rejects.toThrow('no MCP servers configured');
  });

  it('没有 servers 键 → no MCP servers configured', async () => {
    await writeCfg('{"other": 1}');
    await expect(listMcpResources()).rejects.toThrow('no MCP servers configured');
  });

  it('server 条目缺 command → 该条被跳过', async () => {
    await writeCfg(JSON.stringify({ servers: { broken: { args: ['/tmp'] } } }));
    await expect(listMcpResources()).rejects.toThrow('no MCP servers configured');
  });

  it('command 指向不存在的二进制 → connect 失败被拒绝（不炸进程）', async () => {
    await writeCfg(JSON.stringify({
      servers: { ghost: { command: 'definitely-missing-mcp-binary' } },
    }));
    await expect(listMcpResources()).rejects.toThrow();
    const st = await mcpStatus();
    expect(st.configured).toContain('ghost');
    expect(st.connected).not.toContain('ghost');
  });

  it('server 往 stdout 打非 JSON 行 → 被忽略，请求照常成功', async () => {
    await writeCfg(JSON.stringify({
      servers: { noisy: { command: 'bash', args: ['-c', `echo "plain log line"; exec node ${FAKE}`] } },
    }));
    const list = await listMcpResources();
    expect(list).toHaveLength(1);
    expect(list[0].uri).toBe('file:///fake/a.txt');
  });

  it('shutdownMcp 幂等', () => {
    expect(() => shutdownMcp()).not.toThrow();
  });
});
