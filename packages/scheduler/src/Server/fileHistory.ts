// Pre-edit snapshots under `~/.trha/file-history/`.
//
// Reference CLIs keep a short file history so a bad edit can be inspected
// (or reverted by hand) after the fact.  The scheduler owns writes, so this
// is the only place that can capture the content *before* it is replaced.
//
// Best effort by design: a snapshot never fails or delays a tool call — a
// new file (nothing to save) or an unwritable directory just skips it.

import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, unlink, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

/** How many snapshots to keep; the oldest are pruned first. */
const KEEP = 200;

/** `~/.trha/file-history` (TRHA_FILE_HISTORY_DIR overrides, mostly for tests). */
export function fileHistoryDir(): string {
  const override = process.env.TRHA_FILE_HISTORY_DIR;
  return override && override.trim() ? override : path.join(homedir(), '.trha', 'file-history');
}

/** Snapshot the pre-edit content of `file`. Never throws. */
export async function snapshotFile(file: string): Promise<void> {
  try {
    const content = await readFile(file, 'utf8');
    if (!content) return;
    const dir = fileHistoryDir();
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const digest = createHash('sha1').update(file).digest('hex').slice(0, 8);
    const base = path.basename(file).replace(/[^\w.-]/g, '_').slice(-40) || 'file';
    await writeFile(path.join(dir, `${stamp}-${digest}-${base}`), content, {
      encoding: 'utf8',
      mode: 0o600,
    });
    await prune(dir);
  } catch {
    /* a snapshot is a convenience, not a precondition for writing */
  }
}

async function prune(dir: string): Promise<void> {
  const names = (await readdir(dir)).sort();
  const extra = names.length - KEEP;
  for (const name of names.slice(0, Math.max(0, extra))) {
    await unlink(path.join(dir, name)).catch(() => undefined);
  }
}
