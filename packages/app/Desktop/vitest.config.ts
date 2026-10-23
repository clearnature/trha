import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    setupFiles: ['./test/setup.ts'],
    include: ['test/**/*.test.ts', 'test/**/*.test.tsx'],
    exclude: ['node_modules', 'dist'],
    coverage: {
      provider: 'v8',
      reporter: ['text-summary'],
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['src/**/*.test.*', 'src/**/*.d.ts'],
      // Baseline 2026-10-23: 30.56 / 72.94 / 52.9. Renderer UI components
      // dominate the uncovered statements; branches/functions are healthier
      // and get the tighter floor.
      thresholds: { statements: 28, branches: 70, functions: 50 },
    },
  },
});
