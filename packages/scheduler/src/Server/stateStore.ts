// Server-side session persistence (G2 / S3): sessions are saved as
// versioned JSON files under a state directory and reloaded on startup so a
// scheduler restart does not lose live conversations.
//
// Write is atomic (temp file + rename, mirroring the CLI settings writer).
// Unknown/corrupt files are skipped on load, never fatal.

import { mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

export interface PersistedSession {
  v: number;
  sessionId: string;
  mode: string;
  messages: unknown[];
  pendingApproval: { message: string } | null;
  createdAt: string; // ISO
  updatedAt: string; // ISO
}

/** Directory is created on demand. */
async function ensureDir(dir: string): Promise<void> {
  await mkdir(dir, { recursive: true });
}

function fileFor(dir: string, sessionId: string): string {
  // session ids are kernel-generated (session-<ms>); keep them file-safe
  const safe = sessionId.replace(/[^A-Za-z0-9._-]/g, '_');
  return path.join(dir, `${safe}.json`);
}

/** Persist one session atomically. */
export async function saveSession(
  dir: string,
  session: { id: string; mode: string; messages: unknown[]; pendingApproval: { message: string } | null; createdAt: Date },
): Promise<void> {
  await ensureDir(dir);
  const record: PersistedSession = {
    v: 1,
    sessionId: session.id,
    mode: session.mode,
    messages: session.messages,
    pendingApproval: session.pendingApproval,
    createdAt: session.createdAt.toISOString(),
    updatedAt: new Date().toISOString(),
  };
  const target = fileFor(dir, session.id);
  const tmp = `${target}.tmp`;
  await writeFile(tmp, JSON.stringify(record), 'utf8');
  await rename(tmp, target);
}

/** Load every persisted session (skipping unparseable files). */
export async function loadSessions(dir: string): Promise<PersistedSession[]> {
  let entries: string[];
  try {
    entries = await readdir(dir);
  } catch {
    return [];
  }
  const out: PersistedSession[] = [];
  for (const name of entries.filter(n => n.endsWith('.json'))) {
    try {
      const raw = await readFile(path.join(dir, name), 'utf8');
      const rec = JSON.parse(raw) as PersistedSession;
      if (rec && typeof rec.sessionId === 'string' && Array.isArray(rec.messages)) {
        out.push(rec);
      }
    } catch {
      // corrupt/partial file: skip (never fatal)
    }
  }
  return out;
}

/** Remove the persisted file for a session (no-op when absent). */
export async function removeSessionFile(dir: string, sessionId: string): Promise<void> {
  try {
    await rm(fileFor(dir, sessionId), { force: true });
  } catch {
    // ignore
  }
}

// ---- version pin (desktop update lock) ----

/** Read the pinned version from the state directory (null when unset). */
export async function loadPin(dir: string): Promise<string | null> {
  try {
    const raw = await readFile(path.join(dir, 'pin.json'), 'utf8');
    const rec = JSON.parse(raw) as { version?: unknown };
    return typeof rec.version === 'string' ? rec.version : null;
  } catch {
    return null;
  }
}

/** Persist the pinned version atomically. */
export async function savePin(dir: string, version: string): Promise<void> {
  await ensureDir(dir);
  const target = path.join(dir, 'pin.json');
  const tmp = `${target}.tmp`;
  await writeFile(tmp, JSON.stringify({ version }), 'utf8');
  await rename(tmp, target);
}
