import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The production build is served by the scheduler under /studio/, so asset
// URLs must carry that prefix; `vite dev` keeps serving from the root.
export default defineConfig(({ command }) => ({
  base: command === 'build' ? '/studio/' : '/',
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      // the scheduler serves HTTPS with a self-signed loopback certificate
      '/api': { target: 'https://127.0.0.1:28433', secure: false, changeOrigin: true },
      '/studio': { target: 'https://127.0.0.1:28433', secure: false, changeOrigin: true },
    },
  },
  build: {
    outDir: 'dist',
  },
}));
