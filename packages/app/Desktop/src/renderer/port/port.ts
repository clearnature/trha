// Port surface: the ONLY backend entry point the UI may use (Reasonix
// frontend-next model).  Implementations: sse/http (real), mock (tests).
// UI code must not fetch directly; everything goes through a Port.
import type {
  DecisionResult,
  PlanAwaiting,
  PortEvent,
  PortModeConfig,
  PortModel,
  PortSession,
  PortSessionMessage,
  PortToolSpec,
  StepResult,
  StudioVersion,
} from './types.js';
import type { Protocol, ProviderCheck, ProviderDraft, ProviderEdit, ProviderEntry, ProviderProbe } from './provider.js';

export interface Port {
  modes(): Promise<Record<string, PortModeConfig>>;
  models(): Promise<PortModel[]>;
  tools(mode?: string): Promise<PortToolSpec[]>;
  listSessions(): Promise<PortSession[]>;
  getSession(id: string): Promise<PortSession>;
  sessionMessages(id: string): Promise<PortSessionMessage[]>;
  createSession(mode: string): Promise<{ sessionId: string; mode: string }>;
  deleteSession(id: string): Promise<void>;
  /** Run one agent step.  With requireApproval the scheduler answers
   *  PlanAwaiting and the host decides via decision(). */
  step(
    sessionId: string,
    message: string,
    requireApproval?: boolean,
    target?: StepTarget,
  ): Promise<StepResult | PlanAwaiting>;
  decision(sessionId: string, approve: boolean): Promise<DecisionResult>;
  /** Subscribe to the session event stream; returns an unsubscribe fn. */
  subscribe(sessionId: string, onEvent: (e: PortEvent) => void): () => void;
  studioVersion(): Promise<StudioVersion>;

  // Provider registry (P5). The kernel owns it; the scheduler forwards.
  providerEntries(): Promise<ProviderEntry[]>;
  protocols(): Promise<Protocol[]>;
  probeProvider(baseUrl: string, apiKey: string): Promise<ProviderProbe>;
  saveProvider(draft: ProviderDraft): Promise<ProviderEntry[]>;
  editProvider(edit: ProviderEdit): Promise<ProviderEntry[]>;
  setWebSearch(name: string, on: boolean): Promise<ProviderEntry[]>;
  setThinking(name: string, on: boolean): Promise<ProviderEntry[]>;
  checkProvider(name: string): Promise<ProviderCheck>;
  removeProvider(name: string): Promise<ProviderEntry[]>;

  // 权限规则引擎（deny>ask>allow，同步到内核 executor 前置判定）
  permissionRules(): Promise<PermissionRuleEntry[]>;
  setPermissions(rules: PermissionRuleEntry[]): Promise<PermissionRuleEntry[]>;

  // 沙箱额外可信写目录（SandboxPanel 同步）
  writeRoots(): Promise<string[]>;
  setWriteRoots(roots: string[]): Promise<string[]>;

  // 用量统计（UsageStatsPanel；scheduler 聚合 sessions）
  usageStats(): Promise<UsageRow[]>;

  // Hooks 配置（HooksPanel 保存/加载，落盘 ~/.trha/hooks.json）
  hooksConfig(): Promise<{ config: string; path: string }>;
  saveHooksConfig(config: string): Promise<{ config: string; path: string }>;

  // 插件列表（PluginsPanel；scheduler 插件注册系统）
  plugins(): Promise<PluginEntry[]>;

  // 记忆（MemoryPanel；scheduler 落盘 + 分类）
  memories(): Promise<{ items: MemoryEntry[]; stats: { background: number; archived: number; instructionFiles: number } }>;
  saveMemories(items: MemoryEntry[]): Promise<{ items: MemoryEntry[]; stats: { background: number; archived: number; instructionFiles: number } }>;
}

/** 内核权限规则（对齐 scheduler PermissionRule）。 */
export type PermissionRuleEntry = { kind: 'deny' | 'ask' | 'allow'; pattern: string };
/** 用量统计行（按 mode 聚合）。 */
export type UsageRow = { model: string; requests: number; messages: number; tokens: number; cost: string };
/** 插件条目（scheduler listPlugins）。 */
export type PluginEntry = { name: string; version: string; description: string };
/** 记忆条目。 */
export type MemoryEntry = {
  id: string; title: string; slug: string; category: 'feedback' | 'project' | 'preferences';
  excerpt: string; archived?: boolean;
};

export type { PortEvent, PortSession, PortSessionMessage, PortToolSpec, StepResult };
export type { Protocol, ProviderCheck, ProviderDraft, ProviderEdit, ProviderEntry, ProviderProbe } from './provider.js';

/** Which saved provider/model should answer a step (P6). */
export type StepTarget = {
  provider?: string | undefined;
  model?: string | undefined;
  /** 模型生成参数（LLM 设置；省略 = 内核默认）。 */
  genParams?: { temperature?: number | undefined; topP?: number | undefined; maxTokens?: number | undefined };
};

