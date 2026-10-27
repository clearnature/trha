// Agent definitions: `<name>/preset.yml` (dsh-style metadata) plus
// `<name>/AGENT.md` (instructions), project first then user.

import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { loadAgentDefinitions, parsePresetYaml } from '../src/Server/agentDefs.js';

describe('parsePresetYaml', () => {
  it('reads scalars, inline lists and block lists', () => {
    const parsed = parsePresetYaml(
      [
        'name: reviewer',
        'description: "code review"',
        'mode: standard   # trailing comment',
        'tools: [read, grep, glob]',
        'tags:',
        '  - one',
        '  - two',
      ].join('\n'),
    );
    expect(parsed.name).toBe('reviewer');
    expect(parsed.description).toBe('code review');
    expect(parsed.mode).toBe('standard');
    expect(parsed.tools).toEqual(['read', 'grep', 'glob']);
    expect(parsed.tags).toEqual(['one', 'two']);
  });

  it('ignores comments and blank lines', () => {
    expect(parsePresetYaml('# only a comment\n\nname: x\n')).toEqual({ name: 'x' });
  });
});

describe('loadAgentDefinitions', () => {
  let dir: string;
  let project: string;
  let home: string;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-agents-'));
    project = path.join(dir, 'project');
    home = path.join(dir, 'home');
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  async function writeAgent(
    base: string, name: string, preset: string, instructions?: string,
  ): Promise<void> {
    const agentDir = path.join(base, name);
    await mkdir(agentDir, { recursive: true });
    await writeFile(path.join(agentDir, 'preset.yml'), preset, 'utf8');
    if (instructions !== undefined) {
      await writeFile(path.join(agentDir, 'AGENT.md'), instructions, 'utf8');
    }
  }

  it('loads preset.yml and AGENT.md', async () => {
    await writeAgent(project, 'reviewer',
      'name: reviewer\ndescription: review\ntools: [read, grep]\n',
      'You review code.');
    const defs = await loadAgentDefinitions([project, home]);
    expect(defs).toHaveLength(1);
    expect(defs[0]).toMatchObject({
      name: 'reviewer', description: 'review', tools: ['read', 'grep'],
      instructions: 'You review code.',
    });
  });

  it('lets the user directory override the project one', async () => {
    await writeAgent(project, 'reviewer', 'description: project version\n', 'project');
    await writeAgent(home, 'reviewer', 'description: user version\n', 'user');
    const defs = await loadAgentDefinitions([project, home]);
    expect(defs).toHaveLength(1);
    expect(defs[0]!.description).toBe('user version');
    expect(defs[0]!.instructions).toBe('user');
  });

  it('skips directories without preset.yml and invalid names', async () => {
    await mkdir(path.join(project, 'no-preset'), { recursive: true });
    await writeAgent(project, 'bad name', 'name: x\n');
    const defs = await loadAgentDefinitions([project]);
    expect(defs).toHaveLength(0);
  });

  it('tolerates a missing agents directory', async () => {
    expect(await loadAgentDefinitions([path.join(dir, 'nope')])).toEqual([]);
  });
});
