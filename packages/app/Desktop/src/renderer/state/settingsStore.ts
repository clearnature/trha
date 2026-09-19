// 设置持久化 store：模型偏好 / 权限规则 / 快捷键 —— localStorage 持久化
// （切换 tab / 重启应用不丢）。复用 prefs.ts 的 localStorage backend 模式。
// 数据形状与各面板的本地 useState 对齐；接好后组件改为 useExtSettings。

import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';

export interface ModelPrefs {
  defaultModel: string;
  planner: string;
  vision: string;
  webSearch: string;
  subagentModel: string;
  subagentEffort: string;
  thinkLang: string;
  compactMode: string;
  compactCustom: string;
}

export interface PermRule { kind: 'deny' | 'ask' | 'allow'; pattern: string; }
export interface Shortcut { action: string; combo: string; }

export interface ExtSettings {
  modelPrefs: ModelPrefs;
  permRules: PermRule[];
  shortcuts: Shortcut[];
}

const DEFAULT_EXT: ExtSettings = {
  modelPrefs: {
    defaultModel: '', planner: 'follow-session', vision: 'auto', webSearch: 'auto',
    subagentModel: 'follow-main', subagentEffort: 'auto', thinkLang: 'auto',
    compactMode: 'recommended', compactCustom: '80',
  },
  permRules: [],
  shortcuts: [
    { action: 'settings.shortcuts.newSession', combo: 'Ctrl+N' },
    { action: 'settings.shortcuts.focusComposer', combo: 'Ctrl+L' },
    { action: 'settings.shortcuts.approve', combo: 'Ctrl+Enter' },
    { action: 'settings.shortcuts.deny', combo: 'Esc' },
    { action: 'settings.shortcuts.openSettings', combo: 'Ctrl+,' },
  ],
};

/** 规范化加载数据（从不抛异常）。 */
function normalizeExt(raw: unknown): ExtSettings {
  const o = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const mp = (o.modelPrefs ?? {}) as Partial<ModelPrefs>;
  const pr = Array.isArray(o.permRules) ? (o.permRules as PermRule[])
    .filter(r => r && typeof r.pattern === 'string' && ['deny', 'ask', 'allow'].includes(r.kind)) : [];
  const sc = Array.isArray(o.shortcuts) ? (o.shortcuts as Shortcut[])
    .filter(s => s && typeof s.action === 'string' && typeof s.combo === 'string') : [];
  return {
    modelPrefs: {
      defaultModel: typeof mp.defaultModel === 'string' ? mp.defaultModel : DEFAULT_EXT.modelPrefs.defaultModel,
      planner: typeof mp.planner === 'string' ? mp.planner : DEFAULT_EXT.modelPrefs.planner,
      vision: typeof mp.vision === 'string' ? mp.vision : DEFAULT_EXT.modelPrefs.vision,
      webSearch: typeof mp.webSearch === 'string' ? mp.webSearch : DEFAULT_EXT.modelPrefs.webSearch,
      subagentModel: typeof mp.subagentModel === 'string' ? mp.subagentModel : DEFAULT_EXT.modelPrefs.subagentModel,
      subagentEffort: typeof mp.subagentEffort === 'string' ? mp.subagentEffort : DEFAULT_EXT.modelPrefs.subagentEffort,
      thinkLang: typeof mp.thinkLang === 'string' ? mp.thinkLang : DEFAULT_EXT.modelPrefs.thinkLang,
      compactMode: ['early', 'recommended', 'late', 'custom'].includes(mp.compactMode ?? '')
        ? mp.compactMode! : DEFAULT_EXT.modelPrefs.compactMode,
      compactCustom: typeof mp.compactCustom === 'string' ? mp.compactCustom : DEFAULT_EXT.modelPrefs.compactCustom,
    },
    permRules: pr,
    shortcuts: sc.length > 0 ? sc : DEFAULT_EXT.shortcuts,
  };
}

export const useExtSettings = create<ExtSettings & {
  setModelPrefs(patch: Partial<ModelPrefs>): void;
  addPermRule(kind: PermRule['kind'], pattern: string): void;
  removePermRule(idx: number): void;
  setShortcut(idx: number, combo: string): void;
  addShortcut(action: string, combo: string): void;
  removeShortcut(idx: number): void;
  reset(): void;
}>()(persist(
  (set, get) => ({
    ...DEFAULT_EXT,
    setModelPrefs: patch => set({ modelPrefs: { ...get().modelPrefs, ...patch } }),
    addPermRule: (kind, pattern) => set({ permRules: [...get().permRules, { kind, pattern }] }),
    removePermRule: idx => set({ permRules: get().permRules.filter((_, i) => i !== idx) }),
    setShortcut: (idx, combo) => set({ shortcuts: get().shortcuts.map((s, i) => i === idx ? { ...s, combo } : s) }),
    addShortcut: (action, combo) => set({ shortcuts: [...get().shortcuts, { action, combo }] }),
    removeShortcut: idx => set({ shortcuts: get().shortcuts.filter((_, i) => i !== idx) }),
    reset: () => set({ ...DEFAULT_EXT }),
  }),
  { name: 'trha.extSettings', storage: createJSONStorage(() => localStorage), merge: (persisted, current) =>
      normalizeExt(persisted) },
));