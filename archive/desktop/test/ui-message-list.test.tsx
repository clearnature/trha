// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MessageList } from '../src/renderer/ui/MessageList.js';
import { Composer } from '../src/renderer/ui/Composer.js';
import { SessionProvider, type SessionStore } from '../src/renderer/ui/SessionContext.js';
import { makeSessionStore } from '../src/renderer/state/sessionStore.js';
import { MockPort } from '../src/renderer/port/mock.js';

let store: SessionStore;
let port: MockPort;

const mountList = () => render(<SessionProvider store={store}><MessageList /></SessionProvider>);
const mountComposer = () => render(<SessionProvider store={store}><Composer /></SessionProvider>);

beforeEach(async () => {
  port = new MockPort();
  store = makeSessionStore(port);
  await store.getState().refresh();
});

describe('MessageList', () => {
  it('shows the welcome empty state when no session is selected', () => {
    mountList();
    expect(screen.getByText('欢迎使用 trha')).toBeTruthy();
    expect(screen.getByText('新建会话')).toBeTruthy();
  });

  it('shows the per-session empty hint when the session has no messages', async () => {
    await store.getState().select('mock-2');
    mountList();
    expect(screen.getByText('发送消息开始对话。')).toBeTruthy();
  });

  it('renders user and assistant cards for a loaded session', async () => {
    await store.getState().select('mock-1');
    mountList();
    expect(document.querySelector('[data-card="user"]')).toBeTruthy();
    expect(document.querySelector('[data-card="say"]')).toBeTruthy();
  });

  it('renders tool and notice cards from the stream', async () => {
    await store.getState().select('mock-2');
    store.setState({ uiMessages: [
      { kind: 'user', text: 'hi' },
      { kind: 'tool', tool: { name: 'read_file', args: [], status: 'succeeded', durationMs: 1 } },
      { kind: 'notice', text: 'oops' },
    ] });
    mountList();
    expect(document.querySelector('[data-card="tool"]')).toBeTruthy();
    expect(document.querySelector('[data-card="notice"]')).toBeTruthy();
  });

  it('marks the last assistant card as streaming while busy', async () => {
    await store.getState().select('mock-2');
    store.setState({ uiMessages: [{ kind: 'assistant', text: 'partial' }], busy: true });
    mountList();
    expect(document.querySelector('.md-cursor')).toBeTruthy();
  });

  it('renders the arriving answer before step() returns it (A3)', async () => {
    await store.getState().select('mock-2');
    store.setState({ streamText: 'Hello fro', busy: true });
    mountList();
    expect(screen.getByText('Hello fro')).toBeTruthy();
    // Same streaming marker the settled card uses.
    expect(document.querySelector('.md-cursor')).toBeTruthy();
  });
});

describe('Composer', () => {
  it('sends the typed message through the store', async () => {
    await store.getState().select('mock-2');
    mountComposer();
    await userEvent.type(screen.getByLabelText('message'), 'hello there');
    await userEvent.click(screen.getByText('发送'));
    await waitFor(() => {
      const texts = store.getState().uiMessages.map(m => ('text' in m ? m.text : ''));
      expect(texts.some(t => t.includes('hello there'))).toBe(true);
    });
  });

  it('creates a session first when none is selected', async () => {
    mountComposer();
    await userEvent.type(screen.getByLabelText('message'), 'first');
    await userEvent.click(screen.getByText('发送'));
    await waitFor(() => expect(store.getState().currentId).toBeTruthy());
  });

  it('disables the send button for empty input', () => {
    mountComposer();
    expect((screen.getByText('发送') as HTMLButtonElement).disabled).toBe(true);
  });
});
