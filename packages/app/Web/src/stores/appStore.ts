// Web app store — mirrors Desktop store but uses fetch (no Electron IPC)

import { create } from 'zustand';
import type {
  Session, Message, Model, Tool, ModeConfig, AgentState,
  AgentEntry, FileItem, SessionInfo,
} from '../types';
import { mergeToolEvents, parseSsePayload } from '../layout/sse';
import type { ToolEvent } from '../layout/sse';

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
  sessionInfo: SessionInfo | null;
  agents: AgentEntry[];
  files: FileItem[];
  toolEvents: ToolEvent[];
  reasoning: string;
  permission: { mode: string; label: string; planMode: boolean; cycle: string[] } | null;
  currentModel: string;
  rightPanel: { path: string; text: string } | null;
  plugins: { name: string; version?: string; description?: string }[];
  balance: { currency: string; total: number } | null;

  createSession: () => Promise<void>;
  setCurrentSession: (session: Session | null) => void;
  sendMessage: (content: string) => Promise<void>;
  loadModels: () => Promise<void>;
  loadTools: () => Promise<void>;
  loadModes: () => Promise<void>;
  setMode: (mode: string) => Promise<void>;
  setTheme: (theme: 'light' | 'dark') => void;
  setShowSettings: (show: boolean) => void;
  refreshSessionInfo: () => Promise<void>;
  loadAgents: () => Promise<void>;
  loadFiles: () => Promise<void>;
  subscribeEvents: (sessionId: string) => () => void;
  loadPermission: () => Promise<void>;
  setPermission: (mode: string) => Promise<void>;
  setCurrentModel: (model: string) => void;
  openFile: (path: string) => Promise<void>;
  closeRightPanel: () => void;
  loadPlugins: () => Promise<void>;
  loadBalance: () => Promise<void>;
}

export const useAppStore = create<AppState>((set, get) => ({
  sessions: [],
  currentSession: null,
  models: [],
  tools: [],
  modes: {},
  currentMode: 'standard',
  agentState: { status: 'idle' },
  theme: 'dark',
  showSettings: false,
  sessionInfo: null,
  agents: [],
  files: [],
  toolEvents: [],
  reasoning: '',
  permission: null,
  currentModel: '',
  rightPanel: null,
  plugins: [],
  balance: null,

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
    void get().loadPermission();
  },

  setCurrentSession: (session) => set({ currentSession: session }),

  sendMessage: async (content: string) => {
    const { currentSession } = get();
    if (!currentSession) return;

    const userMsg: Message = { role: 'user', content };
    set({ toolEvents: [], reasoning: '' });
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
        body: JSON.stringify({
          sessionId: currentSession.id,
          message: content,
          ...(get().currentModel ? { model: get().currentModel } : {}),
        }),
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
    try {
      const models: Model[] = await apiFetch('/api/models');
      set({ models, currentModel: get().currentModel || models[0]?.name || '' });
    } catch {
      const models: Model[] = [{ name: 'mimo-v2.5-pro', description: 'MIMO v2.5 Pro', contextSize: 131072 }];
      set({ models, currentModel: get().currentModel || models[0]?.name || '' });
    }
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

  refreshSessionInfo: async () => {
    const sid = get().currentSession?.id;
    if (!sid) { set({ sessionInfo: null }); return; }
    try {
      const raw = await apiFetch(`/api/session/${encodeURIComponent(sid)}`);
      set({
        sessionInfo: {
          todos: Array.isArray(raw.todos) ? raw.todos : [],
          goal: typeof raw.goal?.objective === 'string' ? raw.goal.objective : null,
          cwd: typeof raw.cwd === 'string' ? raw.cwd : null,
          promptTokens: Number(raw.lastPromptTokens) || 0,
          cacheHit: Number(raw.cacheHitTokens) || 0,
          cacheMiss: Number(raw.cacheMissTokens) || 0,
        },
      });
    } catch { /* session gone: keep the previous view */ }
  },

  loadAgents: async () => {
    try {
      const rows = await apiFetch('/api/sessions') as AgentEntry[];
      set({ agents: rows.map(r => ({ id: r.id, parentId: r.parentId ?? null })) });
    } catch { set({ agents: [] }); }
  },

  loadFiles: async () => {
    const sid = get().currentSession?.id;
    try {
      const q = sid ? `?sessionId=${encodeURIComponent(sid)}&limit=8` : '?limit=8';
      const body = await apiFetch(`/api/workspace/files${q}`) as { files: FileItem[] };
      set({ files: Array.isArray(body.files) ? body.files : [] });
    } catch { set({ files: [] }); }
  },

  // Live turn events: tool progress and reasoning ride one SSE stream.
  subscribeEvents: (sessionId) => {
    const source = new EventSource(`/api/events/${encodeURIComponent(sessionId)}`);
    source.onmessage = (ev) => {
      const parsed = parseSsePayload(ev.data);
      if (parsed.kind === 'tool') {
        set((s) => ({ toolEvents: mergeToolEvents(s.toolEvents, parsed.tool) }));
      } else if (parsed.kind === 'reasoning') {
        set((s) => ({ reasoning: s.reasoning + parsed.text }));
      }
    };
    return () => source.close();
  },

  // Permission posture (read-only → ask → auto → yolo → plan), the input
  // row's `conversation.input.permission` control.
  loadPermission: async () => {
    const sid = get().currentSession?.id;
    if (!sid) { set({ permission: null }); return; }
    try {
      set({ permission: await apiFetch(`/api/session/${encodeURIComponent(sid)}/mode`) });
    } catch { /* keep the previous posture */ }
  },

  setPermission: async (mode) => {
    const sid = get().currentSession?.id;
    if (!sid) return;
    try {
      const next = await apiFetch(`/api/session/${encodeURIComponent(sid)}/mode`, {
        method: 'POST',
        body: JSON.stringify({ action: 'set', mode }),
      });
      set({ permission: next });
    } catch { /* leave the select on the last known posture */ }
  },

  setCurrentModel: (model) => set({ currentModel: model }),

  // Right panel: a workspace file preview (dsh rightbar occupant).
  openFile: async (path) => {
    if (path.endsWith('/')) return;
    const sid = get().currentSession?.id;
    const q = new URLSearchParams({ path });
    if (sid) q.set('sessionId', sid);
    try {
      const body = await apiFetch(`/api/workspace/file?${q.toString()}`) as { text: string };
      set({ rightPanel: { path, text: body.text } });
    } catch {
      set({ rightPanel: { path, text: '(unable to read this file)' } });
    }
  },

  closeRightPanel: () => set({ rightPanel: null }),

  // Settings panel data: installed plugins and the provider balance.
  loadPlugins: async () => {
    try { set({ plugins: await apiFetch('/api/plugins') }); }
    catch { set({ plugins: [] }); }
  },

  loadBalance: async () => {
    try { set({ balance: await apiFetch('/api/balance') }); }
    catch { set({ balance: null }); }
  },
}));
