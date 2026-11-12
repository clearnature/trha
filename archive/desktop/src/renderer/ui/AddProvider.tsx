// AddProvider: adding a connection asks where and with what key; everything
// else is knowable by asking the endpoint, so it is probed rather than typed
// (the same stance as the reference implementation's AddProvider).

import { useState } from 'react';
import type { Port } from '../port/port.js';
import type { ProviderProbe } from '../port/provider.js';
import { KIND_LABEL } from '../port/provider.js';
import { useT } from './PrefsContext.js';
import { ModelChoice } from './ModelChoice.js';
import { nameFrom, uniqueName } from './vendors.js';

export interface AddProviderProps {
  port: Port;
  /** Names already in use, so a new one does not overwrite an existing one. */
  taken: string[];
  onDone: () => void;
  onCancel: () => void;
}

export function AddProvider({ port, taken, onDone, onCancel }: AddProviderProps) {
  const t = useT();
  const [baseUrl, setBaseUrl] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [probe, setProbe] = useState<ProviderProbe | null>(null);
  const [name, setName] = useState('');
  const [kind, setKind] = useState('openai');
  const [models, setModels] = useState<string[]>([]);
  const [picked, setPicked] = useState<string[]>([]);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const connect = async () => {
    setBusy(true);
    setErr('');
    try {
      const got = await port.probeProvider(baseUrl.trim(), apiKey.trim());
      setProbe(got);
      setKind(got.kind);
      setModels(got.models);
      setPicked(got.models.slice(0, 8));
      setName(uniqueName(nameFrom(baseUrl), taken));
    } catch (e) {
      setProbe(null);
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    if (!probe) return;
    setBusy(true);
    setErr('');
    try {
      await port.saveProvider({
        name: name.trim(),
        kind,
        baseUrl: baseUrl.trim(),
        apiKey: apiKey.trim(),
        models: picked,
        default: picked[0] ?? '',
        authHeader: probe.authHeader,
        noProxy: probe.noProxy,
        effort: '',
        vision: probe.vision.filter(m => picked.includes(m)),
      });
      onDone();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  const toggle = (m: string) =>
    setPicked(cur => (cur.includes(m) ? cur.filter(x => x !== m) : [...cur, m]));
  const addModel = (m: string) => {
    setModels(cur => (cur.includes(m) ? cur : [m, ...cur]));
    setPicked(cur => (cur.includes(m) ? cur : [...cur, m]));
  };

  const choices = probe ? (probe.kinds.length > 0 ? probe.kinds : [probe.kind]) : [];

  return (
    <div className="addp">
      <div className="fields">
        <label className="grow full">
          <span>{t('providers.baseUrl')}</span>
          <input
            aria-label={t('providers.baseUrl')}
            value={baseUrl}
            placeholder="https://api.deepseek.com/v1"
            onChange={e => setBaseUrl(e.target.value)}
            spellCheck={false}
          />
        </label>
        <label className="grow full">
          <span>{t('providers.apiKey')}</span>
          <input
            aria-label={t('providers.apiKey')}
            type="password"
            value={apiKey}
            onChange={e => setApiKey(e.target.value)}
            spellCheck={false}
          />
        </label>
      </div>

      <div className="acts">
        <button type="button" className="act primary" onClick={() => void connect()} disabled={busy || baseUrl.trim() === ''}>
          {busy && !probe ? t('providers.connecting') : t('providers.connect')}
        </button>
        <button type="button" onClick={onCancel} disabled={busy}>{t('providers.cancel')}</button>
      </div>

      {err && <div className="find warn"><span>{t('providers.failed')}</span><span className="why">{err}</span></div>}

      {probe && (
        <>
          <p className="acct-note">{t('providers.guesses')}</p>
          <div className="fields">
            <label className="grow">
              <span>{t('providers.name')}</span>
              <input aria-label={t('providers.name')} value={name} onChange={e => setName(e.target.value)} spellCheck={false} />
            </label>
            <label className="grow">
              <span>{t('providers.kind')}</span>
              <select aria-label={t('providers.kind')} value={kind} onChange={e => setKind(e.target.value)}>
                {choices.map(k => <option key={k} value={k}>{KIND_LABEL[k] ?? k}</option>)}
              </select>
            </label>
          </div>
          {probe.ambiguous && <p className="acct-note">{t('providers.ambiguous')}</p>}
          {probe.noProxy && <p className="acct-note">{t('providers.noProxy')}</p>}

          <div className="mlist-wrap">
            <span className="mlb">{t('providers.modelsPicked', { on: picked.length, all: models.length })}</span>
            <ModelChoice models={models} picked={picked} vision={probe.vision} onToggle={toggle} onAdd={addModel} />
          </div>

          <div className="acts">
            <button type="button" className="act primary" onClick={() => void save()} disabled={busy || picked.length === 0 || name.trim() === ''}>
              {busy ? t('providers.saving') : t('providers.add')}
            </button>
          </div>
        </>
      )}
    </div>
  );
}

export default AddProvider;
