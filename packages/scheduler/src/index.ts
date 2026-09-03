// Main entry point for gh-harness scheduler - Phase 6

export * from './Core/Client.js';
export * from './Core/HTTP.js';
export * from './Core/Logger.js';
export * from './Core/Retry.js';

export * from './Plugins/Plugin.js';

export * from './Parallel/Scheduler.js';

export * from './Subagent/index.js';

export * from './Bridge/Haskell.js';

export * from './Utils/EventEmitter.js';
export * from './Utils/Queue.js';

// Re-export types from Core/Types with explicit names to avoid conflicts
export type {
  SessionId,
  AgentId,
  ToolName,
  SessionEvent,
  AgentState,
  Tool,
  ModelInfo,
  Usage,
  StreamChunk,
  SchedulerConfig,
  SchedulerError,
} from './Core/Types.js';

export { defaultConfig } from './Core/Types.js';

// Re-export Message type from Subagent
export type { Message as SubagentMessage } from './Subagent/Communication/Protocol.js';