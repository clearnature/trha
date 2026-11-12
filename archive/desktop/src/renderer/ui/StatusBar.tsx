// Status bar: a compact footer showing the active mode, current session,
// busy/error indicator, the kernel's causal-constraint verdict (D-1 / P3) and
// the studio version.  Token usage is a reserved placeholder until the kernel
// exposes it through the port.

import { useSession } from './SessionContext.js';
import { useT } from './PrefsContext.js';

export function StatusBar() {
  const mode = useSession(s => s.selectedMode);
  const currentId = useSession(s => s.currentId);
  const busy = useSession(s => s.busy);
  const lastError = useSession(s => s.lastError);
  const version = useSession(s => s.version);
  const constraint = useSession(s => s.constraint);
  const t = useT();

  const state = busy ? 'processing' : lastError ? 'error' : 'ready';
  const sessionLabel = currentId ? currentId.slice(0, 8) : t('status.noSession');
  // The kernel's verdict is three-valued (裁定② 2026-11-11): `pass` (adopted),
  // `hold` (kept as draft, review pending) or `reject` (not adopted). Anything
  // else is shown verbatim rather than guessed at.
  const verdict = typeof constraint?.status === 'string' ? constraint.status : null;

  return (
    <div className="status-bar" role="status" aria-live="polite">
      <span className="status-mode">{mode}</span>
      <span className="status-session" title={currentId ?? undefined}>{sessionLabel}</span>
      <span className={`status-state ${state}`}>
        {busy ? `⏳ ${t('status.working')}` : lastError ? `❌ ${lastError}` : `✅ ${t('status.ready')}`}
      </span>
      {verdict && (
        <span
          className={`status-constraint ${verdict}`}
          data-constraint={verdict}
          title={typeof constraint?.reason === 'string' ? constraint.reason : undefined}
        >
          {verdict === 'pass' ? '🛡 pass' : verdict === 'reject' ? '⛔ reject' : `⚠ ${verdict}`}
        </span>
      )}
      <span className="status-usage" aria-label="token usage">{t('status.tokens')}</span>
      <span className="status-version">{version ? `v${version.current}` : 'v—'}</span>
    </div>
  );
}

export default StatusBar;
