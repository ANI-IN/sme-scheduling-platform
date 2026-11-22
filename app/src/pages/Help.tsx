import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { BookOpen, Search } from 'lucide-react';
import { GUIDES, groupGuides, guideBySlug, searchGuides } from '@/help/guides';
import { Markdown } from '@/help/Markdown';
import { Empty, Input, PageHeader, cn } from '@/components/ui';

const slugOf = (group: string) => group.toLowerCase().replace(/[^a-z]+/g, '_');

/** Help: simple guides with numbered steps, searchable, one per task, listed in groups. */
export default function Help() {
  const { slug } = useParams();
  const [q, setQ] = useState('');
  const guide = guideBySlug(slug);
  const found = searchGuides(q);

  if (slug && guide)
    return (
      <div className="grid gap-8 lg:grid-cols-[16rem_1fr]">
        <nav aria-label="Guides" className="hidden lg:block">
          <GuideList active={slug} />
        </nav>
        <article className="max-w-3xl">
          <PageHeader
            title={guide.title}
            description={guide.summary}
            breadcrumbs={[{ label: 'Help', to: '/help' }, { label: guide.title }]}
          />
          <Markdown source={guide.body} />
          <div className="mt-10 border-t border-border pt-4 text-sm">
            <Link to="/help" className="font-medium text-link hover:underline">
              All help guides
            </Link>
          </div>
        </article>
      </div>
    );

  return (
    <div>
      <PageHeader
        title="Help"
        description="Short guides with numbered steps. Use the question mark next to a page title to open the guide for that page."
      />
      <label className="relative mb-5 block max-w-lg">
        <Search
          className="pointer-events-none absolute top-1/2 left-2.5 h-4 w-4 -translate-y-1/2 text-muted-foreground"
          aria-hidden
        />
        <Input
          aria-label="Search the help"
          placeholder="Search, for example: clash, beta list, break, Discord server"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          className="pl-8"
        />
      </label>
      {slug && !guide && (
        <p className="mb-4 text-sm text-muted-foreground">
          That guide was not found. Here are all guides.
        </p>
      )}
      {found.length === 0 ? (
        <Empty title="Nothing found" icon={<BookOpen className="h-5 w-5" />}>
          Try a shorter word, or open{' '}
          <Link to="/help/troubleshooting" className="font-medium text-link hover:underline">
            Troubleshooting
          </Link>
          .
        </Empty>
      ) : (
        <div className="space-y-6">
          {groupGuides(found).map(({ group, guides }) => (
            <section key={group} aria-labelledby={`help-group-${slugOf(group)}`}>
              <h2 id={`help-group-${slugOf(group)}`} className="mb-2 text-base font-semibold">
                {group}
              </h2>
              <ol className="grid gap-3 md:grid-cols-2">
                {guides.map((g) => (
                  <li key={g.slug}>
                    <Link
                      to={`/help/${g.slug}`}
                      className="block h-full rounded-lg border border-border bg-card p-4 shadow-sm hover:border-primary/60 hover:bg-muted/40"
                    >
                      <div className="font-semibold">
                        {g.order}. {g.title}
                      </div>
                      <div className="mt-1 text-sm text-muted-foreground">{g.summary}</div>
                    </Link>
                  </li>
                ))}
              </ol>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}

/** Every guide, by group. The group names are not headings, so the guide's title stays the first heading. */
function GuideList({ active }: { active?: string }) {
  return (
    <div className="sticky top-4 space-y-3 text-sm">
      {groupGuides(GUIDES).map(({ group, guides }) => (
        <div key={group}>
          <div
            id={`help-nav-${slugOf(group)}`}
            className="px-2 pb-1 text-xs font-semibold tracking-wide text-muted-foreground uppercase"
          >
            {group}
          </div>
          <ol className="space-y-0.5" aria-labelledby={`help-nav-${slugOf(group)}`}>
            {guides.map((g) => (
              <li key={g.slug}>
                <Link
                  to={`/help/${g.slug}`}
                  aria-current={g.slug === active ? 'page' : undefined}
                  className={cn(
                    'block rounded-md px-2 py-1.5 hover:bg-muted',
                    g.slug === active
                      ? 'bg-primary-soft font-medium text-foreground'
                      : 'text-muted-foreground',
                  )}
                >
                  {g.order}. {g.title}
                </Link>
              </li>
            ))}
          </ol>
        </div>
      ))}
    </div>
  );
}
