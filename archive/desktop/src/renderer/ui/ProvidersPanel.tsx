// ProvidersPanel: the connection list. Each row is one endpoint the kernel
// knows about; adding one goes through AddProvider (probe first, type last).
// A row also carries the two per-endpoint switches and its default model —
// whether a switch is usable is the protocol's answer, not ours.

import { useCallback, useEffect, useState } from 'react';
import type { Port } from '../port/port.js';
import type { Protocol, ProviderEntry } from '../port/provider.js';
import { KIND_LABEL } from '../port/provider.js';
import { useT } from './PrefsContext.js';
import { AddProvider } from './AddProvider.js';
import { hostOf, vendorLabel } from './vendors.js';

export interface ProvidersPanelProps {
  port: Port;
}

export function ProvidersPanel({ port }: ProvidersPanelProps) {
  const t = useT();
  const [entries, setEntries] = useState<ProviderEntry[]>([]);
  const [protocols, setProtocols] = useState<Protocol[]>([]);
  const [adding, setAdding] = useState(false);
  const [note, setNote] = useState('');
  const [loaded, setLoaded] = useState(false);

  const reload = useCallback(async () => {
    try {
      setEntries(await port.providerEntries());
      setProtocols(await port.protocols().catch(() => []));
    } catch (e) {
      setNote(String(e));
    } finally {
      setLoaded(true);
    }
  }, [port]);

  useEffect(() => { void reload(); }, [reload]);

  const protocolFor = (kind: string) => protocols.find(x => x.kind === kind);
  const canWebSearch = (kind: string) => protocolFor(kind)?.serverWebSearch ?? false;
  const canSetThinking = (kind: string) => protocolFor(kind)?.reasoningParams ?? false;

  const run = async (fn: () => Promise<ProviderEntry[]>) => {
    try {
      setEntries(await fn());
      setNote('');
    } catch (e) {
      setNote(String(e));
    }
  };

  const remove = (name: string) => run(() => port.removeProvider(name));
  const setDefault = (name: string, model: string) => run(() => port.editProvider({ name, default: model }));
  const toggleWebSearch = (name: string, on: boolean) => run(() => port.setWebSearch(name, on));
  const toggleThinking = (name: string, on: boolean) => run(() => port.setThinking(name, on));

  const check = async (name: string) => {
    try {
      const r = await port.checkProvider(name);
      setNote(r.ok
        ? t('providers.checkOk', { count: (r.models ?? []).length })
        : `${t('providers.checkFailed')}: ${r.error ?? r.code ?? ''}`);
    } catch (e) {
      setNote(String(e));
    }
  };

  return (
    <div className="providers">
      <div className="prov-head">
        <span>{t('providers.title')}</span>
        {!adding && (
          <button type="button" className="act" onClick={() => setAdding(true)}>
            {t('providers.addConnection')}
          </button>
        )}
      </div>

      {loaded && entries.length === 0 && !adding && (
        <p className="acct-note">{t('providers.empty')}</p>
      )}

      {entries.map(p => (
        <div key={p.name} className="prov-row" data-provider={p.name}>
          <span className="prov-name">{p.name}</span>
          <span className="prov-kinds">{KIND_LABEL[p.kind] ?? p.kind}</span>
          <span className="prov-host" title={p.baseUrl}>{vendorLabel(hostOf(p.baseUrl))}</span>
          <span className="prov-models">{t('providers.modelsCount', { count: p.models.length })}</span>
          <span className={`prov-key ${p.hasKey ? 'on' : 'off'}`}>
            {p.hasKey ? t('providers.hasKey') : t('providers.noKey')}
          </span>

          <label className="prov-default">
            <span>{t('providers.defaultModel')}</span>
            <select
              aria-label={`${t('providers.defaultModel')} ${p.name}`}
              value={p.default}
              onChange={e => void setDefault(p.name, e.target.value)}
            >
              {p.models.map(m => <option key={m} value={m}>{m}</option>)}
            </select>
          </label>

          <label className="prov-toggle" title={t('providers.webSearch')}>
            <input
              type="checkbox"
              aria-label={`${t('providers.webSearch')} ${p.name}`}
              checked={!!p.webSearch}
              disabled={!canWebSearch(p.kind)}
              onChange={e => void toggleWebSearch(p.name, e.target.checked)}
            />
            <span>{t('providers.webSearch')}</span>
          </label>

          <label className="prov-toggle" title={t('providers.thinking')}>
            <input
              type="checkbox"
              aria-label={`${t('providers.thinking')} ${p.name}`}
              checked={!!p.sendsThinking}
              disabled={!canSetThinking(p.kind)}
              onChange={e => void toggleThinking(p.name, e.target.checked)}
            />
            <span>{t('providers.thinking')}</span>
          </label>

          <button type="button" className="act" onClick={() => void check(p.name)}>{t('providers.recheck')}</button>
          <button type="button" className="act" onClick={() => void remove(p.name)}>{t('providers.remove')}</button>
        </div>
      ))}

      {note && <p className="acct-note" role="status">{note}</p>}

      {adding && (
        <AddProvider
          port={port}
          taken={entries.map(p => p.name)}
          onDone={() => { setAdding(false); void reload(); }}
          onCancel={() => setAdding(false)}
        />
      )}
    </div>
  );
}

export default ProvidersPanel;
