// The in app Help guides. Each guide is a Markdown file in this folder that starts with a few
// "key: value" lines (title, summary, order), then a line with three dashes, then the guide.

export type Guide = {
  slug: string;
  title: string;
  summary: string;
  order: number;
  body: string;
};

const files = import.meta.glob('./*.md', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

function parse(path: string, raw: string): Guide {
  const slug = path.replace(/^\.\//, '').replace(/\.md$/, '');
  const [head, ...rest] = raw.replace(/\r\n/g, '\n').split('\n---\n');
  const meta: Record<string, string> = {};
  for (const line of (head ?? '').split('\n')) {
    const i = line.indexOf(':');
    if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return {
    slug,
    title: meta.title ?? slug,
    summary: meta.summary ?? '',
    order: Number(meta.order ?? 99),
    body: rest.join('\n---\n').trim(),
  };
}

export const GUIDES: Guide[] = Object.entries(files)
  .map(([p, raw]) => parse(p, raw))
  .sort((a, b) => a.order - b.order);

export const guideBySlug = (slug: string | undefined) => GUIDES.find((g) => g.slug === slug);

/** Search: every word must appear in the title, the summary or the text. */
export function searchGuides(q: string): Guide[] {
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return GUIDES;
  return GUIDES.filter((g) => {
    const text = `${g.title} ${g.summary} ${g.body}`.toLowerCase();
    return words.every((w) => text.includes(w));
  });
}
