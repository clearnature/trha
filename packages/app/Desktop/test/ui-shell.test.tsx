// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { Shell } from '../src/renderer/ui/Shell.js';
import { SessionProvider, useSession } from '../src/renderer/ui/SessionContext.js';
import { MockPort } from '../src/renderer/port/mock.js';

describe('Shell', () => {
  it('renders the three regions with slot content', () => {
    render(
      <Shell sidebar={<nav aria-label="sessions">SIDE</nav>} statusBar={<div>STATUS</div>}>
        <p>MAIN</p>
      </Shell>,
    );
    expect(screen.getByLabelText('sessions')).toBeTruthy();
    expect(screen.getByRole('main').textContent).toContain('MAIN');
    expect(screen.getByText('STATUS')).toBeTruthy();
    expect(document.querySelector('.app-container')).toBeTruthy();
  });

  it('omits the status region when no statusBar is given', () => {
    render(<Shell sidebar={<nav>S</nav>}><p>M</p></Shell>);
    expect(document.querySelector('.status-region')).toBeNull();
  });
});

function Probe() {
  const sessions = useSession(s => s.sessions);
  const mode = useSession(s => s.selectedMode);
  return <div>probe:{sessions.length}:{mode}</div>;
}

describe('SessionContext', () => {
  it('provides a mock-backed store to descendants', async () => {
    const port = new MockPort();
    render(
      <SessionProvider port={port}>
        <Probe />
      </SessionProvider>,
    );
    expect(screen.getByText(/probe:0:standard/)).toBeTruthy();
  });

  it('falls back to a default store outside a provider', () => {
    render(<Probe />);
    expect(screen.getByText(/probe:/)).toBeTruthy();
  });
});
