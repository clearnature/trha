// Pre-edit snapshots under ~/.trha/file-history: the scheduler writes files,
// so it is the only place that can capture the content before it is replaced.

import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { fileHistoryDir, snapshotFile } from '../src/Server/fileHistory.js';

describe('file history', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-fh-'));
    process.env.TRHA_FILE_HISTORY_DIR = path.join(dir, 'history');
  });
  afterEach(async () => {
    delete process.env.TRHA_FILE_HISTORY_DIR;
    await rm(dir, { recursive: true, force: true });
  });

  it('snapshots the content before an edit', async () => {
    const file = path.join(dir, 'notes.txt');
    await writeFile(file, 'old content', 'utf8');
    await snapshotFile(file);
    const names = await readdir(fileHistoryDir());
    expect(names).toHaveLength(1);
    expect(await readFile(path.join(fileHistoryDir(), names[0]!), 'utf8')).toBe('old content');
    // the name carries the file's basename so a snapshot is identifiable
    expect(names[0]).toContain('notes.txt');
  });

  it('does nothing for a file that does not exist yet', async () => {
    await snapshotFile(path.join(dir, 'missing.txt'));
    const names = await readdir(fileHistoryDir()).catch(() => [] as string[]);
    expect(names).toHaveLength(0);
  });

  it('never throws when the history directory is unwritable', async () => {
    const file = path.join(dir, 'notes.txt');
    await writeFile(file, 'x', 'utf8');
    process.env.TRHA_FILE_HISTORY_DIR = path.join(dir, 'notes.txt', 'nested');
    await expect(snapshotFile(file)).resolves.toBeUndefined();
  });
});
