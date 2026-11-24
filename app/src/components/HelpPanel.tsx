// The Legend and help side panel (owner, 24 November 2026, decision 344), on the Schedule board and Upcoming classes.
// It slides in over the right side of the page without moving or resizing anything under it; on a phone or tablet it
// is a full height sheet. It opens the first time, then remembers each person's choice on this browser.
import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { Dialog as D } from 'radix-ui';
import { BookOpen, HelpCircle, X } from 'lucide-react';
import { useAuth } from '@/lib/auth';
import { filterLegend, legendItemId, panelKey, readPanelOpen, squashLabel } from '@/lib/helpPanel';
import type { LegendGroup } from '@/pages/boardBadges';
import { Badge, Button, cn, Input, Switch, TabPanel, Tabs } from './ui';

type Tab = 'legend' | 'read' | 'controls';

export type HelpPanelState = {
  page: string;
  open: boolean;
  setOpen: (open: boolean, byPerson?: boolean) => void;
  tab: Tab;
  setTab: (t: Tab) => void;
  focus: string | null;
  setFocus: (label: string | null) => void;
  /** The person asked for it (not the remembered choice on load), so focus moves into the panel. */
  byPerson: boolean;
  /** Open on the Legend tab at this status or badge. */
  openAt: (label: string) => void;
};

const Ctx = createContext<HelpPanelState | null>(null);

/** The panel of the page, for "What is this?" links (null on pages without the panel). */
export const useHelpPanel = (): HelpPanelState | null => useContext(Ctx);

