// Port-level behaviour of the provider registry (P8): the mock implements the
// same semantics the kernel does, so UI code can be developed offline.

import { describe, it, expect } from 'vitest';
import { MockPort } from '../src/renderer/port/mock.js';

describe('MockPort provider registry', () => {
  it('saves, edits (keeping what the edit omits), toggles and removes', async () => {
    const port = new MockPort();

    const saved = await port.saveProvider({
      name: 'gw', kind: 'openai', baseUrl: 'https://gw.example/v1', apiKey: 'k',
      models: ['a', 'b'], default: 'a', authHeader: true, noProxy: false, effort: '', vision: [],
    });
    expect(saved[0]).toMatchObject({ name: 'gw', hasKey: true, keyEnv: 'GW_API_KEY', models: ['a', 'b'] });

    // An edit that only names a default must not touch the models or the key.
    const edited = await port.editProvider({ name: 'gw', default: 'b' });
    expect(edited[0]).toMatchObject({ default: 'b', models: ['a', 'b'], hasKey: true, keyEnv: 'GW_API_KEY' });

    const ws = await port.setWebSearch('gw', true);
    expect(ws[0].webSearch).toBe(true);
    const th = await port.setThinking('gw', true);
    expect(th[0].sendsThinking).toBe(true);

    expect(await port.removeProvider('gw')).toEqual([]);
  });

  it('leaves an unknown name alone instead of inventing an entry', async () => {
    const port = new MockPort();
    const after = await port.editProvider({ name: 'nope', default: 'x' });
    expect(after).toEqual([]);
  });
});
