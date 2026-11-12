// Notice card: system, error or informational text that is not a chat turn.

export type NoticeTone = 'error' | 'info' | 'system';

export interface NoticeCardProps {
  text: string;
  tone?: NoticeTone;
}

const TONE_ICON: Record<NoticeTone, string> = { error: '❌', info: 'ℹ️', system: '⚙️' };

export function NoticeCard({ text, tone = 'info' }: NoticeCardProps) {
  return (
    <div className={`notice-card ${tone}`} data-card="notice" data-tone={tone} role="note">
      <span className="notice-icon" aria-hidden="true">{TONE_ICON[tone]}</span>
      <span className="notice-text">{text}</span>
    </div>
  );
}

export default NoticeCard;
