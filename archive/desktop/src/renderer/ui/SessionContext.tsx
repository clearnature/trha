// Session store injection: UI components read the session model through
// this context so tests can mount with a mock-backed store and production
// mounts with the default (real port) store.

import { createContext, useContext, useMemo } from 'react';
import type { ReactNode } from 'react';
import { makeSessionStore } from '../state/sessionStore.js';
import type { SessionUiState } from '../state/sessionStore.js';
import type { Port } from '../port/port.js';

export type SessionStore = ReturnType<typeof makeSessionStore>;

const SessionContext = createContext<SessionStore | null>(null);

/** Module-level fallback store (production): assembled from the real port. */
let defaultStore: SessionStore | null = null;
export function getDefaultSessionStore(): SessionStore {
  if (!defaultStore) defaultStore = makeSessionStore();
  return defaultStore;
}

export interface SessionProviderProps {
  children: ReactNode;
  /** Inject a pre-built store (tests) or a port (tests/dev). */
  store?: SessionStore;
  port?: Port;
}

export function SessionProvider({ children, store, port }: SessionProviderProps) {
  const value = useMemo(() => store ?? makeSessionStore(port), [store, port]);
  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

/** Select from the session store; throws when used outside a provider. */
export function useSession<T>(selector: (s: SessionUiState) => T): T {
  const store = useContext(SessionContext) ?? getDefaultSessionStore();
  return store(selector);
}

/** The whole store (for imperative actions in event handlers). */
export function useSessionStore(): SessionStore {
  return useContext(SessionContext) ?? getDefaultSessionStore();
}
