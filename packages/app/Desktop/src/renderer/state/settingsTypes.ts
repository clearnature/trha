// 设置中心层级模型——对齐 DeepSeek-Reasonix 完整架构（三维）：
//   A. 11 个「完整设置功能区」（需要 SettingsView；见 SettingsPanel.tsx:388 needsSettings）
//   B. 8 个导航分组（见 SettingsNavigation.tsx:35-44 SETTINGS_TAB_GROUPS）
//   C. 21 个 tab 全集（见 types.ts:1642 SettingsTab）
// 依据：docs/plans/reasonix-settings-architecture-analysis.md
//
// 每个 tab 标注 trha 实现状态：
//   'done'    —— 已实现并接线
//   'partial' —— UI 已设计/部分接线，剩余接口预留
//   'scaffold'—— UI 呈现 + 预留接口（未实现接线）

export type TabStatus = 'done' | 'partial' | 'scaffold';

export interface SettingsTabDef {
  id: string;
  labelKey: string;
  status: TabStatus;
  /** 预留接口说明（scaffold/partial 用：数据从哪来/写回哪） */
  plannedInterface?: string;
}

export interface SettingsGroupDef {
  id: string;
  labelKey: string;
  tabs: SettingsTabDef[];
}

/** 11 个完整设置功能区（维度 A，用户所指 11 个功能区）——顺序按 SettingsPanel.tsx:388 */
export const SETTINGS_FULL_VIEW_TABS: string[] = [
  'general', 'models', 'providers', 'model-stats', 'bots',
  'subagents', 'network', 'permissions', 'sandbox', 'appearance', 'updates',
];

/** 8 组导航（维度 B）——tab 分布对齐 Reasonix */
export const SETTINGS_GROUPS: SettingsGroupDef[] = [
  {
    id: 'preferences',
    labelKey: 'settings.navGroup.preferences',
    tabs: [{ id: 'general', labelKey: 'settings.tab.general', status: 'done' }],
  },
  {
    id: 'models',
    labelKey: 'settings.navGroup.models',
    tabs: [
      { id: 'models', labelKey: 'settings.tab.models', status: 'partial',
        plannedInterface: 'genParams(temperature/topP/maxTokens) → step 请求；模型分配 defaultModel/plannerModel 待接' },
      { id: 'providers', labelKey: 'settings.tab.providers', status: 'done' },
      { id: 'model-stats', labelKey: 'settings.tab.modelStats', status: 'scaffold',
        plannedInterface: '用量统计：port 未来提供 modelStats()' },
    ],
  },
  {
    id: 'connections',
    labelKey: 'settings.navGroup.connections',
    tabs: [
      { id: 'bots', labelKey: 'settings.tab.bots', status: 'scaffold', plannedInterface: 'bot 配置待接' },
      { id: 'mcp', labelKey: 'settings.tab.mcp', status: 'scaffold', plannedInterface: 'MCP 服务注册待接' },
      { id: 'remote', labelKey: 'settings.tab.remote', status: 'scaffold', plannedInterface: '远程连接待接' },
    ],
  },
  {
    id: 'capabilities',
    labelKey: 'settings.navGroup.capabilities',
    tabs: [
      { id: 'skills', labelKey: 'settings.tab.skills', status: 'scaffold', plannedInterface: '技能启用待接' },
      { id: 'subagents', labelKey: 'settings.tab.subagents', status: 'scaffold', plannedInterface: '子代理模型/effort 待接' },
      { id: 'plugins', labelKey: 'settings.tab.plugins', status: 'scaffold', plannedInterface: '插件管理待接' },
    ],
  },
  {
    id: 'context',
    labelKey: 'settings.navGroup.context',
    tabs: [{ id: 'memory', labelKey: 'settings.tab.memory', status: 'scaffold', plannedInterface: '记忆/上下文策略待接' }],
  },
  {
    id: 'automation',
    labelKey: 'settings.navGroup.automation',
    tabs: [
      { id: 'hooks', labelKey: 'settings.tab.hooks', status: 'scaffold', plannedInterface: '钩子配置待接' },
      { id: 'diagnostics', labelKey: 'settings.tab.diagnostics', status: 'scaffold', plannedInterface: '诊断面板待接' },
    ],
  },
  {
    id: 'security',
    labelKey: 'settings.navGroup.security',
    tabs: [
      { id: 'permissions', labelKey: 'settings.tab.permissions', status: 'scaffold', plannedInterface: '权限全表待接' },
      { id: 'sandbox', labelKey: 'settings.tab.sandbox', status: 'scaffold', plannedInterface: '沙箱配置待接' },
      { id: 'network', labelKey: 'settings.tab.network', status: 'scaffold', plannedInterface: '网络/代理待接' },
      { id: 'browser', labelKey: 'settings.tab.browser', status: 'scaffold', plannedInterface: '浏览器控制待接' },
    ],
  },
  {
    id: 'application',
    labelKey: 'settings.navGroup.application',
    tabs: [
      { id: 'appearance', labelKey: 'settings.tab.appearance', status: 'done' },
      { id: 'shortcuts', labelKey: 'settings.tab.shortcuts', status: 'scaffold', plannedInterface: '快捷键映射待接' },
      { id: 'storage', labelKey: 'settings.tab.storage', status: 'scaffold', plannedInterface: '存储清理待接' },
      { id: 'updates', labelKey: 'settings.tab.updates', status: 'scaffold', plannedInterface: '更新检查待接' },
    ],
  },
];

/** 21 个 tab 全集（维度 C）。 */
export const ALL_SETTINGS_TABS: string[] = SETTINGS_GROUPS.flatMap(g => g.tabs.map(t => t.id));

export const DEFAULT_SETTINGS_TAB = 'general';

/** 模型生成参数（LLM 设置，「模型参数」预设；null = 内核默认）。 */
export interface ModelGenParams {
  temperature: number | null;
  topP: number | null;
  maxTokens: number | null;
}

export const DEFAULT_MODEL_PARAMS: ModelGenParams = { temperature: null, topP: null, maxTokens: null };

export function isParamDefault(p: ModelGenParams): boolean {
  return p.temperature === null && p.topP === null && p.maxTokens === null;
}

export function normalizeModelParams(raw: unknown): ModelGenParams {
  const o = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  return {
    temperature: typeof o.temperature === 'number' && o.temperature >= 0 && o.temperature <= 2 ? o.temperature : null,
    topP: typeof o.topP === 'number' && o.topP > 0 && o.topP <= 1 ? o.topP : null,
    maxTokens: typeof o.maxTokens === 'number' && o.maxTokens > 0 && o.maxTokens <= 1_000_000 ? Math.round(o.maxTokens) : null,
  };
}