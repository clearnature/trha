// Shared types between main and renderer

export interface Session {
  id: string;
  title: string;
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
  schema: unknown;
}

export interface AgentState {
  status: 'idle' | 'processing' | 'waiting' | 'completed' | 'error';
  message?: string;
}

// Electron API injected by preload
export interface ElectronAPI {
  getToken: () => Promise<string>;
  getSchedulerPort: () => Promise<number>;
  getAppVersion: () => Promise<string>;
  platform: string;
}

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}
