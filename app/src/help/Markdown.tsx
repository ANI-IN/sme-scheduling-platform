import { Fragment, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { Notice } from '@/components/ui';

/** Bold, links and code inside a line. Links that start with "/" stay inside the app. */
function inline(text: string, key = 0): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /\*\*(.+?)\*\*|\[([^\]]+)\]\(([^)]+)\)|`([^`]+)`/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let i = key;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    if (m[1]) out.push(<strong key={i++}>{m[1]}</strong>);
    else if (m[2] && m[3])
      out.push(
        m[3].startsWith('/') ? (
          <Link key={i++} to={m[3]} className="font-medium text-link underline underline-offset-2">
            {m[2]}
          </Link>
        ) : (
          <a
            key={i++}
            href={m[3]}
            target="_blank"
            rel="noreferrer"
            className="font-medium text-link underline underline-offset-2"
          >
            {m[2]}
          </a>
        ),
      );
    else if (m[4])
      out.push(
        <code key={i++} className="rounded bg-muted px-1 py-0.5 text-[0.9em]">
          {m[4]}
        </code>,
      );
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

/** A small Markdown renderer for the Help guides: headings, paragraphs, lists, notes and pictures. */
export function Markdown({ source }: { source: string }) {
  const blocks = source.replace(/\r\n/g, '\n').split(/\n{2,}/);
  return (
    <div className="space-y-4 text-[15px] leading-relaxed">
      {blocks.map((b, bi) => {
        const lines = b.split('\n');
        const first = lines[0] ?? '';
        if (first.startsWith('### '))
          return (
            <h3 key={bi} className="pt-2 text-base font-semibold">
              {inline(first.slice(4))}
            </h3>
          );
        if (first.startsWith('## '))
          return (
            <h2 key={bi} className="pt-3 text-lg font-semibold">
              {inline(first.slice(3))}
            </h2>
          );
        const img = first.match(/^!\[([^\]]*)\]\(([^)]+)\)$/);
        if (img && lines.length === 1)
          return (
            <figure key={bi} className="space-y-1">
              <img
                src={img[2]}
                alt={img[1]}
                loading="lazy"
                className="w-full rounded-lg border border-border shadow-sm"
              />
              <figcaption className="text-xs text-muted-foreground">{img[1]}</figcaption>
            </figure>
          );
        if (lines.every((l) => /^\d+\.\s/.test(l)))
          return (
            <ol key={bi} className="list-decimal space-y-1.5 pl-6">
              {lines.map((l, i) => (
                <li key={i}>{inline(l.replace(/^\d+\.\s/, ''))}</li>
              ))}
            </ol>
          );
        if (lines.every((l) => l.startsWith('- ')))
          return (
            <ul key={bi} className="list-disc space-y-1.5 pl-6">
              {lines.map((l, i) => (
                <li key={i}>{inline(l.slice(2))}</li>
              ))}
            </ul>
          );
        if (lines.every((l) => l.startsWith('> ')))
          return (
            <Notice key={bi}>
              {lines.map((l, i) => (
                <Fragment key={i}>
                  {i > 0 && ' '}
                  {inline(l.slice(2))}
                </Fragment>
              ))}
            </Notice>
          );
        return <p key={bi}>{inline(lines.join(' '))}</p>;
      })}
    </div>
  );
}
