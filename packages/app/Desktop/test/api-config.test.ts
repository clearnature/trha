import { describe, expect, it } from 'vitest';
import { resolveApiConfig } from '../src/renderer/stores/apiConfig.js';

describe('resolveApiConfig', () => {
  it('uses the preload token path inside the Electron shell', () => {
    const cfg = resolveApiConfig({ hasPreload: true, schedulerPort: 3456, isStudioPath: false });
    expect(cfg).toEqual({ base: 'http://localhost:3456', useToken: true });
  });

  it('uses the same-origin no-token path under /studio', () => {
    const cfg = resolveApiConfig({ hasPreload: false, isStudioPath: true });
    expect(cfg).toEqual({ base: '', useToken: false });
  });

  it('falls back to the default local port for a plain browser', () => {
    const cfg = resolveApiConfig({ hasPreload: false, isStudioPath: false });
    expect(cfg).toEqual({ base: 'http://localhost:3456', useToken: false });
  });

  it('prefers the shell path even when loaded under /studio-like dev URL', () => {
    // inside Electron the preload exists regardless of the page URL
    const cfg = resolveApiConfig({ hasPreload: true, schedulerPort: 9999, isStudioPath: true });
    expect(cfg.useToken).toBe(true);
    expect(cfg.base).toContain('9999');
  });
});
