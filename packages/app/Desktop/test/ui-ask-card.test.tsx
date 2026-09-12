// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { AskCard } from '../src/renderer/ui/cards/AskCard.js';

describe('AskCard', () => {
  it('renders nothing while the ask capability is unavailable (default)', () => {
    const { container } = render(<AskCard question="Pick one" options={['a', 'b']} />);
    expect(container.firstChild).toBeNull();
  });

  it('renders a disabled prompt when explicitly available', () => {
    render(<AskCard question="Pick one" options={['a', 'b']} available />);
    expect(screen.getByText('Pick one')).toBeTruthy();
    const buttons = screen.getAllByRole('button');
    expect(buttons.map(b => (b as HTMLButtonElement).disabled)).toEqual([true, true]);
    expect(document.querySelector('[data-card="ask"]')?.getAttribute('aria-disabled')).toBe('true');
    expect(screen.getByText('暂不支持回答。')).toBeTruthy();
  });
});
