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
      // Baseline 2026-10-23 (vitest 1.6.1): 79.6 / 76.82 / 67.11.
      // 2026-11-10: TypeScript 7 迁移升 vitest 5 后 v8 引擎的分支度量从
      // 76.82 掉到 68.5（在 e10f0ce 树上复测一致，与代码无关）。按原设计
      // 意图（留余量防噪音、阻止静默回退）把 branches 校准为 67；
      // statements/functions 度量未变，维持原值。后续补测试拉回。
      thresholds: { statements: 75, branches: 67, functions: 62 },
    },
  },
});
