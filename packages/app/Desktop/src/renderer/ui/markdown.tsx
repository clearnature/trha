// Minimal, dependency-free markdown renderer for message cards.  Produces
// React nodes (never raw HTML) so message content cannot inject markup.
// Supported: fenced code blocks, headings (#..###), unordered/ordered lists,
// paragraphs, inline `code` and **bold**.

import type { ReactNode } from 'react';

function renderInline(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const re = /(`[^`]+`|\*\*[^*]+\*\*)/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let k = 0;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) nodes.push(text.slice(last, m.index));
    const tok = m[0];
    if (tok.startsWith('`')) {
      nodes.push(<code key={`c${k++}`} className="md-inline-code">{tok.slice(1, -1)}</code>);
    } else {
      nodes.push(<strong key={`b${k++}`}>{tok.slice(2, -2)}</strong>);
    }
    last = m.index + tok.length;
  }
  if (last < text.length) nodes.push(text.slice(last));
  return nodes;
}

export function Markdown({ text }: { text: string }) {
  const lines = text.split('\n');
  const blocks: ReactNode[] = [];
  let key = 0;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];

    if (line.trimStart().startsWith('```')) {
      const lang = line.trim().slice(3).trim();
      const buf: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trimStart().startsWith('```')) buf.push(lines[i++]);
      if (i < lines.length) i++; // closing fence
      blocks.push(
        <pre key={key++} className="md-code" {...(lang ? { 'data-lang': lang } : {})}>
          <code>{buf.join('\n')}</code>
        </pre>,
      );
      continue;
    }

    const head = /^(#{1,3})\s+(.*)$/.exec(line);
    if (head) {
      const level = head[1].length + 2; // h1..h3 -> h3..h5 (keeps page h1/h2 free)
      const Tag = (`h${level}`) as 'h3' | 'h4' | 'h5';
      blocks.push(<Tag key={key++} className="md-heading" data-level={head[1].length}>{renderInline(head[2])}</Tag>);
      i++;
      continue;
    }

    if (/^\s*[-*]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*[-*]\s+/, ''));
      blocks.push(<ul key={key++} className="md-list">{items.map((it, n) => <li key={n}>{renderInline(it)}</li>)}</ul>);
      continue;
    }

    if (/^\s*\d+\.\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*\d+\.\s+/, ''));
      blocks.push(<ol key={key++} className="md-list">{items.map((it, n) => <li key={n}>{renderInline(it)}</li>)}</ol>);
      continue;
    }

    if (line.trim() === '') { i++; continue; }

    const para: string[] = [];
    while (i < lines.length && lines[i].trim() !== '' && !lines[i].trimStart().startsWith('```')
      && !/^(#{1,3})\s+/.test(lines[i]) && !/^\s*[-*]\s+/.test(lines[i]) && !/^\s*\d+\.\s+/.test(lines[i])) {
      para.push(lines[i++]);
    }
    blocks.push(<p key={key++} className="md-paragraph">{renderInline(para.join('\n'))}</p>);
  }

  return <div className="md-body">{blocks}</div>;
}

export default Markdown;
