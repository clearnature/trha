// Plugin system for trha scheduler

export interface Plugin {
  name: string;
  version: string;
  description: string;

  // Lifecycle hooks
  onInit?: () => Promise<void>;
  onDestroy?: () => Promise<void>;

  // Event hooks
  onSessionCreate?: (sessionId: string) => Promise<void>;
  onSessionDelete?: (sessionId: string) => Promise<void>;
  onMessageSend?: (sessionId: string, message: unknown) => Promise<void>;
  onToolCall?: (sessionId: string, tool: string, args: unknown) => Promise<void>;
}

export class PluginManager {
  private plugins: Map<string, Plugin> = new Map();

  async register(plugin: Plugin): Promise<void> {
    if (this.plugins.has(plugin.name)) {
      throw new Error(`Plugin ${plugin.name} is already registered`);
    }

    if (plugin.onInit) {
      await plugin.onInit();
    }

    this.plugins.set(plugin.name, plugin);
  }

  async unregister(name: string): Promise<void> {
    const plugin = this.plugins.get(name);
    if (!plugin) {
      throw new Error(`Plugin ${name} is not registered`);
    }

    if (plugin.onDestroy) {
      await plugin.onDestroy();
    }

    this.plugins.delete(name);
  }

  getPlugin(name: string): Plugin | undefined {
    return this.plugins.get(name);
  }

  listPlugins(): Plugin[] {
    return Array.from(this.plugins.values());
  }

  async emitSessionCreate(sessionId: string): Promise<void> {
    for (const plugin of this.plugins.values()) {
      if (plugin.onSessionCreate) {
        await plugin.onSessionCreate(sessionId);
      }
    }
  }

  async emitSessionDelete(sessionId: string): Promise<void> {
    for (const plugin of this.plugins.values()) {
      if (plugin.onSessionDelete) {
        await plugin.onSessionDelete(sessionId);
      }
    }
  }

  async emitMessageSend(sessionId: string, message: unknown): Promise<void> {
    for (const plugin of this.plugins.values()) {
      if (plugin.onMessageSend) {
        await plugin.onMessageSend(sessionId, message);
      }
    }
  }

  async emitToolCall(sessionId: string, tool: string, args: unknown): Promise<void> {
    for (const plugin of this.plugins.values()) {
      if (plugin.onToolCall) {
        await plugin.onToolCall(sessionId, tool, args);
      }
    }
  }
}