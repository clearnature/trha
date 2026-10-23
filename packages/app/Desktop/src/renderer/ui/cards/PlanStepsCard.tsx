// Multi-step plan card: the kernel owns the steps, the phase and the barrier;
// this renders them and routes the four decisions. Kept presentational
// (callbacks in props) so it stays testable — PlanPrompt wires it to the store.

import { useT } from '../PrefsContext.js';
import type { PlanDecision, PlanState } from '../../port/types.js';

export interface PlanStepsCardProps {
  plan: PlanState;
  onDecide: (action: PlanDecision) => void;
  disabled?: boolean;
}

const MARKS: Record<string, string> = {
  done: '✓',
  failed: '✗',
  skipped: '–',
  approved: '▶',
  rejected: '✕',
  pending: '·',
};

export function PlanStepsCard({ plan, onDecide, disabled }: PlanStepsCardProps) {
  const t = useT();
  const pending = plan.steps.find(s => s.status === 'pending');
  return (
    <div className="plan-card plan-steps" data-card="steps" data-phase={plan.phase}>
      <div className="plan-header">{t('plan.steps.title')}</div>
      <ol className="plan-step-list">
        {plan.steps.map(step => (
          <li
            key={step.id}
            className={`plan-step status-${step.status}`}
            data-step-id={step.id}
            data-status={step.status}
          >
            <span className="plan-step-mark" aria-hidden="true">{MARKS[step.status] ?? '·'}</span>
            <span className="plan-step-title">{step.title}</span>
            {plan.pending === step.id && (
              <span className="plan-step-pending">{t('plan.steps.pending')}</span>
            )}
          </li>
        ))}
      </ol>
      <div className="plan-actions">
        <button
          type="button"
          className="plan-approve"
          disabled={disabled || !pending}
          onClick={() => onDecide('approve')}
        >
          {t('plan.steps.approve')}
        </button>
        <button
          type="button"
          className="plan-skip"
          disabled={disabled || !pending}
          onClick={() => onDecide('skip')}
        >
          {t('plan.steps.skip')}
        </button>
        <button
          type="button"
          className="plan-deny"
          disabled={disabled || !pending}
          onClick={() => onDecide('reject')}
        >
          {t('plan.steps.reject')}
        </button>
        <button
          type="button"
          className="plan-abandon"
          disabled={disabled || plan.phase === 'idle'}
          onClick={() => onDecide('abandon')}
        >
          {t('plan.steps.abandon')}
        </button>
      </div>
    </div>
  );
}

export default PlanStepsCard;
