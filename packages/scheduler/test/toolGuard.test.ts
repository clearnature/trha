import { describe, it, expect } from 'vitest';
import { confineWritePath, limitOutput } from '../src/Server/toolGuard.js';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

describe('confineWritePath', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'trha-guard-'));
  const extra = mkdtempSync(path.join(tmpdir(), 'trha-extra-'));

  it('工作区内路径允许', async () => {
    const p = await confineWritePath(root, path.join(root, 'a.txt'), []);
    expect(p).toBeTruthy();
  });

  it('越界路径拒绝（无 extraRoots）', async () => {
    const p = await confineWritePath(root, path.join(tmpdir(), 'outside.txt'), []);
    expect(p).toBeNull();
  });

  it('extraRoots 内的路径允许', async () => {
    const p = await confineWritePath(root, path.join(extra, 'data.txt'), [extra]);
    expect(p).toBeTruthy();
    const inside = path.join(extra, 'sub'); mkdirSync(inside, { recursive: true });
    const q = await confineWritePath(root, path.join(inside, 'x.txt'), [extra]);
    expect(q).toBeTruthy();
  });

  it('extraRoots 外的越界仍拒绝', async () => {
    const other = mkdtempSync(path.join(tmpdir(), 'trha-other-'));
    const p = await confineWritePath(root, path.join(other, 'y.txt'), [extra]);
    expect(p).toBeNull();
  });
});

describe('limitOutput', () => {
  it('裁剪超过 64KiB 阈值的长输出', () => {
    const big = 'x'.repeat(64 * 1024 + 100);
    const out = limitOutput(big);
    expect(out.length).toBeLessThan(big.length);
    expect(out).toContain('[truncated]');
  });
});
