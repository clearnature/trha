import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    exclude: ['node_modules', 'dist'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      include: ['../packages/scheduler/src/**/*.ts'],
      exclude: ['node_modules', 'dist', '**/*.d.ts'],
    },
    reporters: ['default', 'json'],
    outputFile: {
      json: 'results/test-results.json',
    },
  },
});