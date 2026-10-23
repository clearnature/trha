import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['test/**/*.test.ts'],
    exclude: ['node_modules', 'dist'],
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
