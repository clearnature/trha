// Transport Layer for Subagent Communication - Phase 6

import { ProtocolHandler, Message } from './Protocol.js';
import { createLogger } from '../../Core/Logger.js';

export interface TransportConfig {
  host: string;
  port: number;
  protocol: 'http' | 'https';
}

export class Transport {
  private protocolHandler: ProtocolHandler;
  private logger = createLogger('info', 'Transport');
  private config: TransportConfig;
  private connections: Map<string, { host: string; port: number }> = new Map();

  constructor(config: TransportConfig) {
    this.config = config;
    this.protocolHandler = new ProtocolHandler();
  }

  // Register a handler for incoming messages
  registerHandler(method: string, handler: (message: any) => Promise<unknown>): void {
    this.protocolHandler.registerHandler(method, handler);
  }

  // Send a message to a subagent
  async sendMessage(message: Message): Promise<unknown> {
    const connection = this.connections.get(message.to);
    if (!connection) {
      throw new Error(`No connection to subagent ${message.to}`);
    }

    const url = `${this.config.protocol}://${connection.host}:${connection.port}/message`;

    this.logger.debug(`Sending message to ${message.to}: ${url}`);

    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(message),
      });

      if (!response.ok) {
        throw new Error(`HTTP error: ${response.status}`);
      }

      return response.json();
    } catch (error) {
      this.logger.error(`Failed to send message to ${message.to}: ${error}`);
      throw error;
    }
  }

  // Register a subagent connection
  registerConnection(subagentId: string, host: string, port: number): void {
    this.connections.set(subagentId, { host, port });
    this.logger.info(`Registered connection for subagent ${subagentId} at ${host}:${port}`);
  }

  // Unregister a subagent connection
  unregisterConnection(subagentId: string): void {
    this.connections.delete(subagentId);
    this.logger.info(`Unregistered connection for subagent ${subagentId}`);
  }

  // Start listening for incoming messages
  async start(): Promise<void> {
    this.logger.info(`Transport started on ${this.config.host}:${this.config.port}`);
    // In real implementation, start HTTP server here
  }

  // Stop listening
  async stop(): Promise<void> {
    this.logger.info('Transport stopped');
    // In real implementation, stop HTTP server here
  }

  // Get protocol handler
  getProtocolHandler(): ProtocolHandler {
    return this.protocolHandler;
  }
}