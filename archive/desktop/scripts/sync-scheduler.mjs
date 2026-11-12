// Sync the scheduler dist into Desktop resources before packaging so the
// packaged app carries its own scheduler under resources/scheduler
// (electron-builder extraResources).  Run before `electron-builder`.
import { cp, mkdir, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

/** Pure path planning, kept separate so tests can assert the contract. */
export function syncPlan(desktopRoot) {
  const schedulerRoot = path.resolve(desktopRoot, '..', '..', 'scheduler');
  return {
    schedulerRoot,
    src: path.join(schedulerRoot, 'dist'),
    out: path.join(desktopRoot, 'resources', 'scheduler-dist'),
    packageJson: path.join(schedulerRoot, 'package.json'),
    lockfile: path.join(schedulerRoot, 'package-lock.json'),
  };
}

export async function syncScheduler(desktopRoot, { runInstall = true } = {}) {
  const plan = syncPlan(desktopRoot);

  await rm(plan.out, { recursive: true, force: true });
  await mkdir(plan.out, { recursive: true });
  await cp(plan.src, plan.out, { recursive: true });

  // keep the ESM package marker so node loads the bundled dist as a module
  await cp(plan.packageJson, path.join(plan.out, 'package.json'));
  try {
    await cp(plan.lockfile, path.join(plan.out, 'package-lock.json'));
  } catch {
    /* optional */
  }

  if (runInstall) {
    // install the scheduler's production dependencies inside the resource dir
    // so the bundled launcher is self-contained (node resolves node_modules
    // upward)
    execFileSync('npm', ['ci', '--omit=dev', '--no-audit', '--no-fund'], {
      cwd: plan.out,
      stdio: 'inherit',
      env: process.env,
    });
  }

  return plan;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const plan = await syncScheduler(desktopRoot);
  console.log(`scheduler dist synced -> ${plan.out}`);
}
