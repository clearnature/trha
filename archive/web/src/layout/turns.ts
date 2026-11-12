// Turn grouping for the chat transcript (pure, testable).
//
// A turn starts at a user message; assistant/system/tool rows that follow
// belong to it. Leading non-user rows form their own turn so nothing is lost.

import type { Message } from '../types';

export interface Turn {
  index: number;
  messages: Message[];
}

export function groupTurns(messages: Message[]): Turn[] {
  const turns: Turn[] = [];
  for (const message of messages) {
    const current = turns[turns.length - 1];
    if (message.role === 'user' || current === undefined) {
      turns.push({ index: turns.length, messages: [message] });
    } else {
      current.messages.push(message);
    }
  }
  return turns;
}
