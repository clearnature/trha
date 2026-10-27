// Service stop/status for the Desktop shell.
//
// This is the same contract `trha stop` implements (see
// `packages/app/CLI/Core/RunState.hs`): stop only the pid recorded in
// `~/.trha/run/<service>.pid`, verify it still looks like the expected
// program, send SIGTERM, and report a timeout instead of escalating.
//
// Kept free of Electron so the rules are unit-testable.

import { readFileSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

export type Service = 'kernel' | 'scheduler';
export type StopStatus = 'stopped' | 'not-running' | 'refused' | 'timeout';

export interface StopResult {
  service: Service;
  status: StopStatus;
  pid?: number;
}

export function runDir(): string {
  return path.join(homedir(), '.trha', 'run');
}

export function pidFile(service: Service): string {
  return path.join(runDir(), `${service}.pid`);
}

/** `~/.trha/run/scheduler.token` — written by the scheduler, read when we
 *  reuse a scheduler that was started outside Desktop. */
export function schedulerTokenFile(): string {
  return path.join(runDir(), 'scheduler.token');
}

export function readPid(service: Service): number | null {
  try {
    const pid = Number(readFileSync(pidFile(service), 'utf8').trim());
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Does a `/proc/<pid>/cmdline` string (NUL-separated) belong to the service? */
export function looksLikeOurProcess(service: Service, cmdline: string): boolean {
  if (service === 'scheduler') return cmdline.includes('cli.js');
  return cmdline.includes('trha') && (cmdline.includes('serve') || cmdline.includes('kernel-stub'));
}

function stillOurs(service: Service, pid: number): boolean {
  try {
    return looksLikeOurProcess(service, readFileSync(`/proc/${pid}/cmdline`, 'utf8'));
  } catch {
    // No /proc (macOS/Windows): trust the pid file.
    return true;
  }
}

function forget(file: string): void {
  try {
    unlinkSync(file);
  } catch {
    /* already gone */
  }
}

async function waitGone(pid: number, totalMs: number): Promise<boolean> {
  const steps = Math.max(1, Math.floor(totalMs / 100));
  for (let i = 0; i < steps; i++) {
    if (!pidAlive(pid)) return true;
    await new Promise<void>((resolve) => setTimeout(resolve, 100));
  }
  return !pidAlive(pid);
}

/**
 * Stop one service.  SIGTERM only; a process that outlives the timeout is
 * reported, never killed — matching `trha stop` without `--force`.
 */
export async function stopService(service: Service): Promise<StopResult> {
  const pid = readPid(service);
  if (!pid) return { service, status: 'not-running' };
  if (!pidAlive(pid)) {
    forget(pidFile(service));
    return { service, status: 'not-running' };
  }
  if (!stillOurs(service, pid)) return { service, status: 'refused', pid };

  try {
    process.kill(pid, 'SIGTERM');
  } catch {
    /* the wait below decides */
  }
  if (await waitGone(pid, 5000)) {
    forget(pidFile(service));
    return { service, status: 'stopped', pid };
  }
  return { service, status: 'timeout', pid };
}

export async function stopAll(): Promise<StopResult[]> {
  return [await stopService('kernel'), await stopService('scheduler')];
}

/** Pid of a live scheduler started by someone else (Desktop or an operator). */
export function runningSchedulerPid(): number | null {
  const pid = readPid('scheduler');
  if (!pid || !pidAlive(pid) || !stillOurs('scheduler', pid)) return null;
  return pid;
}

/** Token of the running scheduler, when it published one. */
export function resolveSchedulerToken(): string | null {
  // Single source first: `~/.trha/runtime.json` (written by the scheduler).
  try {
    const raw = JSON.parse(
      readFileSync(path.join(homedir(), '.trha', 'runtime.json'), 'utf8'),
    ) as { scheduler?: { token?: unknown } };
    if (typeof raw.scheduler?.token === 'string' && raw.scheduler.token) {
      return raw.scheduler.token;
    }
  } catch {
    /* fall through to the legacy token file */
  }
  try {
    const token = readFileSync(schedulerTokenFile(), 'utf8').trim();
    return token || null;
  } catch {
    return null;
  }
}

export function stopResultText(r: StopResult): string {
  switch (r.status) {
    case 'not-running':
      return `${r.service}: not running`;
    case 'stopped':
      return `${r.service}: stopped (pid ${r.pid})`;
    case 'timeout':
      return `${r.service}: pid ${r.pid} did not exit within 5s`;
    case 'refused':
      return `${r.service}: refused — pid ${r.pid} is not a ${r.service} process`;
  }
}
