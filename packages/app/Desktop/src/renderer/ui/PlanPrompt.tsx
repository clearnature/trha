// PlanPrompt: container that surfaces the store's pending plan and routes
// approve/deny to the session store's decision action.

import { PlanCard } from './cards/PlanCard.js';
import { useSession, useSessionStore } from './SessionContext.js';

export function PlanPrompt() {
  const pending = useSession(s => s.pendingPlan);
  const busy = useSession(s => s.busy);
  const store = useSessionStore();

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
