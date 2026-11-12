import React, { useState, useRef, useEffect } from 'react';
import { useAppStore } from '../stores/appStore';

export function ChatView() {
  const { currentSession, sendMessage, agentState, createSession } = useAppStore();
  const [input, setInput] = useState('');
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  useEffect(() => {
    scrollToBottom();
  }, [currentSession?.messages]);

  const handleSend = async () => {
    if (!input.trim()) return;
    if (!currentSession) {
      await createSession();
    }
    const msg = input;
    setInput('');
    await sendMessage(msg);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  if (!currentSession) {
    return (
      <div className="chat-view">
        <div className="chat-empty">
          <h2>Welcome to trha</h2>
          <p>Create a new session to get started.</p>
          <button onClick={createSession} className="new-session-btn">
            + New Session
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="chat-view">
      <div className="chat-header">
        <h3>{currentSession.title}</h3>
        <div className={`agent-status ${agentState.status}`}>
          {agentState.status === 'processing' ? '⏳ Processing...' :
           agentState.status === 'error' ? `❌ ${agentState.message}` :
           '✅ Ready'}
        </div>
      </div>

      <div className="messages-container">
        {currentSession.messages.map((msg, i) => (
          <div key={i} className={`message ${msg.role}`}>
            <div className="message-header">
              <span className="message-role">{msg.role}</span>
            </div>
            <div className="message-content">{msg.content}</div>
          </div>
        ))}
        {currentSession.messages.length === 0 && (
          <div className="messages-empty">
            Send a message to start the conversation.
          </div>
        )}
        <div ref={messagesEndRef} />
      </div>

      <div className="input-container">
        <textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Type a message... (Enter to send, Shift+Enter for newline)"
          rows={3}
          disabled={agentState.status === 'processing'}
        />
        <button
          onClick={handleSend}
          disabled={!input.trim() || agentState.status === 'processing'}
        >
          Send
        </button>
      </div>
    </div>
  );
}
