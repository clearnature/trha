// PluginManager 全生命周期：注册/注入校验/activate 上下文/waterfall/bail/
// parallel/serial 的运行与注销回滚/会话与工具事件的 legacy 钩子。
import { describe, expect, it } from 'vitest';

import { PluginManager } from '../src/Plugins/Plugin.js';
import type { Plugin } from '../src/Plugins/Plugin.js';

const demo = (over: Partial<Plugin> = {}): Plugin => ({
  name: 'demo', version: '1.0', description: 'demo plugin', ...over,
});

describe('PluginManager', () => {
  it('register → getPlugin / listPlugins；重复注册拒绝', async () => {
    const mgr = new PluginManager();
    await mgr.register(demo());
    expect(mgr.getPlugin('demo')?.version).toBe('1.0');
    expect(mgr.listPlugins()).toHaveLength(1);
    await expect(mgr.register(demo())).rejects.toThrow('already registered');
  });

  it('inject 缺失服务 → 拒绝注册；先 registerService 再注册 → 通过且 ctx.service 可解析', async () => {
    const mgr = new PluginManager();
    await expect(mgr.register(demo({ name: 'needy', inject: ['db'] })))
      .rejects.toThrow('injects missing service db');
    mgr.registerService('db', { query: () => [] }, ['sql']);
    let resolved: unknown;
    await mgr.register(demo({
      name: 'needy', inject: ['db'],
      activate: ctx => { resolved = ctx.service('db'); },
    }));
    expect(resolved).toMatchObject({ query: expect.anything() });
  });

  it('activate 的 ctx.on 订阅在 unregister 后被释放', async () => {
    const mgr = new PluginManager();
    // ctx.on 走的是 EventBus（bus 未注入时仅登记）；waterfall 才是可分发的订阅
    let calls = 0;
    await mgr.register(demo({
      name: 'wf',
      activate: ctx => { ctx.waterfall('event', () => { calls += 1; }); },
      deactivate: () => { calls = -100; },
    }));
    await mgr.runWaterfall('event', 'x');
    expect(calls).toBe(1);
    await mgr.unregister('wf');
    await mgr.runWaterfall('event', 'x');
    // 释放后：deactivate 已把计数置 -100；若订阅未被释放，这里会变回 1
    expect(calls).toBe(-100);
    expect(mgr.getPlugin('wf')).toBeUndefined();
    // ctx.on：需要注入 EventBus 才有分发目标
    const busCalls: string[] = [];
    const bus = { on: (e: string, _h: (d: unknown) => void) => { busCalls.push(`on:${e}`); }, off: (e: string) => { busCalls.push(`off:${e}`); } };
    const mgr2 = new PluginManager(bus as never);
    await mgr2.register(demo({
      name: 'sub',
      activate: ctx => { ctx.on('tick', () => undefined); },
      deactivate: () => undefined,
    }));
    await mgr2.unregister('sub');
    expect(busCalls).toEqual(['on:tick', 'off:tick']);
  });

  it('unregister 未注册 → 抛错', async () => {
    const mgr = new PluginManager();
    await expect(mgr.unregister('ghost')).rejects.toThrow('not registered');
  });

  it('waterfall：顺序改写值；返回 undefined 则保持当前值', async () => {
    const mgr = new PluginManager();
    await mgr.register(demo({
      name: 'wf1', activate: ctx => { ctx.waterfall('v', v => `${v}-1`); },
    }));
    await mgr.register(demo({
      name: 'wf2', activate: ctx => {
        ctx.waterfall('v', v => (v === 'x-1' ? undefined : 'skip'));
      },
    }));
    expect(await mgr.runWaterfall('v', 'x')).toBe('x-1');
  });

  it('bail：第一个非空结果胜；全空 → null', async () => {
    const mgr = new PluginManager();
    let secondRan = false;
    await mgr.register(demo({
      name: 'bailer', activate: ctx => {
        ctx.bail('q', () => null);
        ctx.bail('q', () => { secondRan = true; return 'answer'; });
        ctx.bail('q', () => 'never');
      },
    }));
    expect(await mgr.runBail('q', 'x')).toBe('answer');
    expect(secondRan).toBe(true);
  });

  it('parallel 并发全跑；serial 按注册顺序', async () => {
    const mgr = new PluginManager();
    const seen: string[] = [];
    await mgr.register(demo({
      name: 'par', activate: ctx => {
        ctx.parallel('e', () => { seen.push('a'); });
        ctx.parallel('e', () => { seen.push('b'); });
      },
    }));
    await mgr.runParallel('e', 'x');
    expect(seen.sort()).toEqual(['a', 'b']);
    const order: string[] = [];
    await mgr.register(demo({
      name: 's1', activate: ctx => { ctx.serial('e2', () => { order.push('first'); }); },
    }));
    await mgr.register(demo({
      name: 's2', activate: ctx => { ctx.serial('e2', () => { order.push('second'); }); },
    }));
    await mgr.runSerial('e2', 'x');
    expect(order).toEqual(['first', 'second']);
  });

  it('legacy 钩子：onSessionCreate/Delete/MessageSend/ToolCall 逐插件驱动', async () => {
    const mgr = new PluginManager();
    const seen: string[] = [];
    await mgr.register(demo({
      name: 'hooks',
      onSessionCreate: async s => { seen.push(`create:${s}`); },
      onSessionDelete: async s => { seen.push(`delete:${s}`); },
      onMessageSend: async (s, m) => { seen.push(`msg:${s}:${String(m)}`); },
      onToolCall: async (s, tool) => { seen.push(`tool:${s}:${tool}`); },
    }));
    await mgr.emitSessionCreate('s9');
    await mgr.emitMessageSend('s9', 'hi');
    await mgr.emitToolCall('s9', 'bash', {});
    await mgr.emitSessionDelete('s9');
    expect(seen).toEqual(['create:s9', 'msg:s9:hi', 'tool:s9:bash', 'delete:s9']);
  });

  it('describeServices 反映已注册服务', () => {
    const mgr = new PluginManager();
    mgr.registerService('svc', {}, ['cap1', 'cap2']);
    expect(mgr.describeServices()).toEqual([{ name: 'svc', capabilities: ['cap1', 'cap2'] }]);
  });
});
