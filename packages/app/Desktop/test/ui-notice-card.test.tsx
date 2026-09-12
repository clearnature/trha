// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { NoticeCard } from '../src/renderer/ui/cards/NoticeCard.js';

describe('NoticeCard', () => {
  it('renders info notices by default', () => {
    render(<NoticeCard text={'heads up'} />);
    expect(screen.getByText('heads up')).toBeTruthy();
    expect(document.querySelector('[data-tone="info"]')).toBeTruthy();
    expect(screen.getByRole('note')).toBeTruthy();
  });

  it('renders error notices with an error icon', () => {
    render(<NoticeCard text={'failed'} tone="error" />);
    expect(document.querySelector('[data-tone="error"]')).toBeTruthy();
    expect(screen.getByText('❌')).toBeTruthy();
  });

  it('renders the system tone structure', () => {
    const { container } = render(<NoticeCard text={'sys'} tone="system" />);
    const el = container.firstChild as HTMLElement;
    expect(el.className).toBe('notice-card system');
    expect(el.getAttribute('data-card')).toBe('notice');
    expect(el.querySelector('.notice-icon')?.textContent).toBe('⚙️');
    expect(el.querySelector('.notice-text')?.textContent).toBe('sys');
  });
});
