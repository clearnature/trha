import { describe, it, expect } from 'vitest';
import {
  DEFAULT_PREFS,
  electronPrefsBackend,
  loadPrefs,
  normalizePrefs,
  savePrefs,
  type Prefs,
  type PrefsBackend,
} from '../src/renderer/state/prefs.js';

function memoryBackend(initial: unknown = null): PrefsBackend & { value: unknown } {
  const box = {
    value: initial,
    load: async () => box.value,
    save: async (p: Prefs) => { box.value = p; },
  };
  return box;
}

describe('normalizePrefs', () => {
  it('keeps valid values', () => {
    expect(normalizePrefs({ theme: 'dark', lang: 'en', fontSize: 18 }))
      .toEqual({ theme: 'dark', lang: 'en', fontSize: 18 });
  });

  it('falls back for invalid or missing values', () => {
    expect(normalizePrefs(null)).toEqual(DEFAULT_PREFS);
    expect(normalizePrefs({ theme: 'blue', lang: 'fr', fontSize: 'big' })).toEqual(DEFAULT_PREFS);
  });

  it('clamps out-of-range font sizes and rounds', () => {
    expect(normalizePrefs({ fontSize: 9 }).fontSize).toBe(DEFAULT_PREFS.fontSize);
    expect(normalizePrefs({ fontSize: 99 }).fontSize).toBe(DEFAULT_PREFS.fontSize);
    expect(normalizePrefs({ fontSize: 15.6 }).fontSize).toBe(16);
  });
});

describe('prefs roundtrip', () => {
  it('loads what was saved (normalised)', async () => {
    const be = memoryBackend();
    await savePrefs({ theme: 'dark', lang: 'en', fontSize: 16 }, be);
    expect(await loadPrefs(be)).toEqual({ theme: 'dark', lang: 'en', fontSize: 16 });
  });

  it('returns defaults when no backend or when it throws', async () => {
    expect(await loadPrefs(null)).toEqual(DEFAULT_PREFS);
    const broken: PrefsBackend = { load: async () => { throw new Error('nope'); }, save: async () => { throw new Error('nope'); } };
    expect(await loadPrefs(broken)).toEqual(DEFAULT_PREFS);
    await expect(savePrefs(DEFAULT_PREFS, broken)).resolves.toBeUndefined();
  });

  it('sanitises saved data through the backend', async () => {
    const be = memoryBackend({ theme: 'dark', lang: 'xx', fontSize: 500 });
    const loaded = await loadPrefs(be);
    expect(loaded).toEqual({ theme: 'dark', lang: 'zh', fontSize: DEFAULT_PREFS.fontSize });
  });
});

describe('electronPrefsBackend', () => {
  it('delegates load/save to the preload verbs', async () => {
    let stored: unknown = { theme: 'dark' };
    const api = {
      getPrefs: async () => stored,
      setPrefs: async (p: Prefs) => { stored = p; },
    };
    const be = electronPrefsBackend(api);
    expect(await be.load()).toEqual({ theme: 'dark' });
    await be.save({ theme: 'light', lang: 'en', fontSize: 12 });
    expect(stored).toEqual({ theme: 'light', lang: 'en', fontSize: 12 });
  });
});
