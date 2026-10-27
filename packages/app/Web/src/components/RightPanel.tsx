import React from 'react';
import { useAppStore } from '../stores/appStore';

/** Right column occupant (dsh rightbar): file preview with a header and a
 * close control. The frame owns the column width; this only fills it. */
export function RightPanel() {
  const { rightPanel, closeRightPanel } = useAppStore();
  if (!rightPanel) return null;

  return (
    <aside className="rightbar" aria-label="Right panel">
      <header className="rightbar-header">
        <span className="rightbar-title" title={rightPanel.path}>{rightPanel.path}</span>
        <button className="ghost-btn" title="Close panel" onClick={closeRightPanel}>×</button>
      </header>
      <pre className="rightbar-body">{rightPanel.text}</pre>
    </aside>
  );
}
