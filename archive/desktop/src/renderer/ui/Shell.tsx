// Shell: the top-level three-region layout (sidebar | main | status bar).
// Pure layout with slots so it stays trivially testable and lets App decide
// what fills each region.

import type { ReactNode } from 'react';

export interface ShellProps {
  sidebar: ReactNode;
  children: ReactNode;
  statusBar?: ReactNode;
}

export function Shell({ sidebar, children, statusBar }: ShellProps) {
  return (
    <div className="app-container">
      {sidebar}
      <main className="main-content" role="main">
        {children}
      </main>
      {statusBar ? <div className="status-region">{statusBar}</div> : null}
    </div>
  );
}

export default Shell;
