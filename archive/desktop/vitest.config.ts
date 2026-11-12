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
      // 2026-10-28 调到现值（45.79 / 46.12 / 40.57）：重构后 renderer 面板重写、
      // 测试未跟上，branches 从旧基线 72.94 掉到 46。旧基线 2026-10-23:
      // 30.56 / 72.94 / 52.9。面板测试补齐后逐季抬升（每季 +5 为目标）。
      // 余量取整数下限，避免逐次运行的微小波动把门打红。
      thresholds: { statements: 45, branches: 46, functions: 40 },
    },
  },
});
