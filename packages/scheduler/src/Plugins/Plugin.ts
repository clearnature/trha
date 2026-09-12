// Plugin system for trha scheduler
//
// Cordis-style (deepseek-harness) plugin lifecycle: a plugin may declare
// `activate(ctx)` returning a release handle via `ctx.on`, and `deactivate`
// to undo everything.  The legacy optional event hooks below remain
// supported and are driven by the server runtime.
//
// Extension (deepseek-harness docs, cordis-api/registry + events):
//   * `inject: [names]` — declared service dependencies; registration is
//     rejected when a dependency is not registered yet.
//   * `ctx.service(name)` — resolve an injected service by key.
//   * `ctx.waterfall(name, fn)` / `ctx.bail(name, fn)` — dispatch-mode
//     listeners with release handles (unwound on unregister, like `on`).

import { ServiceRegistry } from './Registry.js';

/** Release handle returned by ctx.* subscriptions. */
export type Release = () => void;

/** Waterfall listener: rewrites the value flowing through the chain. */
export type WaterfallHandler = (value: unknown) => unknown | Promise<unknown>;

/** Bail listener: returning a non-null value short-circuits the chain. */
export type BailHandler = (value: unknown) => unknown | null | undefined | Promise<unknown | null | undefined>;

/** Parallel listener: each handler runs concurrently on the same value. */
export type ParallelHandler = (value: unknown) => unknown | Promise<unknown>;

/** Serial listener: handlers await each other in registration order. */
export type SerialHandler = (value: unknown) => unknown | Promise<unknown>;

/**
 * Context handed to `activate`.  `on` subscribes to a server event
 * (event names follow the Server EventEmitter, e.g. 'session:created',
 * 'agent:message', 'tool:update'); the returned release is tracked by the
 * manager and invoked on `unregister` (before `deactivate`).
 */
export interface PluginContext {
  name: string;
  on(event: string, handler: (data: unknown) => void): Release;
  waterfall(event: string, handler: WaterfallHandler): Release;
  bail(event: string, handler: BailHandler): Release;
  /** Fan-out listener: handlers run concurrently for one event value. */
  parallel(event: string, handler: ParallelHandler): Release;
  /** Ordered listener: handlers await each other in registration order. */
  serial(event: string, handler: SerialHandler): Release;
  /** Resolve a service declared in `inject` (throws when missing). */
  service(name: string): unknown;
}

/** Minimal event bus shape used by the plugin manager. */
export interface EventBus {
  on(event: string, handler: (data: unknown) => void): void;
  off(event: string, handler: (data: unknown) => void): void;
}

export interface Plugin {
  name: string;
  version: string;
  description: string;

  /** Declared service dependencies (must all be registered beforehand). */
  inject?: string[];

  // Cordis-style lifecycle (Phase 3 C1)
  activate?(ctx: PluginContext): void | Promise<void>;
  deactivate?(): void | Promise<void>;

  // Legacy lifecycle hooks
  onInit?: () => Promise<void>;
  onDestroy?: () => Promise<void>;

  // Legacy event hooks
  onSessionCreate?: (sessionId: string) => Promise<void>;
  onSessionDelete?: (sessionId: string) => Promise<void>;
  onMessageSend?: (sessionId: string, message: unknown) => Promise<void>;
  onToolCall?: (sessionId: string, tool: string, args: unknown) => Promise<void>;
}

export class PluginManager {
  private plugins: Map<string, Plugin> = new Map();
  private releases: Map<string, Release[]> = new Map();
  private waterfalls: Map<string, WaterfallHandler[]> = new Map();
  private bails: Map<string, BailHandler[]> = new Map();
  private parallels: Map<string, ParallelHandler[]> = new Map();
  private serials: Map<string, SerialHandler[]> = new Map();
  private readonly services;

  constructor(private readonly bus?: EventBus, services?: ServiceRegistry) {
    this.services = services ?? new ServiceRegistry();
  }

  registerService(name: string, service: unknown, capabilities: string[] = []): void {
    this.services.register(name, service, capabilities);
  }

