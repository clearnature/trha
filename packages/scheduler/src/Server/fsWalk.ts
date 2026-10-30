/**
 * Path resolution, a bounded file walk, and a minimal glob compiler.
 *
 * Extracted from `index.ts` so the `glob` / `grep` tools can move onto the
 * registry (DSH contract) while the core chain keeps working during the
 * transition — both sides now import the same helpers instead of owning copies.
 */
import path from 'node:path';
import { readdir } from 'node:fs/promises';

/** Resolve a model-supplied path against a base directory (null when not a path). */
export function resolveReadPath(raw: unknown, base: string): string | null {
  if (typeof raw !== 'string' || !raw.trim()) return null;
  return path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(base, raw);
}

/** Recursive file walk with a depth/file cap and the usual noise skipped. */
export async function walkFiles(dir: string, cap: number): Promise<string[]> {
  const out: string[] = [];
  const skip = new Set(['node_modules', '.git', 'dist', 'dist-newstyle', '.lake', 'target']);
  const walk = async (d: string, depth: number): Promise<void> => {
    if (out.length >= cap || depth > 12) return;
    let entries;
    try {
      entries = await readdir(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (out.length >= cap) return;
      if (e.name.startsWith('.') && e.isDirectory()) continue;
      const full = path.join(d, e.name);
      if (e.isDirectory()) {
        if (skip.has(e.name)) continue;
        await walk(full, depth + 1);
      } else if (e.isFile()) {
        out.push(full);
      }
    }
  };
  await walk(dir, 0);
  return out;
}

/** Minimal glob: `**` spans directories, `*` / `?` stay within a segment. */
export function globToRegExp(pattern: string): RegExp {
  let re = '';
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === '*') {
      if (pattern[i + 1] === '*') {
        re += '.*';
        i += 1;
        if (pattern[i + 1] === '/') i += 1;
      } else {
        re += '[^/]*';
      }
    } else if (ch === '?') {
      re += '[^/]';
    } else {
      re += ch !== undefined && '.+^${}()|[]\\'.includes(ch) ? `\\${ch}` : ch;
    }
  }
  return new RegExp(`^${re}$`);
}

/** Join a relative path onto a base; absolute paths pass through unchanged. */
export function workspaceRelative(raw: string, base: string): string {
  return path.isAbsolute(raw) ? raw : path.join(base, raw);
}
