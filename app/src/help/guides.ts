// The in app Help guides. Each guide is a Markdown file in this folder that starts with a few
// "key: value" lines (title, summary, order, group, keywords), then a line with three dashes, then the guide.

export type Guide = {
  slug: string;
  title: string;
  summary: string;
  order: number;
  /** The heading the guide is listed under on the Help page (one of GUIDE_GROUPS). */
  group: string;
  /** Extra words people may search for, such as "login" for signing in. */
  keywords: string[];
  body: string;
};

/** The groups of the Help page, in the order they are shown. */
export const GUIDE_GROUPS = [
  'Start here',
  'Setup',
  'Daily work',
  'Fixing problems',
  'Messages and settings',
  'Reference',
] as const;

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
    group: meta.group ?? 'Reference',
    keywords: (meta.keywords ?? '')
      .split(',')
      .map((k) => k.trim())
      .filter(Boolean),
    body: rest.join('\n---\n').trim(),
  };
}

export const GUIDES: Guide[] = Object.entries(files)
  .map(([p, raw]) => parse(p, raw))
  .sort((a, b) => a.order - b.order);

export const guideBySlug = (slug: string | undefined) => GUIDES.find((g) => g.slug === slug);

/** Search: every word must appear in the title, the summary, the keywords or the text. */
export function searchGuides(q: string, guides: Guide[] = GUIDES): Guide[] {
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return guides;
  return guides.filter((g) => {
    const text = `${g.title} ${g.summary} ${g.keywords.join(' ')} ${g.body}`.toLowerCase();
    return words.every((w) => text.includes(w));
  });
}

/** The guides under each group of the Help page, in order; groups without a guide are left out. */
export function groupGuides(guides: Guide[]): { group: string; guides: Guide[] }[] {
  const names: string[] = [...GUIDE_GROUPS];
  for (const g of guides) if (!names.includes(g.group)) names.push(g.group);
  return names
    .map((group) => ({ group, guides: guides.filter((g) => g.group === group) }))
    .filter((x) => x.guides.length > 0);
}
