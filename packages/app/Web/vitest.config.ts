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
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['src/**/*.test.*', 'src/**/*.d.ts'],
      // The existing tests under test/ are placeholders (expect(true).toBe(true))
      // and touch no source, so coverage is 0%. No threshold yet: add real
      // tests first, then enable one here.
    },
  },
});
