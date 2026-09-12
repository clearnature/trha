// Sync the scheduler dist into Desktop resources before packaging so the
// packaged app carries its own scheduler under resources/scheduler
// (electron-builder extraResources).  Run before `electron-builder`.
import { cp, mkdir, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = path.resolve(root, '..', '..', 'scheduler', 'dist');
const out = path.join(root, 'resources', 'scheduler-dist');

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
await cp(src, out, { recursive: true });
// keep the ESM package marker so node loads the bundled dist as a module
await cp(path.join(root, '..', '..', 'scheduler', 'package.json'), path.join(out, 'package.json'));
try {
  await cp(path.join(root, '..', '..', 'scheduler', 'package-lock.json'), path.join(out, 'package-lock.json'));
} catch { /* optional */ }
// install the scheduler's production dependencies inside the resource dir so
// the bundled launcher is self-contained (node resolves node_modules upward)
execFileSync('npm', ['ci', '--omit=dev', '--no-audit', '--no-fund'], { cwd: out, stdio: 'inherit', env: process.env });
console.log(`scheduler dist synced -> ${out}`);
