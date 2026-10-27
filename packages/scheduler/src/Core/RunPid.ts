// Run-state pid file for the scheduler, shared with `trha stop`.
//
// `trha serve` writes `~/.trha/run/kernel.pid`; the scheduler writes
// `~/.trha/run/scheduler.pid`.  `trha stop` reads them, verifies the pid still
// belongs to the expected program, and sends SIGTERM (never pkill, never a
// port sweep).
//
// The claim refuses to overwrite a pid that belongs to a *live* scheduler:
// starting a second one would otherwise shadow the first and leave `trha stop`
// pointing at the wrong process.

import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

export function runDir(): string {
  return path.join(homedir(), '.trha', 'run');
}

export function pidPath(name: string): string {
  return path.join(runDir(), `${name}.pid`);
}

/** `~/.trha/run/scheduler.token` — kept for older shells; new readers should
 *  use `~/.trha/runtime.json` (see `readRuntimeSection`). */
export function schedulerTokenFile(): string {
  return path.join(runDir(), 'scheduler.token');
}

// ── Runtime registry: ~/.trha/runtime.json ────────────────────────────────
// Single discovery file: each service writes its own section (host/port/pid/
// token); shells read it instead of guessing from settings or env.

export interface RuntimeEntry {
  host: string;
  port: number;
  pid: number;
  token: string;
}

export function runtimeFile(): string {
  return path.join(homedir(), '.trha', 'runtime.json');
}

export function readRuntimeSection(service: 'kernel' | 'scheduler'): RuntimeEntry | undefined {
  try {
    const root = JSON.parse(readFileSync(runtimeFile(), 'utf8')) as Record<string, unknown>;
    const raw = root[service];
    if (!raw || typeof raw !== 'object') return undefined;
    const o = raw as Record<string, unknown>;
    if (typeof o.host !== 'string' || typeof o.port !== 'number'
        || typeof o.pid !== 'number' || typeof o.token !== 'string') return undefined;
    return { host: o.host, port: o.port, pid: o.pid, token: o.token };
  } catch {
    return undefined;
  }
}

export function writeRuntimeSection(service: 'kernel' | 'scheduler', entry: RuntimeEntry): void {
  const file = runtimeFile();
  let root: Record<string, unknown> = {};
  try {
    root = JSON.parse(readFileSync(file, 'utf8')) as Record<string, unknown>;
  } catch {
    /* first writer */
  }
  root[service] = entry;
  const tmp = `${file}.tmp`;
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  writeFileSync(tmp, JSON.stringify(root, null, 2) + '\n', { mode: 0o600 });
  renameSync(tmp, file);
  try { chmodSync(file, 0o600); } catch { /* best effort */ }
}

export function removeRuntimeSection(service: 'kernel' | 'scheduler'): void {
  const file = runtimeFile();
  try {
    const root = JSON.parse(readFileSync(file, 'utf8')) as Record<string, unknown>;
    const raw = root[service] as RuntimeEntry | undefined;
    if (raw && raw.pid === process.pid) {
      delete root[service];
      writeFileSync(file, JSON.stringify(root, null, 2) + '\n', { mode: 0o600 });
    }
  } catch {
    /* nothing to remove */
  }
}

/** Alive, and its cmdline is a Node process running cli.js. */
function isOurScheduler(pid: number): boolean {
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  try {
    return readFileSync(`/proc/${pid}/cmdline`, 'utf8').includes('cli.js');
  } catch {
    // No /proc (macOS/Windows): trust the pid file.
    return true;
  }
}

/**
 * Claim `~/.trha/run/scheduler.pid`.
 *
 * Returns false when a live scheduler already owns it — the caller should
 * print the pid and exit instead of starting a second one.
 */
export function claimSchedulerPid(): boolean {
  const file = pidPath('scheduler');
  try {
    mkdirSync(runDir(), { recursive: true, mode: 0o700 });
    if (existsSync(file)) {
      const other = Number(readFileSync(file, 'utf8').trim());
      if (other && other !== process.pid && isOurScheduler(other)) return false;
    }
    writeFileSync(file, String(process.pid), { mode: 0o600 });
    process.on('exit', () => {
      try {
        if (Number(readFileSync(file, 'utf8').trim()) === process.pid) unlinkSync(file);
      } catch {
        /* already gone */
      }
    });
    return true;
  } catch {
    // A pid file is a convenience for `trha stop`; never fail startup over it.
    return true;
  }
}

/**
 * Claim the pid file and publish the outer Bearer token for shells that reuse
 * this scheduler (Desktop reads it instead of minting its own).
 */
export function claimSchedulerIdentity(token: string): boolean {
  if (!claimSchedulerPid()) return false;
  const file = schedulerTokenFile();
  try {
    writeFileSync(file, token, { mode: 0o600 });
    process.on('exit', () => {
      try {
        if (readFileSync(file, 'utf8').trim() === token) unlinkSync(file);
      } catch {
        /* already gone */
      }
      removeRuntimeSection('scheduler');
    });
  } catch {
    // Token publishing is a convenience; the scheduler still works without it.
  }
  return true;
}
