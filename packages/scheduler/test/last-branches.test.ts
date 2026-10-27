// 最后的零碎分支：Utils/EventEmitter（once/removeAllListeners/emit 无监听）
// + Core/KernelToken（env 覆盖 / 文件读取 / 缺失 → null）。
import { afterEach, describe, expect, it } from 'vitest';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { EventEmitter } from '../src/Utils/EventEmitter.js';
import { kernelTokenPath, resolveKernelToken } from '../src/Core/KernelToken.js';

describe('Utils/EventEmitter', () => {
  it('emit 无监听 → 不抛；once 触发一次后自移除', async () => {
    const bus = new EventEmitter();
    await expect(bus.emit('nobody', 1)).resolves.toBeUndefined();

    let calls = 0;
    bus.once('tick', () => { calls += 1; });
    await bus.emit('tick', null);
    await bus.emit('tick', null);
    expect(calls).toBe(1);
  });

  it('off 移除指定 handler（不影响同事件的其他监听）', async () => {
    const bus = new EventEmitter();
    const seen: string[] = [];
    const h1 = (): void => { seen.push('h1'); };
    const h2 = (): void => { seen.push('h2'); };
    bus.on('e', h1);
    bus.on('e', h2);
    bus.off('e', h1);
    await bus.emit('e', null);
    expect(seen).toEqual(['h2']);
  });

  it('removeAllListeners：指定事件清空；无参清全部', async () => {
    const bus = new EventEmitter();
    let a = 0;
    let b = 0;
    bus.on('a', () => { a += 1; });
    bus.on('b', () => { b += 1; });
    bus.removeAllListeners('a');
    await bus.emit('a', null);
    bus.removeAllListeners();
    await bus.emit('b', null);
    expect(a).toBe(0);
    expect(b).toBe(0);
  });
});

describe('Core/KernelToken', () => {
  let home = '';
  let oldHome: string | undefined;

  beforeEach(async () => {
    oldHome = process.env.HOME;
    home = await mkdtemp(path.join(tmpdir(), 'ktok-'));
    process.env.HOME = home;
    delete process.env.TRHA_KERNEL_TOKEN;
  });

  afterEach(() => {
    process.env.HOME = oldHome;
    delete process.env.TRHA_KERNEL_TOKEN;
  });

  it('TRHA_KERNEL_TOKEN 覆盖一切（含空白）', async () => {
    const { mkdir } = await import('node:fs/promises');
    await mkdir(path.join(home, '.trha'), { recursive: true });
    await writeFile(path.join(home, '.trha', 'kernel-token'), 'file-token');
    process.env.TRHA_KERNEL_TOKEN = '  env-token  ';
    expect(resolveKernelToken()).toBe('env-token');
  });

  it('无 env、无文件 → null；文件存在（含空白行）→ trim 后的值', async () => {
    expect(resolveKernelToken()).toBeNull();
    const { mkdir } = await import('node:fs/promises');
    await mkdir(path.join(home, '.trha'), { recursive: true });
    await writeFile(path.join(home, '.trha', 'kernel-token'), '  file-token\n');
    expect(resolveKernelToken()).toBe('file-token');
    expect(kernelTokenPath()).toContain(path.join('.trha', 'kernel-token'));
  });
});
