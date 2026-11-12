// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Sidebar } from '../src/renderer/ui/Sidebar.js';
import { SessionProvider, type SessionStore } from '../src/renderer/ui/SessionContext.js';
import { makeSessionStore } from '../src/renderer/state/sessionStore.js';
import { MockPort } from '../src/renderer/port/mock.js';

let store: SessionStore;
let port: MockPort;

const mount = () => render(<SessionProvider store={store}><Sidebar /></SessionProvider>);

beforeEach(async () => {
  port = new MockPort();
  store = makeSessionStore(port);
  await store.getState().refresh();
});

describe('Sidebar', () => {
  it('lists the fixture sessions', async () => {
    mount();
    expect(screen.getByText(/mock-1/)).toBeTruthy();
    expect(screen.getByText(/mock-2/)).toBeTruthy();
  });

  it('creates a session on the New Session button', async () => {
    mount();
    await userEvent.click(screen.getByText('新建会话'));
    await waitFor(() => expect(store.getState().sessions.length).toBe(3));
    expect(store.getState().currentId).toBeTruthy();
  });

  it('selects a session on click', async () => {
    mount();
    await userEvent.click(screen.getByText(/mock-1/));
    await waitFor(() => expect(store.getState().currentId).toBe('mock-1'));
    expect(store.getState().uiMessages.length).toBe(2);
  });

  it('deletes a session via its delete button', async () => {
    mount();
    await userEvent.click(screen.getByLabelText('delete mock-2'));
    await waitFor(() => expect(store.getState().sessions.map(s => s.id)).toEqual(['mock-1']));
    expect(port).toBeTruthy();
  });

  it('renders the mode selector and updates the selected mode', async () => {
    store.setState({ modes: { standard: { name: 'standard', description: '', tools: [], persona: { enabled: false, template: '', maxBytes: 0 }, compaction: { enabled: false, prunerEnabled: false, thresholdChars: 0, headChars: 0, tailChars: 0 }, delegation: { enabled: false, forkEnabled: false, ralphEnabled: false, maxRounds: 0 }, ptc: { enabled: false, language: '', description: '' }, hasPlan: true, hasTodo: false, hasWebSearch: false, hasShell: true, maxTokens: 0, contextSize: 0 }, minimal: { name: 'minimal', description: '', tools: [], persona: { enabled: false, template: '', maxBytes: 0 }, compaction: { enabled: false, prunerEnabled: false, thresholdChars: 0, headChars: 0, tailChars: 0 }, delegation: { enabled: false, forkEnabled: false, ralphEnabled: false, maxRounds: 0 }, ptc: { enabled: false, language: '', description: '' }, hasPlan: false, hasTodo: false, hasWebSearch: false, hasShell: true, maxTokens: 0, contextSize: 0 } } });
    mount();
    await userEvent.selectOptions(screen.getByLabelText('mode'), 'minimal');
    expect(store.getState().selectedMode).toBe('minimal');
  });
});
