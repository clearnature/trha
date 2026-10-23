// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, act } from '@testing-library/react';
import { StatusBar } from '../src/renderer/ui/StatusBar.js';
import { SessionProvider, type SessionStore } from '../src/renderer/ui/SessionContext.js';
import { makeSessionStore } from '../src/renderer/state/sessionStore.js';
import { MockPort } from '../src/renderer/port/mock.js';

let store: SessionStore;

const mount = () => render(
  <SessionProvider store={store}><StatusBar /></SessionProvider>,
);

beforeEach(() => {
  store = makeSessionStore(new MockPort());
});

describe('StatusBar', () => {
  it('shows mode, session placeholder, ready state and usage placeholder', () => {
    mount();
    expect(screen.getByText('standard')).toBeTruthy();
    expect(screen.getByText('无会话')).toBeTruthy();
    expect(screen.getByText('✅ 就绪')).toBeTruthy();
    expect(screen.getByLabelText('token usage').textContent).toContain('—');
  });

  it('reflects busy state from the store', async () => {
    mount();
    await act(async () => { store.setState({ busy: true }); });
    expect(screen.getByText('⏳ 工作中')).toBeTruthy();
  });

  it('reflects error state from the store', async () => {
    mount();
    await act(async () => { store.setState({ lastError: 'boom' }); });
    expect(screen.getByText(/❌ boom/)).toBeTruthy();
  });

  // P3: the kernel's causal-constraint verdict must be visible in the UI.
  it('shows the constraint pass badge when the kernel says pass', async () => {
    mount();
    await act(async () => {
      store.setState({ constraint: { status: 'pass', reason: 'ok' } as Record<string, unknown> });
    });
    const badge = screen.getByText(/pass/);
    expect(badge.getAttribute('data-constraint')).toBe('pass');
  });

  it('shows a warn badge (and the reason) when the kernel says warn', async () => {
    mount();
    await act(async () => {
      store.setState({ constraint: { status: 'warn', reason: 'berry drift' } as Record<string, unknown> });
    });
    const badge = screen.getByText(/warn/);
    expect(badge.getAttribute('data-constraint')).toBe('warn');
    expect(badge.getAttribute('title')).toBe('berry drift');
  });

  it('shows no badge before any constrained step (does not fabricate a verdict)', () => {
    mount();
    expect(screen.queryByText(/pass/)).toBeNull();
    expect(screen.queryByText(/warn/)).toBeNull();
  });

  it('renders the short session id and the studio version once loaded', async () => {
    mount();
    await act(async () => {
      store.setState({ currentId: 'abcdef1234567890' });
      await store.getState().loadVersion();
    });
    expect(screen.getByText('abcdef12')).toBeTruthy();
    expect(screen.getByText('v0.0.0-mock')).toBeTruthy();
  });
});
