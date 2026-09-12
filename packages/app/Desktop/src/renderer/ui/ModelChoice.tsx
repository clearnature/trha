// ModelChoice: the models a connection offers, as checkboxes plus a field for
// a name the listing did not report.  Mirrors the reference's ModelChoice.

import { useState } from 'react';
import { useT } from './PrefsContext.js';

export interface ModelChoiceProps {
  models: string[];
  picked: string[];
  /** Which of them read images, so the row can say so. */
  vision?: string[];
  onToggle: (model: string) => void;
  onAdd: (model: string) => void;
}

export function ModelChoice({ models, picked, vision = [], onToggle, onAdd }: ModelChoiceProps) {
  const t = useT();
  const [draft, setDraft] = useState('');

  return (
    <div className="mlist">
      {models.map(m => (
        <label key={m} className="mrow">
          <input type="checkbox" checked={picked.includes(m)} onChange={() => onToggle(m)} />
          <span>{m}</span>
          {vision.includes(m) && <span className="mvis">{t('providers.vision')}</span>}
        </label>
      ))}
      {models.length === 0 && <p className="acct-note">{t('providers.noModels')}</p>}
      <div className="madd">
        <input
          aria-label={t('providers.addModel')}
          value={draft}
          onChange={e => setDraft(e.target.value)}
          placeholder={t('providers.addModel')}
          spellCheck={false}
        />
        <button
          type="button"
          disabled={!draft.trim()}
          onClick={() => { onAdd(draft.trim()); setDraft(''); }}
        >
          +
        </button>
      </div>
    </div>
  );
}

export default ModelChoice;
