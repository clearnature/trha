// Workspace resolution for the tool layer.
//
// The tools used to be pinned to `/tmp/trha-workspace`, no matter where the
// shell was.  A host (CLI/Desktop) now gets, in order:
//   1. TRHA_WORKSPACE (explicit override; relative to the cwd)
//   2. `.trha/workspace` in the current directory, then in $HOME (a file
//      holding one path; relative paths resolve against the file's folder)
//   3. the directory the scheduler was started in (the shell's cwd)
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

export interface WorkspaceSources {
  env?: string | undefined;
  cwd: string;
  home?: string | undefined;
}

export function resolveWorkspace(sources: WorkspaceSources): string {
  const explicit = sources.env?.trim();
  if (explicit) return path.resolve(sources.cwd, explicit);

  const bases = [sources.cwd];
  if (sources.home && sources.home !== sources.cwd) bases.push(sources.home);

  for (const base of bases) {
    const marker = path.join(base, '.trha', 'workspace');
    if (!existsSync(marker)) continue;
    try {
      const raw = readFileSync(marker, 'utf8').trim();
      // Relative to the project root (the folder holding .trha), not .trha.
      if (raw) return path.resolve(base, raw);
    } catch {
      // unreadable marker: keep looking
    }
  }

  return sources.cwd;
}
