// Types shared with Desktop (same as packages/app/Desktop/src/shared/types.ts)

export interface Session {
  id: string;
  title: string;
  mode: string;
  messages: Message[];
  createdAt: Date;
}

export interface Message {
  role: 'user' | 'assistant' | 'system';
  content: string;
}

export interface Model {
  name: string;
  description: string;
  contextSize: number;
}

export interface Tool {
  name: string;
  description: string;
  schema: Record<string, string>;
}

export interface AgentState {
  status: 'idle' | 'processing' | 'waiting' | 'completed' | 'error';
  message?: string;
}

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
