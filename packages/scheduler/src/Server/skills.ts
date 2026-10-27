// Skill discovery shared by the `skill` tool.
//
// The directory order mirrors the CLI's `UI.Skills.skillDirList` — project
// `.agents` → project `.trha` → home `.agents` → home `.trha` →
// `TRHA_SKILLS_DIR` — so a skill listed in the TUI palette is exactly the one
// the model can load by name from inside a turn.
//
// Layout accepted (same as the CLI): `<dir>/<name>/SKILL.md` and
// `<dir>/<name>.md`, with a tiny `---` frontmatter block carrying `name` and
// `description`.  When the block omits `name`, the directory (or file) name is
// used.

import { readdir, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

export interface DiscoveredSkill {
  name: string;
  description: string;
  /** Absolute path of the markdown file. */
  file: string;
}

/** Roots scanned for skills, highest precedence first. */
export function skillDirs(
  workspace: string,
  home: string = os.homedir(),
  extra: string | undefined = process.env.TRHA_SKILLS_DIR,
): string[] {
  const dirs = [
    path.join(workspace, '.agents', 'skills'),
    path.join(workspace, '.trha', 'skills'),
    path.join(home, '.agents', 'skills'),
    path.join(home, '.trha', 'skills'),
  ];
  if (extra) dirs.push(extra);
  return dirs;
}

/** Parse one skill file; the name falls back to the directory (or file) name. */
export function parseSkill(file: string, body: string): DiscoveredSkill {
  const lines = body.split(/\r?\n/);
  const fields = new Map<string, string>();
  if (lines[0]?.trim() === '---') {
    for (const line of lines.slice(1)) {
      if (line.trim() === '---') break;
      const match = /^\s*([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line);
      const key = match?.[1];
      if (key) fields.set(key, clean(match?.[2] ?? ''));
    }
  }
  const base = path.basename(file);
  const fallback = base === 'SKILL.md'
    ? path.basename(path.dirname(file))
    : base.replace(/\.md$/i, '');
  return {
    name: fields.get('name') || fallback,
    description: fields.get('description') ?? '',
    file,
  };
}

function clean(value: string): string {
  return value.trim().replace(/^["']+|["']+$/g, '').trim();
}

/** Read one directory: `<name>/SKILL.md` and `<name>.md` entries. */
async function scanDir(dir: string): Promise<DiscoveredSkill[]> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  const found: DiscoveredSkill[] = [];
  for (const entry of [...entries].sort((a, b) => a.name.localeCompare(b.name))) {
    const candidate = entry.isDirectory()
      ? path.join(dir, entry.name, 'SKILL.md')
      : entry.name.endsWith('.md')
        ? path.join(dir, entry.name)
        : null;
    if (!candidate) continue;
    try {
      found.push(parseSkill(candidate, await readFile(candidate, 'utf8')));
    } catch {
      // A directory without SKILL.md (or an unreadable file): not a skill.
    }
  }
  return found;
}

/** Every skill, first one per name wins (directory order is precedence). */
export async function discoverSkills(dirs: string[]): Promise<DiscoveredSkill[]> {
  const byName = new Map<string, DiscoveredSkill>();
  for (const dir of dirs) {
    for (const skill of await scanDir(dir)) {
      if (!byName.has(skill.name)) byName.set(skill.name, skill);
    }
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Body of the named skill, or null when no scanned directory declares it.
 * Lookup only ever reads a file that discovery already found: a name like
 * `../etc` cannot escape the skill roots.
 */
export async function readSkill(dirs: string[], name: string): Promise<string | null> {
  const wanted = name.trim();
  if (!wanted) return null;
  const skills = await discoverSkills(dirs);
  const hit = skills.find(s => s.name === wanted)
    ?? skills.find(s =>
      path.basename(s.file, '.md') === wanted
      || path.basename(path.dirname(s.file)) === wanted);
  if (!hit) return null;
  try {
    return await readFile(hit.file, 'utf8');
  } catch {
    return null;
  }
}
