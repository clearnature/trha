// Plan approval card: shows the proposed plan text and the approve/deny
// verbs.  Kept presentational (callbacks in props) so it stays testable;
// PlanPrompt wires it to the store.

import { useT } from '../PrefsContext.js';

export interface PlanCardProps {
  message: string;
  onDecide: (approve: boolean) => void;
  disabled?: boolean;
}

export function PlanCard({ message, onDecide, disabled }: PlanCardProps) {
  const t = useT();
  return (
    <div className="plan-card" data-card="plan">
      <div className="plan-header">{t('plan.title')}</div>
      <pre className="plan-body">{message}</pre>
      <div className="plan-actions">
        <button
          type="button"
          className="plan-approve"
          disabled={disabled}
          onClick={() => onDecide(true)}
        >
          {t('plan.approve')}
        </button>
        <button
          type="button"
          className="plan-deny"
          disabled={disabled}
          onClick={() => onDecide(false)}
        >
          {t('plan.deny')}
        </button>
      </div>
    </div>
  );
}

export default PlanCard;
