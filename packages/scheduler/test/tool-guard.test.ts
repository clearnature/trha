// Defensive guard tests (defensive-patterns): symlink escapes are refused,
// legit paths resolve canonically, and outputs are capped.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { confineWritePath, limitOutput, MAX_TOOL_OUTPUT } from '../src/Server/toolGuard.js';

let root: string;

beforeEach(async () => {
  root = await mkdtemp(path.join(tmpdir(), 'trha-guard-'));
});
afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

describe('confineWritePath', () => {
  it('accepts a normal nested target and creates the parent', async () => {
    const target = await confineWritePath(root, path.join(root, 'sub', 'f.txt'));
    expect(target).toBe(path.join(root, 'sub', 'f.txt'));
    // parent was created by the guard
    await expect(writeFile(path.join(root, 'sub', 'x'), 'x')).resolves.toBeUndefined();
  });

  it('rejects a target outside the workspace', async () => {
    await expect(confineWritePath(root, '/etc/passwd')).resolves.toBeNull();
  });

  it('refuses a symlinked parent that escapes the workspace', async () => {
    await symlink('/etc', path.join(root, 'evil'));
    await expect(confineWritePath(root, path.join(root, 'evil', 'passwd')))
      .resolves.toBeNull();
  });
});

describe('limitOutput', () => {
  it('keeps short output unchanged', () => {
    expect(limitOutput('hello')).toBe('hello');
  });
  it('truncates and marks oversized output', () => {
    const big = 'x'.repeat(MAX_TOOL_OUTPUT + 10);
    const capped = limitOutput(big);
    expect(capped).toHaveLength(MAX_TOOL_OUTPUT + '\n…[truncated]'.length);
    expect(capped.endsWith('…[truncated]')).toBe(true);
  });
});
