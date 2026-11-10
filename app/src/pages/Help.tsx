import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { BookOpen, Search } from 'lucide-react';
import { GUIDES, guideBySlug, searchGuides } from '@/help/guides';
import { Markdown } from '@/help/Markdown';
import { Empty, Input, PageHeader, cn } from '@/components/ui';

/** Help: simple guides with numbered steps, searchable, one per task. */
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
          placeholder="Search, for example: cancel, Discord ID, cohort"
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
          Try a shorter word, or open Common questions and fixes.
        </Empty>
      ) : (
        <ol className="grid gap-3 md:grid-cols-2">
          {found.map((g) => (
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
      )}
    </div>
  );
}

function GuideList({ active }: { active?: string }) {
  return (
    <ol className="sticky top-4 space-y-0.5 text-sm">
      {GUIDES.map((g) => (
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
  );
}
