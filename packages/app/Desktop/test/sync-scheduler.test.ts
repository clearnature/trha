import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtemp, mkdir, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { syncPlan, syncScheduler } from '../scripts/sync-scheduler.mjs';

describe('syncPlan', () => {
  it('resolves the scheduler dist and the desktop resource dir', () => {
    const desktop = path.join('/repo', 'packages', 'app', 'Desktop');
    const plan = syncPlan(desktop);

    expect(plan.schedulerRoot).toBe(path.join('/repo', 'packages', 'scheduler'));
    expect(plan.src).toBe(path.join('/repo', 'packages', 'scheduler', 'dist'));
    expect(plan.out).toBe(path.join(desktop, 'resources', 'scheduler-dist'));
    expect(plan.packageJson).toBe(path.join('/repo', 'packages', 'scheduler', 'package.json'));
  });
});

describe('syncScheduler', () => {
  let tmp;
  let desktop;

  beforeEach(async () => {
    tmp = await mkdtemp(path.join(tmpdir(), 'trha-sync-'));
    desktop = path.join(tmp, 'packages', 'app', 'Desktop');
    const scheduler = path.join(tmp, 'packages', 'scheduler');

    await mkdir(path.join(scheduler, 'dist'), { recursive: true });
    await mkdir(desktop, { recursive: true });
    await writeFile(path.join(scheduler, 'dist', 'index.js'), 'export const x = 1;\n');
    await writeFile(
      path.join(scheduler, 'package.json'),
      '{"name":"@trha/scheduler","type":"module"}\n',
    );
  });

  afterEach(async () => {
    await rm(tmp, { recursive: true, force: true });
  });

  it('copies dist and keeps the ESM package marker', async () => {
    const plan = await syncScheduler(desktop, { runInstall: false });

    expect(await readFile(path.join(plan.out, 'index.js'), 'utf8')).toContain(
      'export const x = 1',
    );
    expect(await readFile(path.join(plan.out, 'package.json'), 'utf8')).toContain('"type":"module"');
  });

  it('tolerates a missing lockfile', async () => {
    await expect(syncScheduler(desktop, { runInstall: false })).resolves.toBeTruthy();
  });

  it('clears stale files from a previous sync', async () => {
    const out = path.join(desktop, 'resources', 'scheduler-dist');
    await mkdir(out, { recursive: true });
    await writeFile(path.join(out, 'stale.js'), 'old');

    await syncScheduler(desktop, { runInstall: false });

    await expect(access(path.join(out, 'stale.js'))).rejects.toThrow();
  });
});
