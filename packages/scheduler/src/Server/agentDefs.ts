// Agent definitions under `~/.trha/agents/<name>/` (and the project's
// `./.trha/agents/<name>/`).
//
// Shape follows dsh's `.agent-presets/<name>/` (one directory per agent with
// `preset.yml` metadata) while the instructions stay a Markdown file, the
// form Reasonix uses for its agent-like skills.  `preset.yml` is intentionally
// shallow — `key: value`, `key: [a, b]` and `- item` lists — so the scheduler
// needs no YAML dependency.

import { readFile, readdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

export interface AgentDef {
  name: string;
  description: string;
  /** trha mode (standard / minimal / ptc / cordis); absent = inherit parent. */
  mode?: string | undefined;
  /** Model override; `inherit` or absent = parent's model. */
  model?: string | undefined;
  /** Reasoning effort override. */
  effort?: string | undefined;
  /** Tool allow-list; absent = every tool the parent has. */
  tools?: string[] | undefined;
  /** Markdown instructions from AGENT.md. */
  instructions: string;
  /** Directory the definition was read from. */
  dir: string;
}

/** Search order: project first, then the user home (the user wins on a clash). */
export function agentDirs(cwd: string): string[] {
  return [
    path.join(cwd, '.trha', 'agents'),
    path.join(homedir(), '.trha', 'agents'),
  ];
}

/** Minimal YAML: `key: value`, `key: [a, b]`, and `- item` lists. */
export function parsePresetYaml(text: string): Record<string, string | string[]> {
  const out: Record<string, string | string[]> = {};
  let listKey: string | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\s+#.*$/, '');
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const item = line.match(/^\s*-\s*(.+)$/);
    if (item && listKey) {
      (out[listKey] as string[]).push(unquote(item[1]!.trim()));
      continue;
    }
    const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (!kv) continue;
    const key = kv[1]!;
    const value = kv[2]!.trim();
    if (value === '') {
      listKey = key;
      out[key] = [];
      continue;
    }
    listKey = null;
    if (value.startsWith('[') && value.endsWith(']')) {
      out[key] = value
        .slice(1, -1)
        .split(',')
        .map(s => unquote(s.trim()))
        .filter(Boolean);
    } else {
      out[key] = unquote(value);
    }
  }
  return out;
}

function unquote(s: string): string {
  return s.replace(/^['"]/, '').replace(/['"]$/, '');
}

/** Load every `<name>/preset.yml`; a missing AGENT.md means "no instructions". */
export async function loadAgentDefinitions(dirs: string[]): Promise<AgentDef[]> {
  const found: AgentDef[] = [];
  for (const dir of dirs) {
    let names: string[];
    try {
      names = (await readdir(dir)).sort();
    } catch {
      continue;
    }
    for (const entry of names) {
      const def = await readAgentDir(path.join(dir, entry), entry);
      if (def) found.push(def);
    }
  }
  // A later directory overrides an earlier one by name, keeping its position.
  const merged: AgentDef[] = [];
  for (const def of found) {
    const i = merged.findIndex(d => d.name === def.name);
    if (i >= 0) merged[i] = def;
    else merged.push(def);
  }
  return merged;
}

async function readAgentDir(dir: string, dirName: string): Promise<AgentDef | null> {
  if (!/^[A-Za-z0-9_-]+$/.test(dirName)) return null;
  let preset: Record<string, string | string[]>;
  try {
    preset = parsePresetYaml(await readFile(path.join(dir, 'preset.yml'), 'utf8'));
  } catch {
    return null; // an agent needs preset.yml; a stray directory is ignored
  }
  const instructions = await readFile(path.join(dir, 'AGENT.md'), 'utf8').catch(() => '');
  const text = (v: string | string[] | undefined): string | undefined =>
    typeof v === 'string' && v.trim() ? v.trim() : undefined;
  const name = text(preset.name) ?? dirName;
  const tools = Array.isArray(preset.tools) ? preset.tools : undefined;
  return {
    name,
    description: text(preset.description) ?? '',
    ...(text(preset.mode) ? { mode: text(preset.mode) } : {}),
    ...(text(preset.model) ? { model: text(preset.model) } : {}),
    ...(text(preset.effort) ? { effort: text(preset.effort) } : {}),
    ...(tools && tools.length ? { tools } : {}),
    instructions: instructions.trim(),
    dir,
  };
}
