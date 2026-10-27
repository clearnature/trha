// balance.ts 全分支覆盖：provider 选择链 / key 解析两路 / fetch 结果三态。
// fetch 一律 stub（vi.stubGlobal），网络零依赖。
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { fetchBalance } from '../src/Server/balance.js';

let home = '';

beforeEach(async () => {
  home = await mkdtemp(path.join(tmpdir(), 'balance-'));
  delete process.env.TEST_KEY;   // 防 keyEnv 用例跨用例泄漏
  vi.stubGlobal('fetch', async () => {
    throw new Error('fetch should not be called in this case');
  });
});

afterEach(() => {
  delete process.env.TEST_KEY;
});

afterEach(() => {
  vi.unstubAllGlobals();
});

async function writeProviders(rows: unknown[]): Promise<void> {
  await writeFile(path.join(home, '.trha', 'providers.json', ''), '').catch(() => {});
  const dir = path.join(home, '.trha');
  const { mkdir } = await import('node:fs/promises');
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, 'providers.json'), JSON.stringify({ providers: rows }));
}

async function writeKeys(keys: Record<string, string>): Promise<void> {
  const dir = path.join(home, '.trha');
  const { mkdir } = await import('node:fs/promises');
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, 'provider-keys.json'), JSON.stringify({ keys }));
}

const openai = (over: Record<string, unknown> = {}) => ({
  name: 'deepseek', kind: 'openai', baseUrl: 'https://api.example.com/', inUse: true, keyEnv: 'TEST_KEY', ...over,
});

function okFetch(calls: string[] = []): void {
  vi.stubGlobal('fetch', async (url: string, init?: { headers?: Record<string, string> }) => {
    calls.push(`${url}|${init?.headers?.Authorization ?? ''}`);
    return {
      ok: true,
      json: async () => ({ balance_infos: [{ currency: 'CNY', total_balance: '42.5' }] }),
    } as unknown as Response;
  });
}

describe('balance.fetchBalance（provider 选择链 + key 两路 + fetch 三态）', () => {
  it('providers.json 缺失 → 拒绝（不崩溃）', async () => {
    await expect(fetchBalance(home)).rejects.toThrow();
  });

  it('providers 为空数组 → no provider configured', async () => {
    await writeProviders([]);
    await expect(fetchBalance(home)).rejects.toThrow('no provider configured');
  });

  it('选择链：openai+inUse 优先于普通 openai，普通 openai 优先于 inUse 非 openai', async () => {
    const calls: string[] = [];
    okFetch(calls);
    await writeProviders([
      openai({ name: 'plain', inUse: false, baseUrl: 'https://plain.example.com/' }),
      openai({ name: 'inuse', inUse: true, baseUrl: 'https://inuse.example.com/' }),
    ]);
    process.env.TEST_KEY = 'k-inuse';
    await fetchBalance(home);
    expect(calls[0]).toContain('https://inuse.example.com/user/balance');
  });

  it('无 openai 时回落到 inUse 的非 openai provider', async () => {
    const calls: string[] = [];
    okFetch(calls);
    await writeProviders([
      { name: 'anthro', kind: 'anthropic', baseUrl: 'https://anthro.example.com/', inUse: true, keyEnv: 'TEST_KEY' },
    ]);
    process.env.TEST_KEY = 'k';
    await fetchBalance(home);
    expect(calls[0]).toContain('https://anthro.example.com/user/balance');
    delete process.env.TEST_KEY;
  });

  it('baseUrl 尾斜杠被剥掉（…/user/balance 不出现双斜杠）', async () => {
    const calls: string[] = [];
    okFetch(calls);
    await writeProviders([openai({ baseUrl: 'https://api.example.com/' })]);
    process.env.TEST_KEY = 'k';
    await fetchBalance(home);
    expect(calls[0]).toContain('https://api.example.com/user/balance');
    expect(calls[0]).not.toContain('//user');
  });

  it('keyEnv 在环境变量里 → 直接用作 Bearer', async () => {
    const calls: string[] = [];
    okFetch(calls);
    await writeProviders([openai()]);
    process.env.TEST_KEY = 'env-key-123';
    await fetchBalance(home);
    expect(calls[0]).toContain('Bearer env-key-123');
    delete process.env.TEST_KEY;
  });

  it('keyEnv 未设 → 回落 provider-keys.json（按 name 查）', async () => {
    const calls: string[] = [];
    okFetch(calls);
    await writeProviders([openai({ keyEnv: 'MISSING_KEY' })]);
    await writeKeys({ deepseek: 'file-key-456' });
    await fetchBalance(home);
    expect(calls[0]).toContain('Bearer file-key-456');
  });

  it('两路 key 都没有 → no API key', async () => {
    okFetch();
    await writeProviders([openai({ keyEnv: 'DEFINITELY_MISSING_KEY_XYZ' })]);
    await expect(fetchBalance(home)).rejects.toThrow('no API key for deepseek');
  });

  it('HTTP 非 200 → balance HTTP 500', async () => {
    vi.stubGlobal('fetch', async () => ({ ok: false, status: 500, json: async () => ({}) }) as unknown as Response);
    await writeProviders([openai()]);
    process.env.TEST_KEY = 'k';
    await expect(fetchBalance(home)).rejects.toThrow('balance HTTP 500');
  });

  it('200 但没有 balance_infos → 可读错误', async () => {
    vi.stubGlobal('fetch', async () => ({ ok: true, json: async () => ({}) }) as unknown as Response);
    await writeProviders([openai()]);
    process.env.TEST_KEY = 'k';
    await expect(fetchBalance(home)).rejects.toThrow('no balance_infos');
  });

  it('成功路径：解析 currency / total（字符串数字转 number）', async () => {
    const calls: string[] = [];
    okFetch(calls);
    await writeProviders([openai()]);
    process.env.TEST_KEY = 'k';
    const b = await fetchBalance(home);
    expect(b).toEqual({ currency: 'CNY', total: 42.5 });
    expect(calls).toHaveLength(1);
  });

  it('成功路径：balance_infos 缺 currency → 默认 CNY；缺 total → 0', async () => {
    vi.stubGlobal('fetch', async () => ({
      ok: true,
      json: async () => ({ balance_infos: [{}] }),
    }) as unknown as Response);
    await writeProviders([openai()]);
    process.env.TEST_KEY = 'k';
    expect(await fetchBalance(home)).toEqual({ currency: 'CNY', total: 0 });
  });
});
