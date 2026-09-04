// Web app store — mirrors Desktop store but uses fetch (no Electron IPC)

import { create } from 'zustand';
import type { Session, Message, Model, Tool, ModeConfig, AgentState } from '../types';

const API_BASE = '';  // Same origin, Vite proxies /api to scheduler

async function apiFetch(path: string, options: RequestInit = {}) {
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...options.headers },
  });
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  return res.json();
}

interface AppState {
  sessions: Session[];
  currentSession: Session | null;
  models: Model[];
  tools: Tool[];
  modes: Record<string, ModeConfig>;
  currentMode: string;
  agentState: AgentState;
  theme: 'light' | 'dark';
  showSettings: boolean;

  createSession: () => Promise<void>;
  setCurrentSession: (session: Session | null) => void;
  sendMessage: (content: string) => Promise<void>;
  loadModels: () => Promise<void>;
  loadTools: () => Promise<void>;
  loadModes: () => Promise<void>;
  setMode: (mode: string) => Promise<void>;
  setTheme: (theme: 'light' | 'dark') => void;
  setShowSettings: (show: boolean) => void;
}

export const useAppStore = create<AppState>((set, get) => ({
  sessions: [],
  currentSession: null,
  models: [],
  tools: [],
  modes: {},
  currentMode: 'standard',
  agentState: { status: 'idle' },
  theme: 'light',
  showSettings: false,

  createSession: async () => {
    const { currentMode, sessions } = get();
    const data = await apiFetch('/api/session/start', {
      method: 'POST',
      body: JSON.stringify({ mode: currentMode }),
    });
    const newSession: Session = {
      id: data.sessionId,
      title: `${currentMode} session ${sessions.length + 1}`,
      mode: currentMode,
      messages: [],
      createdAt: new Date(),
    };
    set((s) => ({ sessions: [...s.sessions, newSession], currentSession: newSession }));
  },

  setCurrentSession: (session) => set({ currentSession: session }),

  sendMessage: async (content: string) => {
    const { currentSession } = get();
    if (!currentSession) return;

    const userMsg: Message = { role: 'user', content };
    set((s) => {
      const updated = { ...currentSession, messages: [...currentSession.messages, userMsg] };
      return {
        currentSession: updated,
        sessions: s.sessions.map(x => x.id === updated.id ? updated : x),
        agentState: { status: 'processing' as const },
      };
    });

    try {
      const data = await apiFetch('/api/agent/step', {
        method: 'POST',
        body: JSON.stringify({ sessionId: currentSession.id, message: content }),
      });
      const assistantMsg: Message = { role: 'assistant', content: data.reply };
      set((s) => {
        const updated = { ...currentSession, messages: [...currentSession.messages, userMsg, assistantMsg] };
        return {
          currentSession: updated,
          sessions: s.sessions.map(x => x.id === updated.id ? updated : x),
          agentState: { status: 'idle' as const },
        };
      });
    } catch (error) {
      set({ agentState: { status: 'error', message: String(error) } });
    }
  },

  loadModels: async () => {
    try { set({ models: await apiFetch('/api/models') }); }
    catch { set({ models: [{ name: 'mimo-v2.5-pro', description: 'MIMO v2.5 Pro', contextSize: 131072 }] }); }
  },

  loadTools: async () => {
    try {
      const { currentMode } = get();
      set({ tools: await apiFetch(`/api/tools?mode=${currentMode}`) });
    } catch { set({ tools: [] }); }
  },

  loadModes: async () => {
    try { set({ modes: await apiFetch('/api/modes') }); }
    catch { set({ modes: {} }); }
  },

  setMode: async (mode: string) => {
    set({ currentMode: mode });
    try { set({ tools: await apiFetch(`/api/tools?mode=${mode}`) }); } catch {}
  },

  setTheme: (theme) => {
    document.documentElement.setAttribute('data-theme', theme);
    set({ theme });
  },
  setShowSettings: (show) => set({ showSettings: show }),
}));
