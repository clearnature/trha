import React from 'react';
import type { ReactNode } from 'react';

/**
 * Minimal markdown renderer for chat rows: fenced code, headings, quotes,
 * lists, inline code / bold / links. Deliberately small — the reference
 * delegates to a full markdown engine, this only covers what the transcript
 * currently produces, with React escaping all text.
 */

type Block =
  | { kind: 'code'; lang: string; text: string }
  | { kind: 'heading'; level: number; text: string }
  | { kind: 'quote'; text: string }
  | { kind: 'list'; items: string[] }
  | { kind: 'paragraph'; text: string };

const BLOCK_START = /^(#{1,3}\s|>\s?|```|\s*[-*]\s+)/;

export function parseMarkdown(src: string): Block[] {
  const lines = src.split('\n');
  const blocks: Block[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? '';

    if (line.startsWith('```')) {
      const lang = line.slice(3).trim();
      const body: string[] = [];
      i += 1;
      while (i < lines.length && !(lines[i] ?? '').startsWith('```')) {
        body.push(lines[i] ?? '');
        i += 1;
      }
      i += 1; // closing fence (or EOF)
      blocks.push({ kind: 'code', lang, text: body.join('\n') });
      continue;
    }

    const heading = /^(#{1,3})\s+(.*)$/.exec(line);
    if (heading) {
      blocks.push({
        kind: 'heading',
        level: (heading[1] ?? '#').length,
        text: heading[2] ?? '',
      });
      i += 1;
      continue;
    }

    if (/^>\s?/.test(line)) {
      blocks.push({ kind: 'quote', text: line.replace(/^>\s?/, '') });
      i += 1;
      continue;
    }

    if (/^\s*[-*]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i] ?? '')) {
        items.push((lines[i] ?? '').replace(/^\s*[-*]\s+/, ''));
        i += 1;
      }
      blocks.push({ kind: 'list', items });
      continue;
    }

    if (line.trim() === '') {
      i += 1;
      continue;
    }

    const paragraph: string[] = [];
    while (i < lines.length && (lines[i] ?? '').trim() !== '' && !BLOCK_START.test(lines[i] ?? '')) {
      paragraph.push(lines[i] ?? '');
      i += 1;
    }
    blocks.push({ kind: 'paragraph', text: paragraph.join('\n') });
  }

  return blocks;
}

const INLINE = /(`[^`]*`)|(\*\*[^*]+\*\*)|(\[[^\]]+\]\([^)]+\))/g;

export function renderInline(text: string): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let key = 0;
  let match: RegExpExecArray | null;

  INLINE.lastIndex = 0;
  while ((match = INLINE.exec(text)) !== null) {
    if (match.index > last) out.push(text.slice(last, match.index));
    const token = match[0];
    if (token.startsWith('`')) {
      out.push(<code key={key++} className="md-inline-code">{token.slice(1, -1)}</code>);
    } else if (token.startsWith('**')) {
      out.push(<strong key={key++}>{token.slice(2, -2)}</strong>);
    } else {
      const link = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(token);
      const label = link?.[1] ?? token;
      const href = link?.[2] ?? '';
      if (href && /^https?:\/\//.test(href)) {
        out.push(
          <a key={key++} className="md-link" href={href} target="_blank" rel="noreferrer">{label}</a>,
        );
      } else {
        out.push(<span key={key++}>{label}</span>);
      }
    }
    last = match.index + token.length;
  }

  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function Markdown({ text }: { text: string }) {
  const blocks = parseMarkdown(text);
  return (
    <>
      {blocks.map((block, index) => {
        switch (block.kind) {
          case 'code':
            return (
              <pre key={index} className="md-code" data-lang={block.lang || undefined}>
                <code>{block.text}</code>
              </pre>
            );
          case 'heading': {
            const Tag = (`h${block.level}`) as 'h1' | 'h2' | 'h3';
            const cls = block.level === 1 ? 'md-h1' : block.level === 2 ? 'md-h2' : 'md-h3';
            return <Tag key={index} className={cls}>{renderInline(block.text)}</Tag>;
          }
          case 'quote':
            return <blockquote key={index} className="md-quote">{renderInline(block.text)}</blockquote>;
          case 'list':
            return (
              <ul key={index} className="md-ul">
                {block.items.map((item, i) => <li key={i}>{renderInline(item)}</li>)}
              </ul>
            );
          default:
            return <p key={index} className="md-p">{renderInline(block.text)}</p>;
        }
      })}
    </>
  );
}
