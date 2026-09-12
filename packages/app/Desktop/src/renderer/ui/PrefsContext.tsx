// Prefs context: owns the loaded Prefs and persists changes.  Components use
// usePrefs()/useT() instead of touching storage directly.

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { DEFAULT_PREFS, loadPrefs, savePrefs, type Prefs } from '../state/prefs.js';
import type { PrefsBackend } from '../state/prefs.js';
import { t as translate, type MessageKey } from './i18n.js';

export interface PrefsContextValue {
  prefs: Prefs;
  ready: boolean;
  setPrefs: (patch: Partial<Prefs>) => void;
  t: (key: MessageKey, vars?: Record<string, string | number>) => string;
}

const PrefsContext = createContext<PrefsContextValue | null>(null);

export interface PrefsProviderProps {
  children: ReactNode;
  /** Injected backend (tests); defaults to the host's best backend. */
  backend?: PrefsBackend | null;
  initial?: Prefs;
}

export function PrefsProvider({ children, backend, initial }: PrefsProviderProps) {
  const [prefs, setState] = useState<Prefs>(initial ?? DEFAULT_PREFS);
  const [ready, setReady] = useState(!!initial);

  useEffect(() => {
    let live = true;
    void loadPrefs(backend).then(loaded => {
      if (live) { setState(loaded); setReady(true); }
    });
    return () => { live = false; };
    // backend/initial are stable for the app's lifetime
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const setPrefs = useCallback((patch: Partial<Prefs>) => {
    setState(prev => {
      const next = { ...prev, ...patch };
      void savePrefs(next, backend);
      return next;
    });
  }, [backend]);

  const value = useMemo<PrefsContextValue>(() => ({
    prefs,
    ready,
    setPrefs,
    t: (key, vars) => translate(prefs.lang, key, vars),
  }), [prefs, ready, setPrefs]);

  return <PrefsContext.Provider value={value}>{children}</PrefsContext.Provider>;
}

export function usePrefs(): PrefsContextValue {
  const ctx = useContext(PrefsContext);
  if (!ctx) throw new Error('usePrefs must be used within a PrefsProvider');
  return ctx;
}

/** Translation helper bound to the current language.  Falls back to the
 *  default locale when rendered outside a PrefsProvider (e.g. unit tests of
 *  a single card), so presentational components stay standalone-usable. */
export function useT(): (key: MessageKey, vars?: Record<string, string | number>) => string {
  const ctx = useContext(PrefsContext);
  const lang = ctx?.prefs.lang ?? DEFAULT_PREFS.lang;
  return useCallback((key, vars) => translate(lang, key, vars), [lang]);
}
