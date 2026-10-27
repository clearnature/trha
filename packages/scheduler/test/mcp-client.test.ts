// mcp.ts 客户端测试：假 stdio MCP 服务器（test/helpers/fake-mcp.mjs）。
// 覆盖：loadConfig / connect 握手（initialize + initialized 通知）/ 三件资源工具 /
// 错误路（无配置、未知服务器、空 uri）/ mcpStatus / shutdownMcp。
// （与 lsp 不同：MCP 是 newline JSON-RPC，不需要 Content-Length 帧。）
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  listMcpResources,
  listMcpResourceTemplates,
  readMcpResource,
  mcpStatus,
  shutdownMcp,
} from '../src/Server/mcp.js';

let dir = '';
const FAKE = path.resolve('test/helpers/fake-mcp.mjs');

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'mcp-'));
  const cfg = path.join(dir, 'mcp.json');
  await writeFile(cfg, JSON.stringify({
    servers: { fs: { command: 'node', args: [FAKE] } },
  }));
  process.env.TRHA_MCP_CONFIG = cfg;
});

afterAll(() => {
  delete process.env.TRHA_MCP_CONFIG;
  shutdownMcp();
});

describe('mcp 客户端（假 stdio 服务器）', () => {
  it('listMcpResources：握手 + resources/list', async () => {
    const list = await listMcpResources();
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ uri: 'file:///fake/a.txt', name: 'a', mimeType: 'text/plain' });
  });

  it('listMcpResourceTemplates', async () => {
    const t = await listMcpResourceTemplates();
    expect(t).toEqual([{ uriTemplate: 'file:///fake/{id}', name: 'tpl' }]);
  });

  it('readMcpResource：contents[].text 透传', async () => {
    expect(await readMcpResource('file:///fake/a.txt')).toBe('fake resource body');
  });

  it('readMcpResource 空 uri → 明确报错', async () => {
    await expect(readMcpResource('')).rejects.toThrow('uri is required');
  });

  it('无 TRHA_MCP_CONFIG → no MCP servers configured', async () => {
    delete process.env.TRHA_MCP_CONFIG;
    await expect(listMcpResources()).rejects.toThrow('no MCP servers configured');
  });

  it('指定未知 server → unknown MCP server', async () => {
    await expect(listMcpResources('ghost')).rejects.toThrow('unknown MCP server "ghost"');
  });

  it('mcpStatus：configured 含 fs，连接后 connected 含 fs', async () => {
    await listMcpResources();   // 触发连接
    const st = await mcpStatus();
    expect(st.configured).toContain('fs');
    expect(st.connected).toContain('fs');
  });

  it('同一服务器复用连接（第二次调用仍成功）', async () => {
    expect(await listMcpResources()).toHaveLength(1);
    expect(await listMcpResources()).toHaveLength(1);
  });
});
