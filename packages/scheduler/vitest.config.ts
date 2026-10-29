import { defineConfig } from 'vitest/config';

// ── Memory guard (2026-10-25 incident) ──────────────────────────────────────
// This suite spawns REAL child processes: headless Chrome (browser-tools),
// login bash shells (terminal_open), and scheduler children. With vitest's
// default worker pool on a 36-core box that meant dozens of concurrent forks
// and several Chromium instances per full run — two overlapping runs OOM'd the
// machine. Pool is therefore hard-capped; dev runs target single spec files.
export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['test/**/*.test.ts'],
    exclude: ['node_modules', 'dist'],
    // Headless Chrome / shell spawns can exceed the 5s default on loaded CI runners.
    testTimeout: 30_000,
    hookTimeout: 30_000,
    pool: 'forks',
    poolOptions: {
      forks: {
        // Hard ceiling: browser + bash spawning suites must never fan out wide.
        maxForks: 4,
        minForks: 1,
        isolate: true,
      },
    },
    coverage: {
      provider: 'v8',
      reporter: ['text-summary'],
      include: ['src/**/*.ts'],
      exclude: ['src/**/*.test.ts', 'src/**/*.d.ts'],
      // Baseline 2026-10-23: 79.6 / 76.82 / 67.11. Leave a little headroom so
      // refactors do not fail on noise, but stop silent regressions.
      thresholds: { statements: 75, branches: 72, functions: 62 },
    },
  },
});
