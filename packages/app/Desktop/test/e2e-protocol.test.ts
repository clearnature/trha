// Protocol-level desktop E2E smoke, run through the test runner so it is
// covered in CI alongside the unit tests.  It shells out to
// scripts/e2e-desktop.mjs (which spawns the real scheduler with the same
// handshake/token/stdin-lease contract the Electron shell uses).  Skipped
// when the scheduler build output is absent.

import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import * as path from 'node:path';
import * as fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const desktopRoot = path.resolve(here, '..');
const repoRoot = path.resolve(desktopRoot, '../../..');
const script = path.join(desktopRoot, 'scripts', 'e2e-desktop.mjs');
const schedulerEntry = path.join(repoRoot, 'packages/scheduler/dist/cli.js');
const hasScheduler = fs.existsSync(schedulerEntry);

describe('desktop E2E smoke (protocol level)', () => {
  it.runIf(hasScheduler)('spawns the scheduler, drives the session API and exits cleanly', () => {
    const out = execFileSync(process.execPath, [script], {
      env: { ...process.env, E2E_PORT: '3489' },
      encoding: 'utf8',
      timeout: 60000,
    });
    expect(out).toContain('RESULT: PASS');
    expect(out).not.toContain('FAIL:');
  });

  it.runIf(!hasScheduler)('is skipped until the scheduler is built', () => {
    expect(true).toBe(true);
  });
});
