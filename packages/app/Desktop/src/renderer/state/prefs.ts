// Local UI preferences (theme / language / font size).  Persistence goes
// through a small backend abstraction: the Electron preload verbs when the
// shell provides them, falling back to localStorage (studio page / tests).
// The normalisation is a pure function so it is trivially testable.

export type Theme = 'light' | 'dark';
/** 界面语言：'auto' = 跟随操作系统（Reasonix 语义：desktopLanguage ""|"en"|"zh"）。 */
export type Lang = 'auto' | 'zh' | 'en';

export interface Prefs {
  theme: Theme;
  lang: Lang;
  fontSize: number;
}

export const DEFAULT_PREFS: Prefs = { theme: 'light', lang: 'zh', fontSize: 14 };

export const FONT_SIZE_RANGE = { min: 10, max: 24 } as const;

/** Coerce arbitrary persisted data into a valid Prefs (never throws). */
export function normalizePrefs(raw: unknown): Prefs {
  const o = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const theme: Theme = o.theme === 'dark' ? 'dark' : 'light';
  // lang 缺失（首次运行/无数据）→ DEFAULT_PREFS.lang（zh）；
  // 显式传入的未知值 → auto（合法回落）。两者分开：null 不等于非法输入。
  const lang: Lang =
    o.lang === 'zh' || o.lang === 'en' || o.lang === 'auto' ? o.lang
    : o.lang === undefined ? DEFAULT_PREFS.lang
    : 'auto';
  const n = typeof o.fontSize === 'number' ? o.fontSize : NaN;
  const fontSize = Number.isFinite(n) && n >= FONT_SIZE_RANGE.min && n <= FONT_SIZE_RANGE.max
    ? Math.round(n)
    : DEFAULT_PREFS.fontSize;
  return { theme, lang, fontSize };
}

export interface PrefsBackend {
  load(): Promise<unknown>;
  save(prefs: Prefs): Promise<void>;
}

export interface ElectronPrefsApi {
  getPrefs: () => Promise<unknown>;
  setPrefs: (prefs: Prefs) => Promise<void>;
}

export function electronPrefsBackend(api: ElectronPrefsApi): PrefsBackend {
  return { load: () => api.getPrefs(), save: prefs => api.setPrefs(prefs) };
}

export function localStoragePrefsBackend(key = 'trha.prefs'): PrefsBackend | null {
  if (typeof localStorage === 'undefined') return null;
  return {
    load: async () => {
      const raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    },
    save: async prefs => { localStorage.setItem(key, JSON.stringify(prefs)); },
  };
}

/** Pick the best available backend for the current host (may be null). */
export function pickPrefsBackend(): PrefsBackend | null {
  const api = (globalThis as { window?: { electronAPI?: Partial<ElectronPrefsApi> } }).window?.electronAPI;
  if (api && typeof api.getPrefs === 'function' && typeof api.setPrefs === 'function') {
    return electronPrefsBackend(api as ElectronPrefsApi);
  }
  return localStoragePrefsBackend();
}

export async function loadPrefs(backend: PrefsBackend | null = pickPrefsBackend()): Promise<Prefs> {
  if (!backend) return { ...DEFAULT_PREFS };
  try {
    return normalizePrefs(await backend.load());
  } catch {
    return { ...DEFAULT_PREFS };
  }
}

export async function savePrefs(prefs: Prefs, backend: PrefsBackend | null = pickPrefsBackend()): Promise<void> {
  if (!backend) return;
  try {
    await backend.save(normalizePrefs(prefs));
  } catch {
    /* prefs are best-effort; a failure must not break the UI */
  }
}
