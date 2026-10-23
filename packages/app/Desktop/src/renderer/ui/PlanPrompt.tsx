// PlanPrompt: surfaces whatever is waiting for a decision.
//
// Two shapes share the spot because they are the same question at two
// granularities: a single-command gate (PlanCard) and a multi-step plan
// (PlanStepsCard). The kernel owns both states; the store only relays.

import { PlanCard } from './cards/PlanCard.js';
import { PlanStepsCard } from './cards/PlanStepsCard.js';
import { useSession, useSessionStore } from './SessionContext.js';

export function PlanPrompt() {
  const pending = useSession(s => s.pendingPlan);
  const plan = useSession(s => s.plan);
  const busy = useSession(s => s.busy);
  const store = useSessionStore();

  if (plan && plan.phase !== 'idle') {
    return (
      <PlanStepsCard
        plan={plan}
        disabled={busy}
        onDecide={action => void store.getState().decideStep(action)}
      />
    );
  }
  if (!pending) return null;
  return (
    <PlanCard
      message={pending.message}
      disabled={busy}
      onDecide={approve => void store.getState().decide(approve)}
    />
  );
}

export default PlanPrompt;
