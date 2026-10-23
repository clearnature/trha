#!/usr/bin/env node
// Verify that local paths referenced from docs still exist.
//
// Only markdown links are checked: [text](relative/path.md), resolved from
// the doc's directory. Backticked paths are deliberately NOT checked -- this
// repo's notes cite other checkouts (deepseek-harness, /data/...) and planned
// files, so a gate there would be noise.
//
// Skipped on purpose: http(s), anchors, globs/brace lists, placeholders
// (`<...>`), absolute paths, directory-only refs ending in `/`, and
// docs/archive/** (historical records may point at deleted files).
//
// Line suffixes (`:52`, `:52,59`) are stripped before resolving. Repo-rooted
// paths are also tried under the package roots, because docs often write
// `src/main/handshake.ts` for packages/app/Desktop/src/main/handshake.ts.
//
// Usage: node scripts/verify-doc-links.mjs [--quiet]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const docsRoot = path.join(repoRoot, 'docs');
const SKIP_DIR = path.join('docs', 'archive');

const PACKAGE_ROOTS = ['', 'packages/app/Desktop', 'packages/scheduler', 'packages/app/Web'];

function listMarkdown(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    const rel = path.relative(repoRoot, full);
    if (entry.isDirectory()) {
      if (rel === SKIP_DIR) continue;
      out.push(...listMarkdown(full));
    } else if (entry.name.endsWith('.md')) {
      out.push(full);
    }
  }
  return out;
}

function stripLineSuffix(target) {
  return target.replace(/:\d+(?:[-,]\d+)*$/, '');
}

function isExternal(target) {
  return (
    /^[a-z]+:/i.test(target) ||
    target.startsWith('#') ||
    target.startsWith('<') ||
    target.startsWith('/') ||
    target.startsWith('~') ||
    target.includes('*') ||
    target.includes('{') ||
    target.includes('}') ||
    target.endsWith('/')
  );
}

export function extractTargets(text) {
  const targets = new Set();

  for (const m of text.matchAll(/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
    targets.add({ target: m[1], base: 'file' });
  }
  return [...targets];
}

function resolveRepoPath(clean) {
  for (const root of PACKAGE_ROOTS) {
    const candidate = path.join(repoRoot, root, clean);
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function main() {
  const quiet = process.argv.includes('--quiet');
  const files = listMarkdown(docsRoot);
  const problems = [];
  let checked = 0;

  for (const file of files) {
    const rel = path.relative(repoRoot, file);
    const lines = fs.readFileSync(file, 'utf8').split('\n');

    lines.forEach((line, idx) => {
      for (const { target, base } of extractTargets(line)) {
        if (isExternal(target)) continue;
        checked += 1;
        const clean = stripLineSuffix(target.replace(/[?#].*$/, ''));
        const resolved =
          base === 'repo' ? resolveRepoPath(clean) : path.resolve(path.dirname(file), clean);
        if (!resolved || !fs.existsSync(resolved)) {
          problems.push(`${rel}:${idx + 1}: missing ${target}`);
        } else if (!quiet) {
          console.log(`ok   ${rel}:${idx + 1}  ${target}`);
        }
      }
    });
  }

  if (problems.length > 0) {
    console.error(`\n${problems.length} broken local doc reference(s):`);
    for (const p of problems) console.error(`  ${p}`);
    process.exitCode = 1;
  } else {
    console.log(`\nchecked ${checked} local reference(s) in ${files.length} doc(s): ok`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
