// Session persistence store tests: atomic roundtrip, load filtering and
// removal, in an isolated temp directory.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  loadSessions,
  removeSessionFile,
  saveSession,
} from '../src/Server/stateStore.js';

let dir: string;

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), 'trha-state-'));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const session = (id: string, messages: unknown[]) => ({
  id,
  mode: 'standard',
  messages,
  pendingApproval: null,
  createdAt: new Date('2026-09-01T00:00:00Z'),
});

describe('stateStore', () => {
  it('round-trips a session with messages', async () => {
    await saveSession(dir, session('session-1', [{ role: 'user', content: 'hi' }]));
    const loaded = await loadSessions(dir);
    expect(loaded).toHaveLength(1);
    expect(loaded[0].sessionId).toBe('session-1');
    expect(loaded[0].messages).toEqual([{ role: 'user', content: 'hi' }]);
    expect(loaded[0].v).toBe(1);
  });

  it('loads multiple sessions and skips corrupt files', async () => {
    await saveSession(dir, session('session-a', []));
    await saveSession(dir, session('session-b', [1]));
    const { writeFile } = await import('node:fs/promises');
    await writeFile(path.join(dir, 'broken.json'), '{not json', 'utf8');
    const loaded = await loadSessions(dir);
    expect(loaded.map(s => s.sessionId).sort()).toEqual(['session-a', 'session-b']);
  });

  it('returns nothing for a missing directory', async () => {
    await expect(loadSessions(path.join(dir, 'nope'))).resolves.toEqual([]);
  });

  it('removes the persisted file for a session', async () => {
    await saveSession(dir, session('session-x', []));
    await removeSessionFile(dir, 'session-x');
    expect(await loadSessions(dir)).toEqual([]);
  });

  it('writes atomically (no leftover tmp files)', async () => {
    await saveSession(dir, session('session-atom', []));
    const names = await (await import('node:fs/promises')).readdir(dir);
    expect(names).toEqual(['session-atom.json']);
  });
});
