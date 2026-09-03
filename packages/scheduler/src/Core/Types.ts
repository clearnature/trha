// Core types for the scheduler

// Session types
export type SessionId = string;
export type AgentId = string;
export type ToolName = string;

// Message types
export interface Message {
  role: 'user' | 'assistant' | 'system';
  content: string;
}

// Session event types
export type SessionEvent =
  | { type: 'user_message'; content: string }
  | { type: 'assistant_message'; content: string }
  | { type: 'tool_call'; tool: ToolName; args: unknown }
  | { type: 'tool_result'; tool: ToolName; result: unknown }
  | { type: 'system_event'; content: string };

// Agent state types
export type AgentState =
  | { status: 'idle' }
  | { status: 'processing'; stepId: string }
  | { status: 'waiting_for_tool'; callId: string }
  | { status: 'completed'; result: string }
  | { status: 'error'; error: string };

// Tool types
export interface Tool {
  name: ToolName;
  description: string;
  schema: unknown;
}

// Model types
export interface ModelInfo {
  name: string;
  description: string;
  contextSize: number;
}

// Usage types
export interface Usage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
}

// Stream chunk types
export type StreamChunk =
  | { type: 'delta'; content: string }
  | { type: 'tool_call'; tool: ToolName; args: string[] }
  | { type: 'done'; usage: Usage };

// Configuration types
export interface SchedulerConfig {
  host: string;
  port: number;
  apiKey?: string;
  timeout: number;
  retries: number;
  maxConcurrency: number;
}

// Default configuration
export const defaultConfig: SchedulerConfig = {
  host: 'localhost',
  port: 3000,
  timeout: 30000,
  retries: 3,
  maxConcurrency: 10,
};

// Error types
export type SchedulerError =
  | { type: 'connection'; message: string }
  | { type: 'authentication'; message: string }
  | { type: 'validation'; message: string }
  | { type: 'server'; message: string }
  | { type: 'timeout' }
  | { type: 'unknown'; message: string };