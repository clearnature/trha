// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ProvidersPanel } from '../src/renderer/ui/ProvidersPanel.js';
import { PrefsProvider } from '../src/renderer/ui/PrefsContext.js';
import { DEFAULT_PREFS, type PrefsBackend } from '../src/renderer/state/prefs.js';
import { MockPort } from '../src/renderer/port/mock.js';
import { hostOf, nameFrom, uniqueName, vendorLabel } from '../src/renderer/ui/vendors.js';

const backend: PrefsBackend = { load: async () => ({ ...DEFAULT_PREFS }), save: async () => { /* ignore */ } };
let port: MockPort;

const mount = () => render(
  <PrefsProvider backend={backend} initial={{ ...DEFAULT_PREFS }}>
    <ProvidersPanel port={port} />
  </PrefsProvider>,
);

beforeEach(() => { port = new MockPort(); });

describe('vendors', () => {
  it('derives a display name from the host', () => {
    expect(hostOf('https://api.deepseek.com/v1')).toBe('api.deepseek.com');
    expect(vendorLabel('api.deepseek.com')).toBe('deepseek');
    expect(nameFrom('https://api.deepseek.com/v1')).toBe('deepseek');
    expect(nameFrom('nonsense')).toBe('custom');
    expect(uniqueName('deepseek', ['deepseek', 'deepseek-2'])).toBe('deepseek-3');
  });
});

describe('ProvidersPanel', () => {
  it('starts empty and offers to add a connection', async () => {
    mount();
    await waitFor(() => expect(screen.getByText('还没有连接。添加一个即可开始。')).toBeTruthy());
    expect(screen.getByText('添加连接')).toBeTruthy();
  });

  it('probes an endpoint, prefills the name, then saves it', async () => {
    mount();
    await waitFor(() => screen.getByText('添加连接'));
    await userEvent.click(screen.getByText('添加连接'));

    await userEvent.type(screen.getByLabelText('接口地址'), 'https://api.deepseek.com/v1');
    await userEvent.click(screen.getByText('连一下试试'));

    // The probe's catalogue is what the panel shows, and the name is derived.
    await waitFor(() => expect(screen.getByText('mock-model-a')).toBeTruthy());
    expect(screen.getByText('mock-model-b')).toBeTruthy();
    expect((screen.getByLabelText('名字') as HTMLInputElement).value).toBe('deepseek');

    await userEvent.click(screen.getByText('添加'));
    await waitFor(() => expect(document.querySelector('[data-provider="deepseek"]')).toBeTruthy());
    // Saved entry remembers where its key comes from, not the key itself.
    const entries = await port.providerEntries();
    expect(entries[0]).toMatchObject({ name: 'deepseek', hasKey: false, keyEnv: 'DEEPSEEK_API_KEY' });
  });

  it('can drop a model from the selection before saving', async () => {
    mount();
    await waitFor(() => screen.getByText('添加连接'));
    await userEvent.click(screen.getByText('添加连接'));
    await userEvent.type(screen.getByLabelText('接口地址'), 'https://gw.example/v1');
    await userEvent.click(screen.getByText('连一下试试'));
    await waitFor(() => screen.getByText('mock-model-b'));

    await userEvent.click(screen.getByRole('checkbox', { name: 'mock-model-b' }));
    await userEvent.click(screen.getByText('添加'));
    await waitFor(async () => {
      const entries = await port.providerEntries();
      expect(entries[0]?.models).toEqual(['mock-model-a']);
    });
  });

  it('reports a probe that cannot connect', async () => {
    mount();
    await waitFor(() => screen.getByText('添加连接'));
    await userEvent.click(screen.getByText('添加连接'));
    await userEvent.type(screen.getByLabelText('接口地址'), 'nonsense');
    await userEvent.click(screen.getByText('连一下试试'));
    await waitFor(() => expect(screen.getByText(/provider\.unreachable/)).toBeTruthy());
  });

  it('edits the default model and flips the two per-row switches (P8)', async () => {
    await port.saveProvider({
      name: 'gw', kind: 'openai', baseUrl: 'https://gw.example/v1', apiKey: '',
      models: ['m-a', 'm-b'], default: 'm-a',
      authHeader: true, noProxy: false, effort: '', vision: [],
    });
    mount();
    await waitFor(() => expect(document.querySelector('[data-provider="gw"]')).toBeTruthy());

    // Default model: picking one goes through editProvider, keeping the rest.
    await userEvent.selectOptions(screen.getByLabelText('默认模型 gw'), 'm-b');
    await waitFor(async () => {
      const [entry] = await port.providerEntries();
      expect(entry).toMatchObject({ default: 'm-b', models: ['m-a', 'm-b'] });
    });

    await userEvent.click(screen.getByLabelText('联网搜索 gw'));
    await waitFor(async () => expect((await port.providerEntries())[0].webSearch).toBe(true));

    await userEvent.click(screen.getByLabelText('思考 gw'));
    await waitFor(async () => expect((await port.providerEntries())[0].sendsThinking).toBe(true));
  });

  it('disables a switch the protocol cannot carry', async () => {
    await port.saveProvider({
      name: 'anth', kind: 'anthropic', baseUrl: 'https://api.anthropic.com', apiKey: '',
      models: ['claude'], default: 'claude',
      authHeader: true, noProxy: false, effort: '', vision: [],
    });
    mount();
    await waitFor(() => expect(document.querySelector('[data-provider="anth"]')).toBeTruthy());
    // Anthropic's wire declares no endpoint-executed search, but does reason.
    await waitFor(() => {
      expect((screen.getByLabelText('联网搜索 anth') as HTMLInputElement).disabled).toBe(true);
      expect((screen.getByLabelText('思考 anth') as HTMLInputElement).disabled).toBe(false);
    });
  });

  it('removes a saved connection', async () => {
    await port.saveProvider({
      name: 'gone', kind: 'openai', baseUrl: 'https://gw.example/v1', apiKey: '',
      models: ['m'], default: 'm', authHeader: true, noProxy: false, effort: '', vision: [],
    });
    mount();
    await waitFor(() => expect(document.querySelector('[data-provider="gone"]')).toBeTruthy());
    await userEvent.click(screen.getByText('删除'));
    await waitFor(() => expect(document.querySelector('[data-provider="gone"]')).toBeNull());
  });
});
