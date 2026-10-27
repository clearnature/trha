// Skill discovery parity with the CLI's `UI.Skills` (same roots, same
// frontmatter rules, same precedence).  These are pure/IO unit tests: no
// scheduler, no child processes.

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { discoverSkills, parseSkill, readSkill, skillDirs } from '../src/Server/skills.js';

let root: string;
let project: string;
let home: string;

beforeEach(async () => {
  root = await mkdtemp(path.join(tmpdir(), 'trha-skills-'));
  project = path.join(root, 'project');
  home = path.join(root, 'home');
  await mkdir(project, { recursive: true });
  await mkdir(home, { recursive: true });
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

async function write(file: string, body: string): Promise<void> {
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, body, 'utf8');
}

describe('skillDirs', () => {
  it('scans the project first, then home, then the explicit dir last', () => {
    expect(skillDirs('/proj', '/home/u', '/extra')).toEqual([
      '/proj/.agents/skills',
      '/proj/.trha/skills',
      '/home/u/.agents/skills',
      '/home/u/.trha/skills',
      '/extra',
    ]);
  });

  it('keeps the four default roots when no extra dir is set', () => {
    expect(skillDirs('/proj', '/home/u', undefined)).toHaveLength(4);
  });
});

describe('parseSkill', () => {
  it('reads name and description from the frontmatter', () => {
    const skill = parseSkill('/s/brooks-review/SKILL.md', '---\nname: brooks-review\ndescription: "Review a diff"\n---\n# Body\n');
    expect(skill).toEqual({
      name: 'brooks-review',
      description: 'Review a diff',
      file: '/s/brooks-review/SKILL.md',
    });
  });

  it('falls back to the directory name for SKILL.md', () => {
    expect(parseSkill('/s/dir-name/SKILL.md', 'no frontmatter').name).toBe('dir-name');
  });

  it('falls back to the file name for flat markdown', () => {
    expect(parseSkill('/s/quick.md', '# quick').name).toBe('quick');
  });
});

describe('discoverSkills', () => {
  it('keeps the project .agents copy when two roots declare the same name', async () => {
    await write(path.join(project, '.agents', 'skills', 'review', 'SKILL.md'),
      '---\nname: review\ndescription: project copy\n---\n');
    await write(path.join(project, '.trha', 'skills', 'review.md'),
      '---\nname: review\ndescription: fallback copy\n---\n');

    const skills = await discoverSkills(skillDirs(project, home, undefined));
    expect(skills.map(s => s.name)).toEqual(['review']);
    expect(skills[0]?.description).toBe('project copy');
  });

  it('finds nested and flat skills in the home roots too', async () => {
    await write(path.join(project, '.agents', 'skills', 'zeta', 'SKILL.md'), '---\nname: zeta\n---\n');
    await write(path.join(home, '.agents', 'skills', 'alpha.md'), '---\nname: alpha\ndescription: from home\n---\n');

    const skills = await discoverSkills(skillDirs(project, home, undefined));
    expect(skills.map(s => s.name)).toEqual(['alpha', 'zeta']);
    expect(skills[0]?.description).toBe('from home');
  });

  it('returns nothing for missing roots', async () => {
    expect(await discoverSkills(skillDirs(project, home, undefined))).toEqual([]);
  });
});

describe('readSkill', () => {
  it('loads by the frontmatter name', async () => {
    await write(path.join(project, '.agents', 'skills', 'review', 'SKILL.md'),
      '---\nname: brooks-review\n---\n# Review body\n');
    const body = await readSkill(skillDirs(project, home, undefined), 'brooks-review');
    expect(body).toContain('# Review body');
  });

  it('also matches the file stem when the frontmatter renames the skill', async () => {
    await write(path.join(project, '.trha', 'skills', 'lean.md'), '---\nname: Lean Tactics\n---\n# Lean\n');
    const body = await readSkill(skillDirs(project, home, undefined), 'lean');
    expect(body).toContain('# Lean');
  });

  it('returns null for an unknown or escaping name', async () => {
    await write(path.join(project, '.trha', 'skills', 'lean.md'), '# Lean\n');
    const dirs = skillDirs(project, home, undefined);
    expect(await readSkill(dirs, 'nope')).toBeNull();
    expect(await readSkill(dirs, '../etc')).toBeNull();
  });

  it('honours the explicit extra directory', async () => {
    const extra = path.join(root, 'extra');
    await write(path.join(extra, 'demo', 'SKILL.md'), '---\nname: demo\n---\n# Demo\n');
    const body = await readSkill(skillDirs(project, home, extra), 'demo');
    expect(body).toContain('# Demo');
  });
});