export function HelpPanelProvider({ page, children }: { page: string; children: ReactNode }) {
  const auth = useAuth();
  const key = panelKey(page, auth.account?.member?.email ?? 'me');
  const [open, setOpenState] = useState(() => readPanelOpen(localStorage.getItem(key)));
  const [byPerson, setByPerson] = useState(false);
  const [tab, setTab] = useState<Tab>('legend');
  const [focus, setFocus] = useState<string | null>(null);
  const setOpen = (o: boolean, person = true) => {
    setByPerson(person);
    setOpenState(o);
    localStorage.setItem(key, o ? 'open' : 'closed');
  };
  const value: HelpPanelState = {
    page,
    open,
    setOpen,
    tab,
    setTab,
    focus,
    setFocus,
    byPerson,
    openAt: (label) => {
      setTab('legend');
      setFocus(label);
      setOpen(true);
    },
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

const buttonId = (page: string) => `helpPanelButton_${page}`;
const panelId = (page: string) => `helpPanel_${page}`;

/** The toolbar button that opens and closes the panel. */
export function HelpPanelButton() {
  const p = useHelpPanel();
  if (!p) return null;
  return (
    <Button
      id={buttonId(p.page)}
      size="sm"
      variant={p.open ? 'primary' : 'secondary'}
      aria-expanded={p.open}
      aria-controls={p.open ? panelId(p.page) : undefined}
      onClick={() => p.setOpen(!p.open)}
    >
      <BookOpen className="h-4 w-4" aria-hidden /> Legend and help
    </Button>
  );
}

/** "What is this?" next to a status or badge: opens the panel's Legend at it. Nothing on pages without the panel. */
export function WhatIsThis({ label, onBefore }: { label: string; onBefore?: () => void }) {
  const p = useHelpPanel();
  if (!p) return null;
  return (
    <button
      type="button"
      className="inline-flex rounded p-0.5 align-middle text-muted-foreground hover:bg-muted hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring"
      aria-label={`What is ${label}?`}
      title="What is this?"
      onClick={() => {
        onBefore?.();
        p.openAt(label);
      }}
    >
      <HelpCircle className="h-3.5 w-3.5" aria-hidden />
    </button>
  );
}

/** Below 1024 pixels (phones and tablets) the panel is a full height sheet. */
function useSmallScreen() {
  const [small, setSmall] = useState(() => window.innerWidth < 1024);
  useEffect(() => {
    const on = () => setSmall(window.innerWidth < 1024);
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);
  return small;
}

/** The statuses and badges shown on the page now (each Badge carries data-badge), outside this panel. */
function shownOnPage(): Set<string> {
  return new Set(
    [...(document.querySelector('main')?.querySelectorAll<HTMLElement>('[data-badge]') ?? [])].map(
      (b) => (b.textContent ?? '').trim(),
    ),
  );
}

export function HelpPanel({
  groups,
  readTitle,
  read,
  controlsTitle,
  controls,
  onlyLabel,
}: {
  groups: LegendGroup[];
  readTitle: string;
  read: ReactNode;
  controlsTitle: string;
  controls: ReactNode;
  /** "Only what's on this board" or "Only what's on this page". */
  onlyLabel: string;
}) {
  const p = useHelpPanel();
  const small = useSmallScreen();
  const [query, setQuery] = useState('');
  const [onlyShown, setOnlyShown] = useState(false);
  const [shown, setShown] = useState<Set<string>>(new Set());
  const listRef = useRef<HTMLDivElement>(null);

  // With the switch on, look at the page now and then: the board changes as filters and weeks change.
  useEffect(() => {
    if (!p?.open || !onlyShown) return;
    const t = setInterval(() => setShown(shownOnPage()), 2000);
    return () => clearInterval(t);
  }, [p?.open, onlyShown]);

  // "What is this?": show the item, scroll to it and mark it for a moment.
  const focus = p?.focus ?? null;
  useEffect(() => {
    if (!focus || !p?.open) return;
    const t = setTimeout(() => {
      const el = document.getElementById(legendItemId(focus));
      el?.scrollIntoView({ block: 'center' });
      el?.focus();
    }, 50);
    return () => clearTimeout(t);
  }, [focus, p?.open]);

  if (!p) return null;
  // At a "What is this?" item the whole Legend shows, so the item is there; typing or the switch go back to filtering.
  const list = focus ? groups : filterLegend(groups, query, onlyShown, shown);
  const focused = focus ? squashLabel(focus) : null;

  return (
    <D.Root open={p.open} onOpenChange={(o) => p.setOpen(o)} modal={small}>
      <D.Portal>
        {small && <D.Overlay className="fixed inset-0 z-40 bg-overlay" />}
        <D.Content
          id={panelId(p.page)}
          aria-describedby={undefined}
          // Opened by the remembered choice on load: leave the focus where it is.
          onOpenAutoFocus={(e) => {
            if (!p.byPerson) e.preventDefault();
          }}
          // Focus goes back to the button that opens and closes the panel.
          onCloseAutoFocus={(e) => {
            e.preventDefault();
            document.getElementById(buttonId(p.page))?.focus();
          }}
          // On a wide screen the board stays usable: clicking it does not close the panel.
          onInteractOutside={(e) => {
            if (!small) e.preventDefault();
          }}
          className={cn(
            'fixed flex flex-col bg-card text-card-foreground shadow-lg',
            small
              ? 'inset-0 z-50'
              : 'top-0 right-0 z-30 h-full w-96 max-w-[90vw] border-l border-border',
          )}
        >
          <div className="flex items-center justify-between gap-3 border-b border-border px-4 py-3">
            <D.Title className="text-base font-semibold">Legend and help</D.Title>
            <D.Close asChild>
              {small ? (
                <Button size="sm" variant="secondary">
                  <X className="h-4 w-4" aria-hidden /> Close
                </Button>
              ) : (
                <button
                  type="button"
                  className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
                  aria-label="Close the legend and help"
                >
                  <X className="h-4 w-4" aria-hidden />
                </button>
              )}
            </D.Close>
          </div>
          <div className="min-w-0 flex-1 overflow-y-auto px-4 py-3 text-sm [overflow-wrap:anywhere]">
            <Tabs
              value={p.tab}
              onValueChange={(v) => p.setTab(v as Tab)}
              tabs={[
                { value: 'legend', label: 'Legend' },
                { value: 'read', label: readTitle },
                { value: 'controls', label: controlsTitle },
              ]}
            >
              <TabPanel value="legend">
                <div className="space-y-3">
                  <Input
                    type="search"
                    aria-label="Search the legend"
                    placeholder="Search the legend"
                    value={query}
                    onChange={(e) => {
                      p.setFocus(null);
                      setQuery(e.target.value);
                    }}
                  />
                  <Switch
                    label={onlyLabel}
                    checked={onlyShown}
                    onChange={(c) => {
                      p.setFocus(null);
                      if (c) setShown(shownOnPage());
                      setOnlyShown(c);
                    }}
                  />
                  <div ref={listRef} className="space-y-4">
                    {list.length === 0 && (
                      <p className="text-muted-foreground">
                        {onlyShown && !query
                          ? 'No statuses or badges are shown right now.'
                          : 'Nothing matches. Try another word.'}
                      </p>
                    )}
                    {list.map((g) => (
                      <section key={g.title} aria-label={g.title}>
                        <h3 className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
                          {g.title}
                        </h3>
                        <ul className="space-y-1">
                          {g.items.map((i) => {
                            const Icon = i.icon;
                            return (
                              <li
                                key={i.label}
                                id={legendItemId(i.label)}
                                tabIndex={-1}
                                className={cn(
                                  'rounded-md px-1 py-0.5 outline-none',
                                  focused === squashLabel(i.label) && 'bg-muted ring-2 ring-ring',
                                )}
                              >
                                <Badge tone={i.tone} className="mr-1.5">
                                  {Icon && <Icon className="h-3.5 w-3.5" aria-hidden />}
                                  {i.label}
                                </Badge>
                                <span className="text-muted-foreground">{i.text}</span>
                              </li>
                            );
                          })}
                        </ul>
                      </section>
                    ))}
                  </div>
                </div>
              </TabPanel>
              <TabPanel value="read">
                <div className="space-y-3 leading-relaxed">{read}</div>
              </TabPanel>
              <TabPanel value="controls">
                <div className="space-y-3 leading-relaxed">{controls}</div>
              </TabPanel>
            </Tabs>
          </div>
        </D.Content>
      </D.Portal>
    </D.Root>
  );
}
