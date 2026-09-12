// Ask card (placeholder): the kernel does not yet expose an `ask` capability,
// so this component renders a disabled prompt.  It is hidden entirely unless
// `available` is set, so it never appears in normal sessions today.

export interface AskCardProps {
  question: string;
  options?: string[];
  /** Whether the ask capability exists yet (false today -> render nothing). */
  available?: boolean;
}

import { useT } from '../PrefsContext.js';

export function AskCard({ question, options = [], available = false }: AskCardProps) {
  const t = useT();
  if (!available) return null;
  return (
    <div className="ask-card disabled" data-card="ask" aria-disabled="true">
      <div className="ask-header">Question</div>
      <div className="ask-question">{question}</div>
      <div className="ask-options">
        {options.map(opt => (
          <button key={opt} type="button" className="ask-option" disabled>{opt}</button>
        ))}
      </div>
      <div className="ask-note">{t('ask.note')}</div>
    </div>
  );
}

export default AskCard;
