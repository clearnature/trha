// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { SettingsPanel } from '../src/renderer/ui/SettingsPanel.js';
import { PrefsProvider } from '../src/renderer/ui/PrefsContext.js';
import { SessionProvider, type SessionStore } from '../src/renderer/ui/SessionContext.js';
import { makeSessionStore } from '../src/renderer/state/sessionStore.js';
import { DEFAULT_PREFS, type Prefs, type PrefsBackend } from '../src/renderer/state/prefs.js';
import { MockPort } from '../src/renderer/port/mock.js';

let store: SessionStore;
let saved: Prefs;
const backend: PrefsBackend = {
  load: async () => ({ ...DEFAULT_PREFS }),
  save: async p => { saved = p; },
};

const mount = () => render(
  <PrefsProvider backend={backend} initial={{ ...DEFAULT_PREFS }}>
    <SessionProvider store={store}>
      <SettingsPanel onClose={() => {}} />
    </SessionProvider>
  </PrefsProvider>,
);

beforeEach(async () => {
  saved = { ...DEFAULT_PREFS };
  store = makeSessionStore(new MockPort());
  await store.getState().loadCatalog();
  await store.getState().loadVersion();
});

describe('SettingsPanel', () => {
  it('renders local prefs and the read-only kernel surface', () => {
    mount();
    expect(screen.getByLabelText('主题')).toBeTruthy();
    expect(screen.getByLabelText('语言')).toBeTruthy();
    expect(screen.getByLabelText('字号')).toBeTruthy();
    expect(screen.getByText(/内核版本: 0.0.0-mock/)).toBeTruthy();
    expect(screen.getByText('standard')).toBeTruthy(); // mode list entry
    expect(screen.getByText('mock-model')).toBeTruthy();
  });

  it('persists a theme change through the injected backend', async () => {
    mount();
    await userEvent.selectOptions(screen.getByLabelText('主题'), 'dark');
    await waitFor(() => expect(saved.theme).toBe('dark'));
  });

  it('persists a font-size change', async () => {
    mount();
    const slider = screen.getByLabelText('字号') as HTMLInputElement;
    fireEvent.change(slider, { target: { value: '20' } });
    await waitFor(() => expect(saved.fontSize).toBe(20));
  });

  it('switches language and re-renders labels', async () => {
    mount();
    await userEvent.selectOptions(screen.getByLabelText('语言'), 'en');
    await waitFor(() => expect(screen.getByText('Settings')).toBeTruthy());
    expect(screen.getByLabelText('Theme')).toBeTruthy();
  });
});
