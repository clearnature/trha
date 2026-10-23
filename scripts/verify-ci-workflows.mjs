#!/usr/bin/env node
// Verify that every `npm run <script>` in .github/workflows resolves to a
// script declared by the package.json in the directory the step runs from.
//
// This is the trha analogue of dsh's ci-* scripts: workflow YAML has no type
// system, so a renamed npm script silently breaks CI until the next push.
//
// Usage: node scripts/verify-ci-workflows.mjs [--quiet]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const workflowsDir = path.join(repoRoot, '.github', 'workflows');

export function scriptsOf(pkgPath) {
  try {
    return new Set(Object.keys(JSON.parse(fs.readFileSync(pkgPath, 'utf8')).scripts ?? {}));
  } catch {
    return null;
  }
}

/**
 * Walk one workflow file and return `{ file, line, cwd, script }` references.
 * Handles the two shapes used in this repo:
 *   - `run: |` blocks with `cd <dir>` followed by `npm run <script>`
 *   - `working-directory: <dir>` on the step
 */
export function extractReferences(file, lines) {
  const refs = [];
  let stepCwd = '.';
  let inRun = false;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const lineNo = i + 1;

    const wd = line.match(/^\s*working-directory:\s*(\S+)\s*$/);
    if (wd) stepCwd = wd[1];

    if (/^\s*-\s+name:/.test(line) || /^\s*-\s+uses:/.test(line)) {
      stepCwd = '.';
      inRun = false;
      continue;
    }

    if (/^\s*run:\s*\|/.test(line)) {
      inRun = true;
      continue;
    }

    if (inRun) {
      const indent = line.match(/^(\s*)\S/);
      if (!indent || indent[1].length < 8) {
        inRun = false;
        continue;
      }
      const cd = line.match(/^\s*cd\s+(\S+)\s*$/);
      if (cd) {
        stepCwd = path.posix.normalize(path.posix.join(stepCwd, cd[1]));
        continue;
      }
      const npm = line.match(/^\s*npm\s+run\s+([A-Za-z0-9:._-]+)/);
      if (npm) refs.push({ file, line: lineNo, cwd: stepCwd, script: npm[1] });
    }
  }
  return refs;
}

function main() {
  const quiet = process.argv.includes('--quiet');
  const files = fs.readdirSync(workflowsDir).filter(f => f.endsWith('.yml') || f.endsWith('.yaml'));
  const problems = [];
  let checked = 0;

  for (const name of files) {
    const file = path.join(workflowsDir, name);
    const refs = extractReferences(file, fs.readFileSync(file, 'utf8').split('\n'));
    for (const ref of refs) {
      checked += 1;
      const pkgPath = path.join(repoRoot, ref.cwd, 'package.json');
      const scripts = scriptsOf(pkgPath);
      const where = `${name}:${ref.line}`;
      if (!scripts) {
        problems.push(`${where}: no package.json at ${ref.cwd}`);
      } else if (!scripts.has(ref.script)) {
        problems.push(
          `${where}: "npm run ${ref.script}" has no matching script in ${path.join(ref.cwd, 'package.json')}`,
        );
      } else if (!quiet) {
        console.log(`ok   ${where}  ${ref.cwd} :: ${ref.script}`);
      }
    }
  }

  if (problems.length > 0) {
    console.error(`\n${problems.length} unresolved workflow script reference(s):`);
    for (const p of problems) console.error(`  ${p}`);
    process.exitCode = 1;
  } else {
    console.log(`\nchecked ${checked} npm script reference(s) across ${files.length} workflow(s): ok`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
