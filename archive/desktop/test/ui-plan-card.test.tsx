// @vitest-environment jsdom
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { PlanCard } from '../src/renderer/ui/cards/PlanCard.js';
import { PlanPrompt } from '../src/renderer/ui/PlanPrompt.js';
import { SessionProvider, type SessionStore } from '../src/renderer/ui/SessionContext.js';
import { makeSessionStore } from '../src/renderer/state/sessionStore.js';
import { MockPort } from '../src/renderer/port/mock.js';

describe('PlanCard', () => {
  it('renders the plan text and the approve/deny verbs', () => {
    const onDecide = vi.fn();
    render(<PlanCard message={'step 1\nstep 2'} onDecide={onDecide} />);
    expect(document.querySelector('.plan-body')?.textContent).toBe('step 1\nstep 2');
    expect(screen.getByText('批准')).toBeTruthy();
    expect(screen.getByText('拒绝')).toBeTruthy();
  });

  it('calls onDecide with the chosen verb', async () => {
    const onDecide = vi.fn();
    render(<PlanCard message={'p'} onDecide={onDecide} />);
    await userEvent.click(screen.getByText('批准'));
    expect(onDecide).toHaveBeenLastCalledWith(true);
    await userEvent.click(screen.getByText('拒绝'));
    expect(onDecide).toHaveBeenLastCalledWith(false);
  });

  it('disables the verbs when told to', () => {
    render(<PlanCard message={'p'} onDecide={() => {}} disabled />);
    expect((screen.getByText('批准') as HTMLButtonElement).disabled).toBe(true);
  });
});

describe('PlanPrompt (store roundtrip)', () => {
  let store: SessionStore;
  let port: MockPort;

  beforeEach(async () => {
    port = new MockPort();
    store = makeSessionStore(port);
    await store.getState().refresh();
    await store.getState().select('mock-2');
  });

  const mount = () => render(<SessionProvider store={store}><PlanPrompt /></SessionProvider>);

  it('renders nothing when there is no pending plan', () => {
    const { container } = mount();
    expect(container.firstChild).toBeNull();
  });

  it('surfaces a pending plan and approves it through the store', async () => {
    await act(async () => {
      await port.step('mock-2', 'plan please', true);
      store.setState({ pendingPlan: { message: 'plan please' } });
    });
    mount();
    expect(screen.getByText('计划待批准')).toBeTruthy();
    await userEvent.click(screen.getByText('批准'));
    await waitFor(() => expect(store.getState().pendingPlan).toBeNull());
    const msgs = store.getState().uiMessages;
    expect(msgs.at(-1)?.kind).toBe('assistant');
  });

  it('denies a pending plan through the store', async () => {
    await act(async () => {
      await port.step('mock-2', 'plan please', true);
      store.setState({ pendingPlan: { message: 'plan please' } });
    });
    mount();
    await userEvent.click(screen.getByText('拒绝'));
    await waitFor(() => expect(store.getState().pendingPlan).toBeNull());
    expect(store.getState().uiMessages.at(-1)?.kind).not.toBe('assistant');
  });
});
