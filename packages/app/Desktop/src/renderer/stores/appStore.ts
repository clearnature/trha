import { create } from 'zustand';
import type { Session, Message, Model, Tool, AgentState } from '../../shared/types';

// ── API client ──────────────────────────────────────────────────────────

let apiBase = 'http://localhost:3456';
let apiToken = '';

export async function initAPI() {
  if (window.electronAPI) {
    const port = await window.electronAPI.getSchedulerPort();
    apiToken = await window.electronAPI.getToken();
    apiBase = `http://localhost:${port}`;
  }
}

async function apiFetch(path: string, options: RequestInit = {}) {
  const res = await fetch(`${apiBase}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiToken}`,
      ...options.headers,
    },
  });
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  return res.json();
}

// ── Types ───────────────────────────────────────────────────────────────

export interface ModeConfig {
  name: string;
  description: string;
  tools: string[];
  persona: { enabled: boolean; template: string; maxBytes: number };
  compaction: { enabled: boolean; prunerEnabled: boolean; thresholdChars: number; headChars: number; tailChars: number };
  delegation: { enabled: boolean; forkEnabled: boolean; ralphEnabled: boolean; maxRounds: number };
  ptc: { enabled: boolean; language: string; description: string };
  hasPlan: boolean;
  hasTodo: boolean;
  hasWebSearch: boolean;
  hasShell: boolean;
  maxTokens: number;
  contextSize: number;
}

// ── Store ───────────────────────────────────────────────────────────────

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

  // Actions
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
      messages: [],
      createdAt: new Date(),
    };
    set((state) => ({
      sessions: [...state.sessions, newSession],
      currentSession: newSession,
    }));
  },

  setCurrentSession: (session) => set({ currentSession: session }),

  sendMessage: async (content: string) => {
    const { currentSession } = get();
    if (!currentSession) return;

    const userMsg: Message = { role: 'user', content };
    set((state) => {
      const updated = { ...currentSession, messages: [...currentSession.messages, userMsg] };
      return {
        currentSession: updated,
        sessions: state.sessions.map(s => s.id === updated.id ? updated : s),
        agentState: { status: 'processing' as const },
      };
    });

    try {
      const data = await apiFetch('/api/agent/step', {
        method: 'POST',
        body: JSON.stringify({ sessionId: currentSession.id, message: content }),
      });
      const assistantMsg: Message = { role: 'assistant', content: data.reply };
      set((state) => {
        const updated = { ...currentSession, messages: [...currentSession.messages, userMsg, assistantMsg] };
        return {
          currentSession: updated,
          sessions: state.sessions.map(s => s.id === updated.id ? updated : s),
          agentState: { status: 'idle' as const },
        };
      });
    } catch (error) {
      set({ agentState: { status: 'error', message: String(error) } });
    }
  },

  loadModels: async () => {
    try {
      const models = await apiFetch('/api/models');
      set({ models });
    } catch {
      set({ models: [
        { name: 'mimo-v2.5-pro', description: 'MIMO v2.5 Pro', contextSize: 131072 },
        { name: 'deepseek-chat', description: 'DeepSeek Chat', contextSize: 65536 },
      ]});
    }
  },

  loadTools: async () => {
    try {
      const { currentMode } = get();
      const tools = await apiFetch(`/api/tools?mode=${currentMode}`);
      set({ tools });
    } catch {
      set({ tools: [
        { name: 'bash', description: 'Execute shell commands', schema: {} },
        { name: 'read', description: 'Read a file', schema: {} },
        { name: 'write', description: 'Write a file', schema: {} },
      ]});
    }
  },

  loadModes: async () => {
    try {
      const modes = await apiFetch('/api/modes');
      set({ modes });
    } catch {
      set({ modes: {
        standard: { name: 'standard', description: 'Full coding agent', tools: ['bash','read','write','grep','glob','edit','web_search','subagent','subagent_fork','workflow','todo','plan','ask_user','skill','checkpoint','memory'], persona: { enabled: true, template: '', maxBytes: 65536 }, compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 }, delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 }, ptc: { enabled: false, language: '', description: '' }, hasPlan: true, hasTodo: true, hasWebSearch: true, hasShell: true, maxTokens: 8192, contextSize: 131072 },
        ptc: { name: 'ptc', description: 'Program-the-code', tools: ['bash','read','write','grep','glob','edit','web_search','subagent','subagent_fork','run_code','ask_user','skill','checkpoint','memory'], persona: { enabled: true, template: '', maxBytes: 65536 }, compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 }, delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 }, ptc: { enabled: true, language: 'typescript', description: '' }, hasPlan: false, hasTodo: false, hasWebSearch: true, hasShell: true, maxTokens: 16384, contextSize: 131072 },
        minimal: { name: 'minimal', description: 'Lightweight', tools: ['bash','read','write','grep','glob','edit','ask_user'], persona: { enabled: false, template: '', maxBytes: 0 }, compaction: { enabled: false, prunerEnabled: false, thresholdChars: 0, headChars: 0, tailChars: 0 }, delegation: { enabled: false, forkEnabled: false, ralphEnabled: false, maxRounds: 0 }, ptc: { enabled: false, language: '', description: '' }, hasPlan: false, hasTodo: false, hasWebSearch: false, hasShell: true, maxTokens: 4096, contextSize: 65536 },
        cordis: { name: 'cordis', description: 'Base layer', tools: [], persona: { enabled: false, template: '', maxBytes: 0 }, compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 }, delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 }, ptc: { enabled: false, language: '', description: '' }, hasPlan: false, hasTodo: false, hasWebSearch: false, hasShell: true, maxTokens: 4096, contextSize: 65536 },
      }});
    }
  },

  setMode: async (mode: string) => {
    set({ currentMode: mode });
    try {
      const tools = await apiFetch(`/api/tools?mode=${mode}`);
      set({ tools });
    } catch { /* ignore */ }
  },

  setTheme: (theme) => set({ theme }),
  setShowSettings: (show) => set({ showSettings: show }),
}));
