// Status bar: a compact footer showing the active mode, current session,
// busy/error indicator and the studio version.  Token usage is a reserved
// placeholder until the kernel exposes it through the port.

import { useSession } from './SessionContext.js';
import { useT } from './PrefsContext.js';

export function StatusBar() {
  const mode = useSession(s => s.selectedMode);
  const currentId = useSession(s => s.currentId);
  const busy = useSession(s => s.busy);
  const lastError = useSession(s => s.lastError);
  const version = useSession(s => s.version);
  const t = useT();

  const state = busy ? 'processing' : lastError ? 'error' : 'ready';
  const sessionLabel = currentId ? currentId.slice(0, 8) : t('status.noSession');

  return (
    <div className="status-bar" role="status" aria-live="polite">
      <span className="status-mode">{mode}</span>
      <span className="status-session" title={currentId ?? undefined}>{sessionLabel}</span>
      <span className={`status-state ${state}`}>
        {busy ? `⏳ ${t('status.working')}` : lastError ? `❌ ${lastError}` : `✅ ${t('status.ready')}`}
      </span>
      <span className="status-usage" aria-label="token usage">{t('status.tokens')}</span>
      <span className="status-version">{version ? `v${version.current}` : 'v—'}</span>
    </div>
  );
}

export default StatusBar;
