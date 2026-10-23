// @vitest-environment jsdom
// Multi-step plan card: it must show every step's status and route the four
// decisions. The kernel owns the plan, so the card never invents or reorders
// steps — it renders what it is given.

import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { PlanStepsCard } from '../src/renderer/ui/cards/PlanStepsCard.js';
import type { PlanState } from '../src/renderer/port/types.js';

const plan: PlanState = {
  id: 's#plan',
  mode: 'stepwise',
  phase: 'planning',
  pending: 's2',
  steps: [
    { id: 's1', title: 'create branch', status: 'done' },
    { id: 's2', title: 'edit files', status: 'pending' },
    { id: 's3', title: 'run tests', status: 'skipped' },
    { id: 's4', title: 'deploy', status: 'failed' },
  ],
};

describe('PlanStepsCard', () => {
  it('renders one row per step, in kernel order, with its status', () => {
    render(<PlanStepsCard plan={plan} onDecide={() => {}} />);
    const rows = Array.from(document.querySelectorAll('.plan-step'));
    expect(rows.map(r => r.getAttribute('data-step-id'))).toEqual(['s1', 's2', 's3', 's4']);
    expect(rows.map(r => r.getAttribute('data-status'))).toEqual([
      'done', 'pending', 'skipped', 'failed',
    ]);
    expect(screen.getByText('create branch')).toBeTruthy();
    expect(screen.getByText('edit files')).toBeTruthy();
  });

  it('marks the pending step, and only that one', () => {
    render(<PlanStepsCard plan={plan} onDecide={() => {}} />);
    const pending = document.querySelectorAll('.plan-step-pending');
    expect(pending.length).toBe(1);
    expect(pending[0]?.closest('.plan-step')?.getAttribute('data-step-id')).toBe('s2');
  });

  // Queried by class, not label: the label depends on the active language,
  // and these tests are about behaviour, not copy.
  const button = (cls: string) => document.querySelector(cls) as HTMLButtonElement;

  it('routes each decision with its action name', () => {
    const onDecide = vi.fn();
    render(<PlanStepsCard plan={plan} onDecide={onDecide} />);
    fireEvent.click(button('.plan-approve'));
    fireEvent.click(button('.plan-skip'));
    fireEvent.click(button('.plan-deny'));
    fireEvent.click(button('.plan-abandon'));
    expect(onDecide.mock.calls.map(c => c[0])).toEqual([
      'approve', 'skip', 'reject', 'abandon',
    ]);
  });

  it('disables the decision buttons when no step is pending', () => {
    const done: PlanState = {
      ...plan,
      phase: 'executing_step',
      pending: null,
      steps: plan.steps.map(s => ({ ...s, status: s.status === 'pending' ? 'approved' : s.status })),
    };
    render(<PlanStepsCard plan={done} onDecide={() => {}} />);
    expect(button('.plan-approve').disabled).toBe(true);
    expect(button('.plan-skip').disabled).toBe(true);
    // abandoning a running plan is still meaningful
    expect(button('.plan-abandon').disabled).toBe(false);
  });

  it('disables everything while the shell is busy', () => {
    render(<PlanStepsCard plan={plan} onDecide={() => {}} disabled />);
    for (const cls of ['.plan-approve', '.plan-skip', '.plan-deny', '.plan-abandon']) {
      expect(button(cls).disabled).toBe(true);
    }
  });
});
