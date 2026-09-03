// Session Management for Subagents - Phase 6

export interface Session {
  id: string;
  subagentId: string;
  parentSessionId: string;
  status: 'active' | 'completed' | 'failed' | 'terminated';
  startTime: Date;
  endTime?: Date;
  messages: SessionMessage[];
  metadata: Record<string, unknown>;
}

export interface SessionMessage {
  id: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  timestamp: Date;
  metadata?: Record<string, unknown>;
}

export class SessionManager {
  private sessions: Map<string, Session> = new Map();

  // Create a new session
  async createSession(subagentId: string, parentSessionId: string): Promise<Session> {
    const sessionId = `session-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

    const session: Session = {
      id: sessionId,
      subagentId,
      parentSessionId,
      status: 'active',
      startTime: new Date(),
      messages: [],
      metadata: {},
    };

    this.sessions.set(sessionId, session);
    return session;
  }

  // Get a session by ID
  async getSession(sessionId: string): Promise<Session | undefined> {
    return this.sessions.get(sessionId);
  }

  // List all sessions for a subagent
  async listSessions(subagentId: string): Promise<Session[]> {
    return Array.from(this.sessions.values()).filter((s) => s.subagentId === subagentId);
  }

  // Add a message to a session
  async addMessage(sessionId: string, role: SessionMessage['role'], content: string, metadata?: Record<string, unknown>): Promise<SessionMessage> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} not found`);
    }

    const message: SessionMessage = {
      id: `msg-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      role,
      content,
      timestamp: new Date(),
      metadata,
    };

    session.messages.push(message);
    return message;
  }

  // Complete a session
  async completeSession(sessionId: string, status: 'completed' | 'failed' | 'terminated'): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} not found`);
    }

    session.status = status;
    session.endTime = new Date();
  }

  // Get session messages
  async getMessages(sessionId: string): Promise<SessionMessage[]> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} not found`);
    }

    return session.messages;
  }

  // Update session metadata
  async updateMetadata(sessionId: string, metadata: Record<string, unknown>): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} not found`);
    }

    session.metadata = { ...session.metadata, ...metadata };
  }

  // Get session summary
  async getSessionSummary(sessionId: string): Promise<{
    id: string;
    subagentId: string;
    parentSessionId: string;
    status: string;
    messageCount: number;
    duration?: number;
  }> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} not found`);
    }

    const duration = session.endTime
      ? session.endTime.getTime() - session.startTime.getTime()
      : undefined;

    return {
      id: session.id,
      subagentId: session.subagentId,
      parentSessionId: session.parentSessionId,
      status: session.status,
      messageCount: session.messages.length,
      duration,
    };
  }

  // Get all sessions summary
  async getAllSessionsSummary(): Promise<Array<{
    id: string;
    subagentId: string;
    parentSessionId: string;
    status: string;
    messageCount: number;
    duration?: number;
  }>> {
    const sessions = Array.from(this.sessions.values());

    return sessions.map((session) => {
      const duration = session.endTime
        ? session.endTime.getTime() - session.startTime.getTime()
        : undefined;

      return {
        id: session.id,
        subagentId: session.subagentId,
        parentSessionId: session.parentSessionId,
        status: session.status,
        messageCount: session.messages.length,
        duration,
      };
    });
  }
}