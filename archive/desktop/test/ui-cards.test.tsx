// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { Markdown } from '../src/renderer/ui/markdown.js';
import { UserCard } from '../src/renderer/ui/cards/UserCard.js';
import { SayCard } from '../src/renderer/ui/cards/SayCard.js';

describe('Markdown', () => {
  it('renders headings, lists and paragraphs', () => {
    render(<Markdown text={'# Title\n\npara one\n- a\n- b\n\n1. x\n2. y'} />);
    expect(screen.getByText('Title').tagName).toBe('H3');
    expect(screen.getByText('para one')).toBeTruthy();
    expect(screen.getByText('a').tagName).toBe('LI');
    expect(screen.getAllByRole('list').length).toBe(2);
  });

  it('renders fenced code blocks with language', () => {
    render(<Markdown text={'```ts\nconst a = 1;\n```'} />);
    const pre = document.querySelector('pre.md-code');
    expect(pre?.getAttribute('data-lang')).toBe('ts');
    expect(pre?.textContent).toContain('const a = 1;');
  });

  it('renders inline code and bold', () => {
    render(<Markdown text={'use `npm i` and **now**'} />);
    expect(screen.getByText('npm i').tagName).toBe('CODE');
    expect(screen.getByText('now').tagName).toBe('STRONG');
  });

  it('does not interpret embedded HTML', () => {
    render(<Markdown text={'<img src=x onerror=alert(1)>'} />);
    expect(document.querySelector('.md-body img')).toBeNull();
    expect(screen.getByText(/<img src=x/)).toBeTruthy();
  });
});

describe('UserCard', () => {
  it('renders the plain text with a role label', () => {
    render(<UserCard text={'hello **not bold**'} />);
    expect(screen.getByText('hello **not bold**')).toBeTruthy();
    expect(document.querySelector('[data-card="user"]')).toBeTruthy();
  });
});

describe('SayCard', () => {
  it('renders markdown content', () => {
    render(<SayCard text={'# Hi\nthere'} />);
    expect(screen.getByText('Hi').tagName).toBe('H3');
    expect(screen.getByText('there')).toBeTruthy();
  });

  it('shows a streaming cursor only while streaming', () => {
    const { unmount } = render(<SayCard text={'x'} streaming />);
    expect(document.querySelector('.md-cursor')).toBeTruthy();
    unmount();
    render(<SayCard text={'x'} />);
    expect(document.querySelector('.md-cursor')).toBeNull();
  });
});
