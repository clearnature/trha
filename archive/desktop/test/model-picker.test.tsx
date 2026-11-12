// @vitest-environment jsdom
// P6: the picker chooses which saved connection (and model) answers the next
// step, and that choice reaches the port — not just the screen.

import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ModelPicker } from '../src/renderer/ui/ModelPicker.js';
import { SessionProvider, useSessionStore, type SessionStore } from '../src/renderer/ui/SessionContext.js';
import { PrefsProvider } from '../src/renderer/ui/PrefsContext.js';
import { makeSessionStore } from '../src/renderer/state/sessionStore.js';
import { DEFAULT_PREFS, type PrefsBackend } from '../src/renderer/state/prefs.js';
import { MockPort } from '../src/renderer/port/mock.js';

const backend: PrefsBackend = { load: async () => ({ ...DEFAULT_PREFS }), save: async () => { /* ignore */ } };
let port: MockPort;
let store: SessionStore;

const mount = () => render(
  <PrefsProvider backend={backend} initial={{ ...DEFAULT_PREFS }}>
    <SessionProvider store={store}><ModelPicker /></SessionProvider>
  </PrefsProvider>,
);

beforeEach(async () => {
  port = new MockPort();
  store = makeSessionStore(port);
  await store.getState().refresh();
  await store.getState().select('mock-2');
});

describe('ModelPicker', () => {
  it('offers the kernel default plus every saved connection', async () => {
    await port.saveProvider({
      name: 'deepseek', kind: 'openai', baseUrl: 'https://api.deepseek.com/v1', apiKey: '',
      models: ['deepseek-chat'], default: 'deepseek-chat',
      authHeader: true, noProxy: false, effort: '', vision: [],
    });
    mount();
    await waitFor(() => expect(screen.getByRole('option', { name: 'deepseek' })).toBeTruthy());
    // Both selects carry the "kernel default" entry.
    expect(screen.getAllByRole('option', { name: '默认（内核）' }).length).toBe(2);
  });

  it('records the choice in the store and disables the model list without a provider', () => {
    mount();
    expect((screen.getByLabelText('模型') as HTMLSelectElement).disabled).toBe(true);
    expect(store.getState().selectedProvider).toBeNull();
  });

  it('carries the picked provider and model into the next step', async () => {
    await port.saveProvider({
      name: 'gw', kind: 'openai', baseUrl: 'https://gw.example/v1', apiKey: '',
      models: ['m-a', 'm-b'], default: 'm-a',
      authHeader: true, noProxy: false, effort: '', vision: [],
    });
    mount();
    await waitFor(() => expect(screen.getByRole('option', { name: 'gw' })).toBeTruthy());

    await userEvent.selectOptions(screen.getByLabelText('模型服务'), 'gw');
    await waitFor(() => expect((screen.getByLabelText('模型') as HTMLSelectElement).disabled).toBe(false));
    await userEvent.selectOptions(screen.getByLabelText('模型'), 'm-b');

    expect(store.getState().selectedProvider).toBe('gw');
    expect(store.getState().selectedModel).toBe('m-b');

    // The step itself carries it — the assertion is on what the port received.
    await store.getState().send('hi');
    // ✅ 2026-09-19 更新：step 现携带 genParams（LLM 设置接线）；target 断言改部分匹配
    await waitFor(() => expect(port.lastTarget).toEqual(expect.objectContaining({ provider: 'gw', model: 'm-b' })));
  });

  it('clears the model when the provider changes', async () => {
    await port.saveProvider({
      name: 'gw', kind: 'openai', baseUrl: 'https://gw.example/v1', apiKey: '',
      models: ['m-a'], default: 'm-a', authHeader: true, noProxy: false, effort: '', vision: [],
    });
    mount();
    await waitFor(() => screen.getByRole('option', { name: 'gw' }));
    await userEvent.selectOptions(screen.getByLabelText('模型服务'), 'gw');
    await userEvent.selectOptions(screen.getByLabelText('模型'), 'm-a');
    expect(store.getState().selectedModel).toBe('m-a');

    await userEvent.selectOptions(screen.getByLabelText('模型服务'), '');
    expect(store.getState().selectedProvider).toBeNull();
    expect(store.getState().selectedModel).toBeNull();
  });
});
