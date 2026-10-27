// Workspace resolution for the tool layer.
//
// The tools used to be pinned to `/tmp/trha-workspace`, no matter where the
// shell was.  A host (CLI/Desktop) now gets, in order:
//   1. TRHA_WORKSPACE (explicit override; relative to the cwd)
//   2. `.trha/workspace` — the nearest one walking up from the cwd, then the
//      one in $HOME (a file holding one path; relative paths resolve against
//      the folder holding `.trha`, not against `.trha` itself)
//   3. the nearest ancestor that is a VCS root (`.git`)
//   4. the nearest ancestor with a build manifest (`cabal.project`,
//      `package.json`, `Cargo.toml`, `go.mod`)
//   5. the directory the scheduler was started in (the shell's cwd)
//
// Steps 2-4 walk *up* on purpose.  A scheduler launched from `packages/foo`
// used to report `packages/foo` as the workspace even when the repo root said
// otherwise, so the system prompt's `{{cwd}}` (and the file-tool sandbox)
// silently moved with the launch directory.  A marker is an explicit
// statement about the project, so it wins over the launch directory no matter
// how deep the shell was; a `.git` root likewise beats the `package.json` of
// the subpackage the shell happens to sit in.
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

export interface WorkspaceSources {
  env?: string | undefined;
  cwd: string;
  home?: string | undefined;
}

/** Marks a VCS checkout root (step 3): a directory *or* a gitfile (worktree/submodule). */
const VCS_MARKERS = ['.git'];

/** Build manifests that mark a project root when there is no VCS (step 4). */
const MANIFEST_MARKERS = ['cabal.project', 'package.json', 'Cargo.toml', 'go.mod'];

/** `start` and its ancestors, nearest first, ending at the filesystem root. */
function ancestors(start: string): string[] {
  const out: string[] = [];
  let cur = path.resolve(start);
  for (;;) {
    out.push(cur);
    const up = path.dirname(cur);
    if (up === cur) return out;
    cur = up;
  }
}

/**
 * The workspace declared by `<folder>/.trha/workspace`, or null when the
 * marker is missing, unreadable or empty (an empty marker means "no opinion",
 * so the search keeps going instead of pinning the workspace to `folder`).
 */
function markerFor(folder: string): string | null {
  const marker = path.join(folder, '.trha', 'workspace');
  if (!existsSync(marker)) return null;
  try {
    const raw = readFileSync(marker, 'utf8').trim();
    // Relative to the project root (the folder holding .trha), not .trha.
    return raw ? path.resolve(folder, raw) : null;
  } catch {
    // unreadable marker: keep looking
    return null;
  }
}

function hasAny(folder: string, names: string[]): boolean {
  return names.some(m => existsSync(path.join(folder, m)));
}

export function resolveWorkspace(sources: WorkspaceSources): string {
  const explicit = sources.env?.trim();
  if (explicit) return path.resolve(sources.cwd, explicit);

  const chain = ancestors(sources.cwd);
  for (const folder of chain) {
    const found = markerFor(folder);
    if (found) return found;
  }

  if (sources.home && sources.home !== sources.cwd) {
    const found = markerFor(sources.home);
    if (found) return found;
  }

  // Nothing declared: stay at the checkout root rather than in whatever
  // subpackage the shell was launched from.  `.git` first — `packages/foo`
  // carries its own package.json, so a manifest-first search would stop there.
  for (const folder of chain) {
    if (hasAny(folder, VCS_MARKERS)) return folder;
  }
  for (const folder of chain) {
    if (hasAny(folder, MANIFEST_MARKERS)) return folder;
  }

  return sources.cwd;
}
