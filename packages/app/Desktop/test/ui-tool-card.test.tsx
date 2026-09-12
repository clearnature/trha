// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ToolCard } from '../src/renderer/ui/cards/ToolCard.js';
import type { PortToolEvent } from '../src/renderer/port/types.js';

const ev = (over: Partial<PortToolEvent> = {}): PortToolEvent => ({
  name: 'read_file', args: ['/tmp/a'], status: 'running', ...over,
});

describe('ToolCard', () => {
  it('shows a running tool with icon and details collapsed', () => {
    render(<ToolCard tool={ev()} />);
    expect(screen.getByText('read_file')).toBeTruthy();
    expect(screen.getByText('⏳')).toBeTruthy();
    expect(document.querySelector('[data-status="running"]')).toBeTruthy();
    expect(document.querySelector('.tool-detail')).toBeNull();
  });

  it('walks the status sequence running -> succeeded with duration', () => {
    const { rerender } = render(<ToolCard tool={ev()} />);
    rerender(<ToolCard tool={ev({ status: 'succeeded', durationMs: 42 })} />);
    expect(screen.getByText('✅')).toBeTruthy();
    expect(screen.getByText('42ms')).toBeTruthy();
    expect(document.querySelector('[data-status="succeeded"]')).toBeTruthy();
  });

  it('renders a failed tool with an error', async () => {
    render(<ToolCard tool={ev({ status: 'failed', error: 'boom' })} />);
    expect(screen.getByText('❌')).toBeTruthy();
    await userEvent.click(screen.getByRole('button'));
    expect(screen.getByText('boom')).toBeTruthy();
  });

  it('expands and collapses the detail section', async () => {
    render(<ToolCard tool={ev({ args: ['a', 'b'] })} />);
    const btn = screen.getByRole('button');
    await userEvent.click(btn);
    expect(document.querySelector('.tool-args')?.textContent).toBe('a\nb');
    expect(btn.getAttribute('aria-expanded')).toBe('true');
    await userEvent.click(btn);
    expect(document.querySelector('.tool-detail')).toBeNull();
  });

  it('disables the toggle when there is no detail', () => {
    render(<ToolCard tool={ev({ args: [] })} />);
    expect((screen.getByRole('button') as HTMLButtonElement).disabled).toBe(true);
  });
});
