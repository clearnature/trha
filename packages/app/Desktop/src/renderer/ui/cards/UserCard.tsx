// User message card: plain text with a role label.

export interface UserCardProps {
  text: string;
}

export function UserCard({ text }: UserCardProps) {
  return (
    <div className="message user" data-card="user">
      <div className="message-header"><span className="message-role">user</span></div>
      <div className="message-content">{text}</div>
    </div>
  );
}

export default UserCard;
