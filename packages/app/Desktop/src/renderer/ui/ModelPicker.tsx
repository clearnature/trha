// ModelPicker: which saved connection (and which of its models) answers the
// next step.  Empty means "let the kernel decide" — the default adapter.

import { useEffect, useState } from 'react';
import type { ProviderEntry } from '../port/provider.js';
import { useSession, useSessionStore } from './SessionContext.js';
import { useT } from './PrefsContext.js';

export function ModelPicker() {
  const t = useT();
  const port = useSession(s => s.port);
  const selectedProvider = useSession(s => s.selectedProvider);
  const selectedModel = useSession(s => s.selectedModel);
  const store = useSessionStore();
  const [entries, setEntries] = useState<ProviderEntry[]>([]);

  useEffect(() => {
    let live = true;
    void port.providerEntries()
      .then(list => { if (live) setEntries(list); })
      .catch(() => { if (live) setEntries([]); });
    return () => { live = false; };
  }, [port]);

  const entry = entries.find(e => e.name === selectedProvider) ?? null;
  const models = entry ? entry.models : [];

  return (
    <div className="model-picker">
      <label>
        <span>{t('picker.provider')}</span>
        <select
          aria-label={t('picker.provider')}
          value={selectedProvider ?? ''}
          onChange={e => store.getState().setTarget(e.target.value || null, null)}
        >
          <option value="">{t('picker.default')}</option>
          {entries.map(p => <option key={p.name} value={p.name}>{p.name}</option>)}
        </select>
      </label>
      <label>
        <span>{t('picker.model')}</span>
        <select
          aria-label={t('picker.model')}
          value={selectedModel ?? ''}
          disabled={!entry}
          onChange={e => store.getState().setTarget(selectedProvider, e.target.value || null)}
        >
          <option value="">{t('picker.default')}</option>
          {models.map(m => <option key={m} value={m}>{m}</option>)}
        </select>
      </label>
    </div>
  );
}

export default ModelPicker;
