// Workspace resolution: the tools must follow the shell, not a hard-coded
// /tmp path.  Priority: env → .trha/workspace (cwd, then $HOME) → cwd.

import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { resolveWorkspace } from '../src/Server/workspace.js';

const dirs: string[] = [];

async function tempDir(): Promise<string> {
  const d = await mkdtemp(path.join(tmpdir(), 'trha-ws-'));
  dirs.push(d);
  return d;
}

afterEach(async () => {
  while (dirs.length > 0) await rm(dirs.pop()!, { recursive: true, force: true });
});

describe('resolveWorkspace', () => {
  it('prefers the explicit env override, resolved against the cwd', async () => {
    const cwd = await tempDir();
    expect(resolveWorkspace({ env: 'sub/project', cwd })).toBe(path.resolve(cwd, 'sub/project'));
    expect(resolveWorkspace({ env: '/abs/place', cwd })).toBe('/abs/place');
  });

  it('defaults to the directory the shell was in', async () => {
    const cwd = await tempDir();
    expect(resolveWorkspace({ cwd })).toBe(cwd);
  });

  it('reads .trha/workspace from the cwd and resolves relative to it', async () => {
    const cwd = await tempDir();
    await mkdir(path.join(cwd, '.trha'), { recursive: true });
    await writeFile(path.join(cwd, '.trha', 'workspace'), 'project\n');
    expect(resolveWorkspace({ cwd })).toBe(path.resolve(cwd, 'project'));
  });

  it('falls back to $HOME/.trha/workspace when the cwd has none', async () => {
    const cwd = await tempDir();
    const home = await tempDir();
    await mkdir(path.join(home, '.trha'), { recursive: true });
    await writeFile(path.join(home, '.trha', 'workspace'), '/srv/app');
    expect(resolveWorkspace({ cwd, home })).toBe('/srv/app');
  });

  it('ignores an empty marker and keeps looking', async () => {
    const cwd = await tempDir();
    await mkdir(path.join(cwd, '.trha'), { recursive: true });
    await writeFile(path.join(cwd, '.trha', 'workspace'), '   \n');
    expect(resolveWorkspace({ cwd })).toBe(cwd);
  });
});