  service(name: string): unknown {
    return this.services.require(name);
  }

  /** Declared service surface ({ name, capabilities } for each service). */
  describeServices(): { name: string; capabilities: string[] }[] {
    return this.services.describe();
  }

  async register(plugin: Plugin): Promise<void> {
    if (this.plugins.has(plugin.name)) {
      throw new Error(`Plugin ${plugin.name} is already registered`);
    }

    for (const dep of plugin.inject ?? []) {
      if (!this.services.has(dep)) {
        throw new Error(`Plugin ${plugin.name} injects missing service ${dep}`);
      }
    }

    if (plugin.onInit) {
      await plugin.onInit();
    }

    const active: Release[] = [];
    const ctx: PluginContext = {
      name: plugin.name,
      on: (event, handler) => {
        const off: Release = () => this.bus?.off(event, handler as never);
        this.bus?.on(event, handler as never);
        active.push(off);
        return off;
      },
      waterfall: (event, handler) => {
        const list = this.waterfalls.get(event) ?? [];
        list.push(handler);
        this.waterfalls.set(event, list);
        const off: Release = () => {
          this.waterfalls.set(event, (this.waterfalls.get(event) ?? []).filter(h => h !== handler));
        };
        active.push(off);
        return off;
      },
      bail: (event, handler) => {
        const list = this.bails.get(event) ?? [];
        list.push(handler);
        this.bails.set(event, list);
        const off: Release = () => {
          this.bails.set(event, (this.bails.get(event) ?? []).filter(h => h !== handler));
        };
        active.push(off);
        return off;
      },
      parallel: (event, handler) => {
        const list = this.parallels.get(event) ?? [];
        list.push(handler);
        this.parallels.set(event, list);
        const off: Release = () => {
          this.parallels.set(event, (this.parallels.get(event) ?? []).filter(h => h !== handler));
        };
        active.push(off);
        return off;
      },
      serial: (event, handler) => {
        const list = this.serials.get(event) ?? [];
        list.push(handler);
        this.serials.set(event, list);
        const off: Release = () => {
          this.serials.set(event, (this.serials.get(event) ?? []).filter(h => h !== handler));
        };
        active.push(off);
        return off;
      },
      service: (name) => this.services.require(name),
    };
    if (plugin.activate) {
      await plugin.activate(ctx);
    }

    this.plugins.set(plugin.name, plugin);
    this.releases.set(plugin.name, active);
  }

  /** Run a waterfall: each registered listener rewrites the value in order. */
  async runWaterfall(event: string, value: unknown): Promise<unknown> {
    let current = value;
    for (const handler of this.waterfalls.get(event) ?? []) {
      const next = await handler(current);
      if (next !== undefined) {
        current = next;
      }
    }
    return current;
  }

  /** Run parallel: every listener runs concurrently on the same value. */
  async runParallel(event: string, value: unknown): Promise<unknown[]> {
    return Promise.all((this.parallels.get(event) ?? []).map(h => h(value)));
  }

  /** Run serial: listeners await each other in registration order. */
  async runSerial(event: string, value: unknown): Promise<void> {
    for (const handler of this.serials.get(event) ?? []) {
      await handler(value);
    }
  }

  /** Run a bail: first non-null/non-undefined listener result wins. */
  async runBail(event: string, value: unknown): Promise<unknown | null> {
    for (const handler of this.bails.get(event) ?? []) {
      const result = await handler(value);
      if (result !== undefined && result !== null) {
        return result;
      }
    }
    return null;
  }

  async unregister(name: string): Promise<void> {
    const plugin = this.plugins.get(name);
    if (!plugin) {
      throw new Error(`Plugin ${name} is not registered`);
    }

    // 1. release ctx.on/waterfall/bail subscriptions (reversible effects)
    for (const off of this.releases.get(name) ?? []) {
      off();
    }
    this.releases.delete(name);

    // 2. plugin-level teardown
    if (plugin.deactivate) {
      await plugin.deactivate();
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
