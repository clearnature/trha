// Communication Protocol for Subagents - Phase 6

export interface BaseMessage {
  id: string;
  type: 'request' | 'response' | 'event' | 'error';
  from: string;
  to: string;
  timestamp: Date;
}

export interface RequestMessage extends BaseMessage {
  type: 'request';
  method: string;
  params: unknown;
}

export interface ResponseMessage extends BaseMessage {
  type: 'response';
  requestId: string;
  result?: unknown;
  error?: string;
}

export interface EventMessage extends BaseMessage {
  type: 'event';
  event: string;
  data: unknown;
}

export interface ErrorMessage extends BaseMessage {
  type: 'error';
  error: string;
  details?: unknown;
}

export type Message = RequestMessage | ResponseMessage | EventMessage | ErrorMessage;

// Protocol Handler
export class ProtocolHandler {
  private handlers: Map<string, (message: Message) => Promise<unknown>> = new Map();

  // Register a handler for a method
  registerHandler(method: string, handler: (message: Message) => Promise<unknown>): void {
    this.handlers.set(method, handler);
  }

  // Handle an incoming message
  async handleMessage(message: Message): Promise<unknown> {
    switch (message.type) {
      case 'request':
        return this.handleRequest(message as RequestMessage);
      case 'response':
        return this.handleResponse(message as ResponseMessage);
      case 'event':
        return this.handleEvent(message as EventMessage);
      case 'error':
        return this.handleError(message as ErrorMessage);
      default:
        throw new Error(`Unknown message type: ${(message as any).type}`);
    }
  }

  private async handleRequest(message: RequestMessage): Promise<unknown> {
    const handler = this.handlers.get(message.method);
    if (!handler) {
      throw new Error(`No handler for method: ${message.method}`);
    }

    return handler(message);
  }

  private async handleResponse(message: ResponseMessage): Promise<unknown> {
    // Handle response - typically used for tracking request/response pairs
    return message.result;
  }

  private async handleEvent(message: EventMessage): Promise<unknown> {
    // Handle events - can be extended for event-driven communication
    return message.data;
  }

  private async handleError(message: ErrorMessage): Promise<unknown> {
    // Handle errors
    throw new Error(message.error);
  }

  // Create a request message
  createRequest(from: string, to: string, method: string, params: unknown): RequestMessage {
    return {
      id: `msg-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      type: 'request',
      from,
      to,
      method,
      params,
      timestamp: new Date(),
    };
  }

  // Create a response message
  createResponse(from: string, to: string, requestId: string, result?: unknown, error?: string): ResponseMessage {
    return {
      id: `msg-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      type: 'response',
      from,
      to,
      requestId,
      result,
      error,
      timestamp: new Date(),
    };
  }

  // Create an event message
  createEvent(from: string, to: string, event: string, data: unknown): EventMessage {
    return {
      id: `msg-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      type: 'event',
      from,
      to,
      event,
      data,
      timestamp: new Date(),
    };
  }

  // Create an error message
  createError(from: string, to: string, error: string, details?: unknown): ErrorMessage {
    return {
      id: `msg-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      type: 'error',
      from,
      to,
      error,
      details,
      timestamp: new Date(),
    };
  }
}