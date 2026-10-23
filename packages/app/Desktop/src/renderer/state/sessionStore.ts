// Session UI store: the single client-side model for one desktop session,
// driven exclusively through a Port (never direct fetch).  Message text
// comes from the step() return value (single aggregate reply today);
// tool/plan/decision arrive live through subscribe().  Assistant/user text
// is therefore not double-counted from the event stream.

import { create } from 'zustand';
import type { Port } from '../port/port.js';
import type { PortModeConfig, PortModel, PortSession, PortToolEvent, PortToolSpec, StudioVersion } from '../port/types.js';
import { createPort } from '../port/index.js';

export type UiMessage =
  | { kind: 'user'; text: string }
  | { kind: 'assistant'; text: string }
  | { kind: 'tool'; tool: PortToolEvent }
  | { kind: 'notice'; text: string };

export interface SessionUiState {
  port: Port;
  sessions: PortSession[];
  currentId: string | null;
  uiMessages: UiMessage[];
  /** Text of the answer currently arriving (A3); '' when idle. */
  streamText: string;
  busy: boolean;
  pendingPlan: { message: string } | null;
  selectedMode: string;
  /** Which saved provider/model answers steps (P6); null = kernel default. */
  selectedProvider: string | null;
  selectedModel: string | null;
  /** 模型生成参数（LLM 设置面板；null 字段 = 内核默认）。接线到 step 请求 genParams。 */
  genParams: { temperature: number | null; topP: number | null; maxTokens: number | null };
  // catalog + shell metadata
  modes: Record<string, PortModeConfig>;
  models: PortModel[];
  tools: PortToolSpec[];
  version: StudioVersion | null;
  lastError: string | null;
  /** Kernel causal-constraint verdict of the last step (D-1 / P3): pass | warn | null. */
  constraint: Record<string, unknown> | null;

  loadCatalog(): Promise<void>;
  loadVersion(): Promise<void>;
  refresh(): Promise<void>;
  select(id: string): Promise<void>;
  create(): Promise<string>;
  remove(id: string): Promise<void>;
  send(text: string): Promise<void>;
  decide(approve: boolean): Promise<void>;
  setMode(mode: string): void;
  setTarget(provider: string | null, model: string | null): void;
  /** 设置模型生成参数（LLM 设置面板 ↔ step 请求）。 */
  setGenParams(p: { temperature: number | null; topP: number | null; maxTokens: number | null }): void;
}

export function makeSessionStore(port?: Port) {
  return create<SessionUiState>((set, get) => {
    let unsubscribe: (() => void) | null = null;
    const p = port ?? createPort();

    const attach = async (id: string) => {
      if (unsubscribe) { unsubscribe(); unsubscribe = null; }
      const session = await p.getSession(id);
      set({
        currentId: id,
        selectedMode: session.mode,
        pendingPlan: null,
        streamText: '',
        uiMessages: session.messages.map(m =>
          m.role === 'user' ? { kind: 'user' as const, text: m.content }
            : m.role === 'assistant' ? { kind: 'assistant' as const, text: m.content }
              : { kind: 'notice' as const, text: `[${m.role}] ${m.content}` }),
      });
      unsubscribe = p.subscribe(id, e => {
        if (e.type === 'tool') {
          set(s => ({ uiMessages: [...s.uiMessages, { kind: 'tool', tool: e.tool }] }));
        } else if (e.type === 'plan') {
          set({ pendingPlan: { message: e.message } });
        } else if (e.type === 'decision') {
          set({ pendingPlan: null });
        } else if (e.type === 'delta') {
          // A3: render the answer as it arrives; step() replaces it with the
          // final text, so a dropped frame can never corrupt the transcript.
          set(s => ({ streamText: s.streamText + e.text }));
        }
        // message events are not appended: step() return is the text source
      });
    };

    return {
      port: p,
      sessions: [],
      currentId: null,
      uiMessages: [],
      streamText: '',
      busy: false,
      pendingPlan: null,
      selectedMode: 'standard',
      selectedProvider: null,
      selectedModel: null,
      genParams: { temperature: null, topP: null, maxTokens: null },
      modes: {},
      models: [],
      tools: [],
      version: null,
      lastError: null,
      constraint: null,

      loadCatalog: async () => {
        try {
          const [modes, models, tools] = await Promise.all([p.modes(), p.models(), p.tools()]);
          set({ modes, models, tools });
        } catch (e) {
          set({ lastError: String(e) });
        }
      },

      loadVersion: async () => {
        try {
          set({ version: await p.studioVersion() });
        } catch (e) {
          set({ lastError: String(e) });
        }
      },

      refresh: async () => {
        try {
          set({ sessions: await p.listSessions() });
        } catch (e) {
          set({ lastError: String(e) });
        }
      },

      select: async (id) => { await attach(id); },

      create: async () => {
        const { sessionId } = await p.createSession(get().selectedMode);
        await get().refresh();
        await attach(sessionId);
        return sessionId;
      },

      remove: async (id) => {
        await p.deleteSession(id);
        if (get().currentId === id) {
          if (unsubscribe) { unsubscribe(); unsubscribe = null; }
          set({ currentId: null, uiMessages: [], pendingPlan: null });
        }
        await get().refresh();
      },

      send: async (text) => {
        const sid = get().currentId;
        if (!sid || !text.trim() || get().busy) return;
        set(s => ({ busy: true, streamText: '', uiMessages: [...s.uiMessages, { kind: 'user', text }] }));
        try {
          const { selectedProvider, selectedModel, genParams } = get();
          const gp = genParams ?? { temperature: null, topP: null, maxTokens: null };
          const out = await p.step(sid, text, undefined, {
            provider: selectedProvider ?? undefined,
            model: selectedModel ?? undefined,
            genParams: {
              temperature: gp.temperature ?? undefined,
              topP: gp.topP ?? undefined,
              maxTokens: gp.maxTokens ?? undefined,
            },
          });
          if (out.status === 'awaiting_approval') {
            set({ pendingPlan: { message: text }, streamText: '' });
          } else {
            // The streamed text is replaced by the final reply, so the
            // transcript never depends on every delta having arrived.
            set(s => ({
              pendingPlan: null,
              streamText: '',
              constraint: (out.constraint as Record<string, unknown> | undefined) ?? null,
              uiMessages: [...s.uiMessages, { kind: 'assistant', text: out.reply }],
            }));
          }
        } catch (e) {
          set(s => ({ streamText: '', uiMessages: [...s.uiMessages, { kind: 'notice', text: String(e) }] }));
        } finally {
          set({ busy: false });
        }
      },

      decide: async (approve) => {
        const sid = get().currentId;
        if (!sid) return;
        await p.decision(sid, approve);
        set({ pendingPlan: null });
        if (approve) {
          const s = await p.getSession(sid);
          const last = s.messages[s.messages.length - 1];
          if (last && last.role === 'assistant') {
            set(st => ({ uiMessages: [...st.uiMessages, { kind: 'assistant', text: last.content }] }));
          }
        }
      },

      setMode: (mode) => set({ selectedMode: mode }),

      setTarget: (provider, model) => set({ selectedProvider: provider, selectedModel: model }),
      setGenParams: (p) => set({ genParams: p }),
    };
  });
}

/** Development/test helper: a store wired to the mock port. */
export const useMockSessionStore = makeSessionStore();
