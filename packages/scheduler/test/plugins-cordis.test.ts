// Cordis service/dispatch tests (deepseek-harness docs):
//   * service registry semantics (register / duplicate / missing)
//   * plugin `inject` dependency resolution and rejection
//   * ctx.waterfall ordering; ctx.bail short-circuit
//   * release handles unwind on unregister

import { describe, expect, it } from 'vitest';
import { PluginManager, PluginContext } from '../src/Plugins/Plugin.js';
import { ServiceRegistry } from '../src/Plugins/Registry.js';

const plugin = (name: string, extra: Partial<Parameters<PluginManager['register']>[0]> = {}) => ({
  name,
  version: '0.0.0',
  description: name,
  ...extra,
});

describe('ServiceRegistry', () => {
  it('registers, resolves and lists services by name', () => {
    const r = new ServiceRegistry();
    r.register('events', {});
    expect(r.has('events')).toBe(true);
    expect(r.get('events')).toEqual({});
    expect(r.names()).toEqual(['events']);
  });

  it('rejects duplicate registration', () => {
    const r = new ServiceRegistry();
    r.register('x', 1);
    expect(() => r.register('x', 2)).toThrow(/already registered/);
  });

  it('require throws for an unknown service', () => {
    const r = new ServiceRegistry();
    expect(() => r.require('nope')).toThrow(/not registered/);
  });
});

describe('PluginManager inject', () => {
  it('rejects a plugin whose inject dependency is missing', async () => {
    const m = new PluginManager();
    await expect(m.register(plugin('p', { inject: ['missing-service'] })))
      .rejects.toThrow(/injects missing service missing-service/);
  });

  it('resolves declared services through ctx.service', async () => {
    const m = new PluginManager();
    m.registerService('tools', { list: () => ['read_file'] });
    let got: unknown;
    await m.register(plugin('p', {
      inject: ['tools'],
      async activate(ctx: PluginContext) {
        got = ctx.service('tools');
      },
    }));
    expect(got).toEqual({ list: expect.any(Function) });
  });
});

describe('waterfall dispatch', () => {
  it('rewrites the value through listeners in order', async () => {
    const m = new PluginManager();
    await m.register(plugin('a', {
      activate: (ctx: PluginContext) => {
        ctx.waterfall('agent:tools', (v) => [...(v as string[]), 'a-tool']);
      },
    }));
    await m.register(plugin('b', {
      activate: (ctx: PluginContext) => {
        ctx.waterfall('agent:tools', (v) => [...(v as string[]), 'b-tool']);
      },
    }));
    const out = await m.runWaterfall('agent:tools', ['read_file']);
    expect(out).toEqual(['read_file', 'a-tool', 'b-tool']);
  });

  it('keeps the previous value when a listener returns undefined', async () => {
    const m = new PluginManager();
    await m.register(plugin('a', {
      activate: (ctx: PluginContext) => {
        ctx.waterfall('x', () => undefined);
      },
    }));
    expect(await m.runWaterfall('x', 'orig')).toBe('orig');
  });
});

describe('bail dispatch', () => {
  it('short-circuits on the first non-null listener result', async () => {
    const m = new PluginManager();
    await m.register(plugin('noop', {
      activate: (ctx: PluginContext) => {
        ctx.bail('agent:step:before', () => null);
      },
    }));
    await m.register(plugin('guard', {
      activate: (ctx: PluginContext) => {
        ctx.bail('agent:step:before', () => 'blocked by guard');
      },
    }));
    await m.register(plugin('later', {
      activate: (ctx: PluginContext) => {
        ctx.bail('agent:step:before', () => 'never reached');
      },
    }));
    expect(await m.runBail('agent:step:before', 'hello')).toBe('blocked by guard');
  });

  it('returns null when nobody bails', async () => {
    const m = new PluginManager();
    expect(await m.runBail('agent:step:before', 'hello')).toBeNull();
  });
});

describe('release semantics', () => {
  it('unwinds waterfall/bail listeners on unregister', async () => {
    const m = new PluginManager();
    await m.register(plugin('p', {
      activate: (ctx: PluginContext) => {
        ctx.waterfall('w', (v) => `${v}!`);
        ctx.bail('b', () => 'x');
      },
    }));
    expect(await m.runWaterfall('w', 'v')).toBe('v!');
    expect(await m.runBail('b', 'v')).toBe('x');
    await m.unregister('p');
    expect(await m.runWaterfall('w', 'v')).toBe('v');
    expect(await m.runBail('b', 'v')).toBeNull();
  });

  it('individually released handles stop firing', async () => {
    const m = new PluginManager();
    let release: (() => void) | undefined;
    await m.register(plugin('p', {
      activate: (ctx: PluginContext) => {
        release = ctx.waterfall('w', (v) => `${v}+`);
      },
    }));
    await m.runWaterfall('w', 'v');
    release?.();
    expect(await m.runWaterfall('w', 'v')).toBe('v');
  });
});
describe('parallel / serial dispatch', () => {
  it('parallel fans out to every listener and collects results', async () => {
    const m = new PluginManager();
    await m.register(plugin('a', {
      activate: (ctx: PluginContext) => {
        ctx.parallel('fan', (v) => `${v}-a`);
      },
    }));
    await m.register(plugin('b', {
      activate: (ctx: PluginContext) => {
        ctx.parallel('fan', (v) => `${v}-b`);
      },
    }));
    const results = await m.runParallel('fan', 'x');
    expect(results.sort()).toEqual(['x-a', 'x-b']);
  });

  it('serial awaits listeners in registration order', async () => {
    const m = new PluginManager();
    const order: string[] = [];
    await m.register(plugin('first', {
      activate: (ctx: PluginContext) => {
        ctx.serial('seq', async () => {
          await new Promise(r => setTimeout(r, 5));
          order.push('first');
        });
      },
    }));
    await m.register(plugin('second', {
      activate: (ctx: PluginContext) => {
        ctx.serial('seq', async () => {
          order.push('second');
        });
      },
    }));
    await m.runSerial('seq', 'v');
    expect(order).toEqual(['first', 'second']);
  });
});
describe('capability surface', () => {
  it('describes registered services with their capabilities', () => {
    const m = new PluginManager();
    m.registerService('events', {}, ['events:listen', 'events:emit']);
    m.registerService('bridge', {}, []);
    const info = m.describeServices();
    expect(info.find(x => x.name === 'events')?.capabilities).toEqual(['events:listen', 'events:emit']);
    expect(info.find(x => x.name === 'bridge')?.capabilities).toEqual([]);
    expect(info.map(x => x.name).sort()).toEqual(['bridge', 'events']);
  });
});

describe('DSH-style inject (services as properties)', () => {
  it('mounts injected services on ctx so ctx.<name> works in apply()', async () => {
    const manager = new PluginManager();
    const dir = { ensure: () => '/tmp/x', set: (_a: string) => '/tmp/x' };
    manager.registerService('workingDirectory', dir);
    let seen: unknown;
    await manager.register({
      name: 'dsh-tool-demo',
      inject: ['workingDirectory'],
      apply(ctx) {
        seen = (ctx as unknown as Record<string, unknown>).workingDirectory;
      },
    });
    expect(seen).toBe(dir);
  });
});
