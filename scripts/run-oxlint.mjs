#!/usr/bin/env node
// Thin wrapper around oxlint so every caller gets the same target set and
// warning policy. Same role as dsh's run-oxlint.ts: one place owns the flags,
// the output cap and the "warnings fail the build" decision.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cli = path.join(repoRoot, 'node_modules', '.bin', 'oxlint');

const DEFAULT_TARGETS = [
  'packages/scheduler/src',
  'packages/app/Desktop/src',
  'packages/app/Web/src',
];

// oxlint prints one caret block per finding; keep a ceiling so a pathological
// file cannot exhaust memory in CI logs.
const MAX_CAPTURED_OUTPUT_BYTES = 64 * 1024 * 1024;

export function buildInvocation(argv) {
  const args = [...argv];
  const hasTargets = args.some(arg => !arg.startsWith('-'));
  const hasWarningPolicy = args.some(
    arg => arg === '--deny-warnings' || arg.startsWith('--max-warnings'),
  );

  if (!hasTargets) args.push(...DEFAULT_TARGETS);
  if (!hasWarningPolicy) args.push('--deny-warnings');
  return args;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = buildInvocation(process.argv.slice(2));
  const result = spawnSync(cli, args, {
    cwd: repoRoot,
    stdio: 'inherit',
    maxBuffer: MAX_CAPTURED_OUTPUT_BYTES,
  });
  process.exit(result.status ?? 1);
}
