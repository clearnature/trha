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

  // Regression: a scheduler launched from a subpackage (the Electron host and
  // the dev launcher both `cd packages/<pkg>` first) used to take that
  // subdirectory as the workspace, so the system prompt's `{{cwd}}` and the
  // file sandbox silently moved with the launch directory even though the repo
  // root declared a workspace.
  it('walks up to a marker in an ancestor', async () => {
    const root = await tempDir();
    await mkdir(path.join(root, '.trha'), { recursive: true });
    await writeFile(path.join(root, '.trha', 'workspace'), '.\n');
    const sub = path.join(root, 'packages', 'scheduler');
    await mkdir(sub, { recursive: true });
    expect(resolveWorkspace({ cwd: sub })).toBe(root);
  });

  it('keeps walking up past an empty marker in a subdirectory', async () => {
    const root = await tempDir();
    await mkdir(path.join(root, '.trha'), { recursive: true });
    await writeFile(path.join(root, '.trha', 'workspace'), 'app\n');
    const sub = path.join(root, 'packages', 'scheduler');
    await mkdir(path.join(sub, '.trha'), { recursive: true });
    await writeFile(path.join(sub, '.trha', 'workspace'), '  \n');
    expect(resolveWorkspace({ cwd: sub })).toBe(path.resolve(root, 'app'));
  });

  it('resolves an ancestor marker relative to the folder holding .trha', async () => {
    const root = await tempDir();
    await mkdir(path.join(root, '.trha'), { recursive: true });
    await writeFile(path.join(root, '.trha', 'workspace'), 'services/api\n');
    const sub = path.join(root, 'packages', 'deep', 'deeper');
    await mkdir(sub, { recursive: true });
    expect(resolveWorkspace({ cwd: sub })).toBe(path.resolve(root, 'services', 'api'));
  });

  it('falls back to the nearest project root when no marker exists', async () => {
    const root = await tempDir();
    await mkdir(path.join(root, '.git'), { recursive: true });
    const sub = path.join(root, 'packages', 'scheduler');
    await mkdir(sub, { recursive: true });
    expect(resolveWorkspace({ cwd: sub })).toBe(root);
  });

  // The subpackage carries its own package.json, so a manifest-first search
  // would stop there and reproduce the original bug.
  it('prefers the checkout root over a subpackage manifest', async () => {
    const root = await tempDir();
    await mkdir(path.join(root, '.git'), { recursive: true });
    const sub = path.join(root, 'packages', 'scheduler');
    await mkdir(sub, { recursive: true });
    await writeFile(path.join(sub, 'package.json'), '{}\n');
    expect(resolveWorkspace({ cwd: sub })).toBe(root);
  });

  it('stops at a manifest root when the tree is not a checkout', async () => {
    const root = await tempDir();
    await writeFile(path.join(root, 'package.json'), '{}\n');
    const sub = path.join(root, 'packages', 'scheduler');
    await mkdir(sub, { recursive: true });
    expect(resolveWorkspace({ cwd: sub })).toBe(root);
  });

  it('prefers the $HOME marker over the project-root fallback', async () => {
    const cwd = await tempDir();
    const home = await tempDir();
    await mkdir(path.join(cwd, '.git'), { recursive: true });
    await mkdir(path.join(home, '.trha'), { recursive: true });
    await writeFile(path.join(home, '.trha', 'workspace'), '/srv/app');
    expect(resolveWorkspace({ cwd, home })).toBe('/srv/app');
  });
});
