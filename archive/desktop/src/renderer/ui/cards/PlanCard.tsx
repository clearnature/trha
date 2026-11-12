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
  // 权限 ask 请求（来自权限规则引擎 REQUIRE_APPROVAL）→ 权限确认文案；否则计划
  const isPermission = message.includes('REQUIRE_APPROVAL');
  return (
    <div className="plan-card" data-card={isPermission ? 'permission' : 'plan'}>
      <div className="plan-header">{isPermission ? t('perm.title') : t('plan.title')}</div>
      <pre className="plan-body">{isPermission ? message.replace(/^.*REQUIRE_APPROVAL:\s*/, '') : message}</pre>
      <div className="plan-actions">
        <button
          type="button"
          className="plan-approve"
          disabled={disabled}
          onClick={() => onDecide(true)}
        >
          {isPermission ? t('perm.allow') : t('plan.approve')}
        </button>
        <button
          type="button"
          className="plan-deny"
          disabled={disabled}
          onClick={() => onDecide(false)}
        >
          {isPermission ? t('perm.deny') : t('plan.deny')}
        </button>
      </div>
    </div>
  );
}

export default PlanCard;
