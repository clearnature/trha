// 设置中心层级模型 —— 结构以用户提供的权威导航为准（2026-09-19）：
//   8 组 / 22 tab：
//   偏好设置: 通用, 模型
//   模型: 模型偏好, 模型服务, 用量统计
//   集成与连接: 机器人, MCP 与工具, 远程 SSH
//   能力扩展: Agent Skills, 子智能体, 插件
//   记忆与上下文: 记忆
//   自动化与开发者: Hooks, 诊断
//   安全与控制: 权限, 沙箱, 网络, 浏览器控制
//   应用: 外观, 快捷键, 存储与路径, 关于
// 语义参照 Reasonix：11 个需 SettingsView 的完整功能区 + capability 页自带数据。
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

/** 8 组导航（用户权威结构；对应 Reasonix SETTINGS_TAB_GROUPS）。 */
export const SETTINGS_GROUPS: SettingsGroupDef[] = [
  {
    id: 'preferences',
    labelKey: 'settings.navGroup.preferences',
    tabs: [
      { id: 'general', labelKey: 'settings.tab.general', status: 'done' },
      { id: 'models', labelKey: 'settings.tab.models', status: 'partial',
        plannedInterface: 'genParams(temperature/topP/maxTokens) → step 请求已接；模型分配 defaultModel/plannerModel 待接' },
    ],
  },
  {
    id: 'model',
    labelKey: 'settings.navGroup.model',
    tabs: [
      { id: 'model-preferences', labelKey: 'settings.tab.modelPreferences', status: 'scaffold',
        plannedInterface: '模型偏好（默认识别/生成参数）待接' },
      { id: 'providers', labelKey: 'settings.tab.providers', status: 'done' },
      { id: 'model-stats', labelKey: 'settings.tab.modelStats', status: 'scaffold',
        plannedInterface: '用量统计：port 未来提供 modelStats()' },
    ],
  },
  {
    id: 'connections',
    labelKey: 'settings.navGroup.connections',
    tabs: [
      { id: 'bots', labelKey: 'settings.tab.bots', status: 'scaffold', plannedInterface: '机器人接入待接' },
      { id: 'mcp', labelKey: 'settings.tab.mcp', status: 'scaffold', plannedInterface: 'MCP 与工具注册待接' },
      { id: 'remote', labelKey: 'settings.tab.remote', status: 'scaffold', plannedInterface: '远程 SSH 连接待接' },
    ],
  },
  {
    id: 'capabilities',
    labelKey: 'settings.navGroup.capabilities',
    tabs: [
      { id: 'skills', labelKey: 'settings.tab.skills', status: 'scaffold', plannedInterface: 'Agent Skills 待接' },
      { id: 'subagents', labelKey: 'settings.tab.subagents', status: 'scaffold', plannedInterface: '子智能体待接' },
      { id: 'plugins', labelKey: 'settings.tab.plugins', status: 'scaffold', plannedInterface: '插件管理待接' },
    ],
  },
  {
    id: 'context',
    labelKey: 'settings.navGroup.context',
    tabs: [{ id: 'memory', labelKey: 'settings.tab.memory', status: 'scaffold', plannedInterface: '记忆策略待接' }],
  },
  {
    id: 'automation',
    labelKey: 'settings.navGroup.automation',
    tabs: [
      { id: 'hooks', labelKey: 'settings.tab.hooks', status: 'scaffold', plannedInterface: 'Hooks 配置待接' },
      { id: 'diagnostics', labelKey: 'settings.tab.diagnostics', status: 'scaffold', plannedInterface: '诊断待接' },
    ],
  },
  {
    id: 'security',
    labelKey: 'settings.navGroup.security',
    tabs: [
      { id: 'permissions', labelKey: 'settings.tab.permissions', status: 'scaffold', plannedInterface: '权限待接' },
      { id: 'sandbox', labelKey: 'settings.tab.sandbox', status: 'scaffold', plannedInterface: '沙箱待接' },
      { id: 'network', labelKey: 'settings.tab.network', status: 'scaffold', plannedInterface: '网络待接' },
      { id: 'browser', labelKey: 'settings.tab.browser', status: 'scaffold', plannedInterface: '浏览器控制待接' },
    ],
  },
  {
    id: 'application',
    labelKey: 'settings.navGroup.application',
    tabs: [
      { id: 'appearance', labelKey: 'settings.tab.appearance', status: 'done' },
      { id: 'shortcuts', labelKey: 'settings.tab.shortcuts', status: 'scaffold', plannedInterface: '快捷键待接' },
      { id: 'storage', labelKey: 'settings.tab.storage', status: 'scaffold', plannedInterface: '存储与路径待接' },
      { id: 'about', labelKey: 'settings.tab.about', status: 'done' },
    ],
  },
];

/** 22 tab 全集。 */
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