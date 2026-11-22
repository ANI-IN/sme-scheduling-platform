// The Schedule board (Release 3, M12a, decisions 295 and 305): every cohort's class weeks in one grid, by cohort or by
// instructor, or as a list. Each cell shows its main status (colour, icon and word together), its instructor and its
// exception badges; Needs a decision counts every problem and filters by it. A cell opens the class drawer, which
// holds every action. All data and every check come from the database (schedule_board).
import { useMemo, useState, useSyncExternalStore } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DateTime } from 'luxon';
import { Download, ChevronDown, ChevronRight, Pause } from 'lucide-react';
import { rpc } from '@/lib/rpc';
import { downloadCsv, toCsv } from '@/lib/csv';
import { useDomain } from '@/lib/domain';
import { useAuth } from '@/lib/auth';
import { useInstructors, useWeeks } from '@/lib/data';
import { RegionBadge } from '@/components/ClassTime';
import {
  Badge,
  Button,
  Checkbox,
  ErrorText,
  PageHeader,
  Select,
  SkeletonRows,
  Toolbar,
  cn,
} from '@/components/ui';
import { ClassDrawer } from './ClassDrawer';
import { AddBreakDialog, AddCohortHolidayDialog } from './setup/breakParts';
import { MergeCohortsDialog } from './setup/mergeParts';
import { ShareDialog } from './sharedParts';
import { BulkChangeDialog } from './boardBulk';
import {
  COHORT_BADGE,
  MARK,
  SERIOUS,
  STATUS,
  badgeLabel,
  confirmedCount,
  decisionLabel,
  legendGroups,
  moreBadges,
  type Status,
} from './boardBadges';

/** The group of cohorts that follow no standard schedule. */
export const NO_STANDARD_GROUP = 'No standard schedule';

type Problem = { code: string; level: 'Block' | 'Warning' | 'Information'; text: string };
type Cell = {
  id: string;
  cohort_id: string | null;
  cohort: string | null;
  module: string;
  week_start_date: string;
  past: boolean;
  status: Status;
  instructor: string | null;
  badges: string[];
  problems: Problem[];
  shared_with: string | null;
  guests: number;
  standard_position: number | null;
  customized: boolean;
};
type CohortCol = {
  id: string;
  name: string;
  region: string;
  standard: string | null;
  mode: 'Standard' | 'Custom' | 'Fully custom';
  changes: number;
  merged_into: string | null;
  merged_from: string | null;
  merged_into_name: string | null;
  archived: boolean;
};
type BreakRow = {
  id: string;
  cohort_id: string;
  program_break_id: string | null;
  starts_on: string;
  weeks: number;
  reason: string;
};
type Board = {
  now: string;
  weeks: Cell[];
  cohorts: CohortCol[];
  breaks: BreakRow[];
  decisions: Record<string, number>;
};
function StatusChip({ status }: { status: Status }) {
  const s = STATUS[status];
  const Icon = s.icon;
  return (
    <Badge tone={s.tone} className={status === 'Cancelled' ? 'line-through' : undefined}>
      <Icon className="h-3.5 w-3.5" aria-hidden /> {s.word}
    </Badge>
  );
}

type Prefs = {
  view: 'cohort' | 'instructor' | 'list';
  weeks: number;
  onlyProblems: boolean;
  compare?: boolean;
};

/** Filters remembered per person on this device. */
function usePrefs(key: string) {
  const initial = (): Prefs => {
    try {
      const v = JSON.parse(localStorage.getItem(key) ?? '') as Prefs;
      if (v && v.view) return v;
    } catch {
      /* first visit */
    }
    // On a phone the List view comes first.
    return { view: window.innerWidth < 768 ? 'list' : 'cohort', weeks: 8, onlyProblems: false };
  };
  const [prefs, setPrefs] = useState<Prefs>(initial);
  const update = (p: Partial<Prefs>) => {
    const next = { ...prefs, ...p };
    setPrefs(next);
    localStorage.setItem(key, JSON.stringify(next));
  };
  return [prefs, update] as const;
}

const sunday = (d: DateTime) => d.minus({ days: d.weekday % 7 }).startOf('day');

export default function Board() {
  const { domain } = useDomain();
  const auth = useAuth();
  const [prefs, setPrefs] = usePrefs(`board:${auth.account?.member?.email ?? 'me'}`);
  // The board opens at this week, so no empty past weeks come first; Earlier shows the weeks before.
  const [start, setStart] = useState(() => sunday(DateTime.now()));
  const [decision, setDecision] = useState<string | null>(null);
  const [openWeek, setOpenWeek] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [menu, setMenu] = useState<{ kind: 'break' | 'holiday' | 'merge'; cohort?: string } | null>(
    null,
  );
  const [legend, setLegend] = useState(false);
  // Bulk actions (M12b, decision 314): select several class weeks, then one action with one combined preview.
  const [selecting, setSelecting] = useState(false);
  const [selected, setSelected] = useState<string[]>([]);
  const [bulk, setBulk] = useState<'move' | 'cancel' | 'break' | 'share' | null>(null);
  const toggle = (id: string) =>
    setSelected((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]));
  const from = start.toISODate()!;
  const to = start.plus({ weeks: prefs.weeks }).minus({ days: 1 }).toISODate()!;
  const board = useQuery({
    queryKey: ['module_week', 'board', domain?.id, from, to],
    enabled: !!domain,
    queryFn: async () =>
      (await rpc('schedule_board', {
        p_domain_id: domain!.id,
        p_from: from,
        p_to: to,
      })) as unknown as Board,
  });
  const weeks = useWeeks(domain?.id);
  const instructors = useInstructors();
  const names = useMemo(
    () => new Map((instructors.data ?? []).map((i) => [i.id, i.full_name])),
    [instructors.data],
  );
  const b = board.data;
  const cells = useMemo(() => {
    const all = b?.weeks ?? [];
    return all.filter(
      (c) =>
        (!prefs.onlyProblems ||
          c.problems.some((p) => p.level !== 'Information') ||
          c.status === 'Needs instructor' ||
          c.status === 'Proposed time') &&
        (!decision ||
          c.badges.includes(decision) ||
          c.problems.some((p) => p.code === decision) ||
          c.status.toLowerCase().replace(/ /g, '_') === decision),
    );
  }, [b, prefs.onlyProblems, decision]);
  const rows = useMemo(
    () => Array.from({ length: prefs.weeks }, (_, i) => start.plus({ weeks: i })),
    [start, prefs.weeks],
  );
  const thisWeek = sunday(DateTime.now()).toISODate();
  const open = (weeks.data ?? []).find((w) => w.id === openWeek);

  const cellsAt = (cohort: string, row: DateTime) =>
    cells.filter(
      (c) =>
        c.cohort_id === cohort &&
        DateTime.fromISO(c.week_start_date) >= row &&
        DateTime.fromISO(c.week_start_date) < row.plus({ weeks: 1 }),
    );
  const breakAt = (cohort: string, row: DateTime) =>
    (b?.breaks ?? []).find(
      (x) =>
        x.cohort_id === cohort &&
        DateTime.fromISO(x.starts_on) < row.plus({ weeks: 1 }) &&
        DateTime.fromISO(x.starts_on).plus({ weeks: x.weeks }) > row,
    );
  // Tracks: the cohorts of one standard schedule, which can be folded away together.
  const tracks = useMemo(() => {
    const m = new Map<string, CohortCol[]>();
    for (const c of b?.cohorts ?? []) {
      const k = c.standard ?? NO_STANDARD_GROUP;
      m.set(k, [...(m.get(k) ?? []), c]);
    }
    return [...m.entries()];
  }, [b]);
  const visibleCohorts = tracks.flatMap(([t, cs]) => (collapsed.has(t) ? [] : cs));
  const health = (cohort: string) => {
    const mine = (b?.weeks ?? []).filter(
      (c) => c.cohort_id === cohort && !c.past && c.status !== 'Cancelled',
    );
    return { confirmed: mine.filter((c) => c.status === 'Confirmed').length, total: mine.length };
  };

  const CellButton = ({ c }: { c: Cell }) => {
    const shown = c.badges.filter((x) => badgeLabel(x));
    const differs = prefs.compare && (c.customized || c.standard_position === null);
    const body = (
      <>
        <div className="font-medium">
          {!c.past && <span className="sr-only">Open </span>}
          {c.module}
          {!c.past && (
            <span className="sr-only">
              {` for ${c.cohort ?? 'no cohort'}, week of ${DateTime.fromISO(c.week_start_date).toFormat('LLL d')}:`}
            </span>
          )}
        </div>
        <StatusChip status={c.status} />
        {differs && (
          <div className="mt-1">
            <Badge tone="warning">
              {c.standard_position === null ? MARK.notInStandard : MARK.differs}
            </Badge>
          </div>
        )}
        {c.instructor && (
          <div className="mt-0.5 truncate text-xs text-muted-foreground">
            {c.status === 'Not asked yet' ? `Primary: ${c.instructor}` : c.instructor}
          </div>
        )}
        {shown.length > 0 && (
          <div className="mt-1 flex flex-wrap gap-1">
            {shown.slice(0, 3).map((x) => (
              <Badge key={x} tone={SERIOUS.has(x) ? 'danger' : 'warning'}>
                {badgeLabel(x)}
              </Badge>
            ))}
            {shown.length > 3 && <Badge>{moreBadges(shown.length - 3)}</Badge>}
          </div>
        )}
      </>
    );
    if (c.past)
      return (
        <div className="rounded-md border border-border bg-muted/40 p-2 text-left text-sm opacity-80">
          {body}
        </div>
      );
    const picked = selecting && selected.includes(c.id);
    return (
      <button
        type="button"
        onClick={() => (selecting ? toggle(c.id) : setOpenWeek(c.id))}
        aria-pressed={selecting ? picked : undefined}
        className={cn(
          'w-full rounded-md border bg-card p-2 text-left text-sm hover:bg-muted/60 focus-visible:outline-2 focus-visible:outline-ring',
          differs ? 'border-warning-strong' : 'border-border',
          picked && 'ring-2 ring-ring',
        )}
      >
        {selecting && <span className="sr-only">{picked ? 'Selected: ' : 'Select: '}</span>}
        {body}
      </button>
    );
  };

  const decisions = Object.entries(b?.decisions ?? {}).filter(([, n]) => n > 0);

  // What is shown, as a spreadsheet, and the download in Activity history like every other one.
  const download = () => {
    void rpc('log_export', {
      p_what: 'Schedule board',
      p_rows: cells.length,
      p_filters: { from, to, only_problems: prefs.onlyProblems, decision },
      p_domain_id: domain?.id,
    }).catch(() => {});
    downloadCsv(
      `schedule_board_${domain?.name}_${from}.csv`,
      toCsv(
        cells.map((c) => ({
          week_of: c.week_start_date,
          cohort: c.cohort ?? '',
          module: c.module,
          status: STATUS[c.status].word,
          instructor: c.instructor ?? '',
          badges: c.badges.map((x) => badgeLabel(x) ?? x).join('; '),
          problems: c.problems.map((p) => `${p.level}: ${p.text}`).join(' | '),
          follows_standard: c.standard_position === null ? 'no' : c.customized ? 'changed' : 'yes',
        })),
      ),
    );
  };

  return (
    <div>
      <PageHeader
        title="Schedule board"
        description="Every cohort's class weeks at a glance. Each cell shows its status, its instructor and anything that needs a decision. Select a cell for details and actions."
      />
      <Toolbar>
        <div className="flex flex-wrap items-center gap-2" role="group" aria-label="View">
          {(
            [
              ['cohort', 'By cohort'],
              ['instructor', 'By instructor'],
              ['list', 'List'],
            ] as const
          ).map(([v, label]) => (
            <Button
              key={v}
              size="sm"
              variant={prefs.view === v ? 'primary' : 'outline'}
              aria-pressed={prefs.view === v}
              onClick={() => setPrefs({ view: v })}
            >
              {label}
            </Button>
          ))}
        </div>
        <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Weeks shown">
          <Button
            size="sm"
            variant="outline"
            onClick={() => setStart(start.minus({ weeks: prefs.weeks }))}
          >
            Earlier
          </Button>
          <Button size="sm" variant="outline" onClick={() => setStart(sunday(DateTime.now()))}>
            This week
          </Button>
          <Button
            size="sm"
            variant="outline"
            onClick={() => setStart(start.plus({ weeks: prefs.weeks }))}
          >
            Later
          </Button>
          <Select
            aria-label="Number of weeks"
            value={String(prefs.weeks)}
            onChange={(e) => setPrefs({ weeks: Number(e.target.value) })}
            className="h-9 w-32"
          >
            {[4, 8, 12, 26].map((n) => (
              <option key={n} value={n}>
                {n} weeks
              </option>
            ))}
          </Select>
        </div>
        <Checkbox
          label="Only problems"
          checked={prefs.onlyProblems}
          onChange={(v) => setPrefs({ onlyProblems: v })}
        />
        <Checkbox
          label="Compare to standard"
          checked={!!prefs.compare}
          onChange={(v) => setPrefs({ compare: v })}
        />
        <Button size="sm" variant="ghost" aria-expanded={legend} onClick={() => setLegend(!legend)}>
          Legend
        </Button>
        <Button size="sm" variant="secondary" disabled={cells.length === 0} onClick={download}>
          <Download className="h-4 w-4" aria-hidden /> Download as spreadsheet
        </Button>
        <Button
          size="sm"
          variant={selecting ? 'primary' : 'secondary'}
          aria-pressed={selecting}
          onClick={() => {
            setSelecting(!selecting);
            setSelected([]);
          }}
        >
          {selecting ? 'Done selecting' : 'Select class weeks'}
        </Button>
      </Toolbar>

      {selecting && (
        <section
          aria-label="Selected class weeks"
          className="mb-4 flex flex-wrap items-center gap-2 rounded-md border border-border bg-muted/40 p-3 text-sm"
        >
          <span className="font-medium">
            {selected.length === 0
              ? 'Click class weeks to select them.'
              : `${selected.length} class week${selected.length === 1 ? '' : 's'} selected`}
          </span>
          <Button
            size="sm"
            variant="secondary"
            disabled={selected.length === 0}
            onClick={() => setBulk('break')}
          >
            Add a break
          </Button>
          <Button
            size="sm"
            variant="secondary"
            disabled={selected.length === 0}
            onClick={() => setBulk('move')}
          >
            Move
          </Button>
          <Button
            size="sm"
            variant="secondary"
            disabled={selected.length === 0}
            onClick={() => setBulk('cancel')}
          >
            Cancel
          </Button>
          <Button
            size="sm"
            variant="secondary"
            disabled={selected.length < 2}
            onClick={() => setBulk('share')}
          >
            Make one shared class
          </Button>
          {selected.length > 0 && (
            <Button size="sm" variant="ghost" onClick={() => setSelected([])}>
              Clear selection
            </Button>
          )}
        </section>
      )}

      {legend && <Legend />}

      <section aria-label="Needs a decision" className="mb-4">
        <h2 className="mb-2 text-sm font-semibold">Needs a decision</h2>
        {decisions.length === 0 ? (
          <p className="text-sm text-muted-foreground">Nothing needs a decision in these weeks.</p>
        ) : (
          <div className="flex flex-wrap gap-2">
            {decisions.map(([k, n]) => (
              <Button
                key={k}
                size="sm"
                variant={decision === k ? 'primary' : 'outline'}
                aria-pressed={decision === k}
                onClick={() => setDecision(decision === k ? null : k)}
              >
                {decisionLabel(k)}: {n}
              </Button>
            ))}
            {decision && (
              <Button size="sm" variant="ghost" onClick={() => setDecision(null)}>
                Show everything
              </Button>
            )}
          </div>
        )}
      </section>

      {board.isLoading ? (
        <SkeletonRows rows={6} />
      ) : board.error ? (
        <ErrorText error={board.error} />
      ) : !b || b.weeks.length === 0 ? (
        <p className="text-sm text-muted-foreground">No class weeks in these weeks.</p>
      ) : prefs.view === 'list' ? (
        <div className="overflow-x-auto rounded-md border border-border">
          <table className="w-full text-sm">
            <thead className="sticky top-0 bg-muted/60">
              <tr>
                <th className="px-3 py-2 text-left">Week of</th>
                <th className="px-3 py-2 text-left">Cohort</th>
                <th className="px-3 py-2 text-left">Class week</th>
              </tr>
            </thead>
            <tbody>
              {cells.map((c) => (
                <tr key={c.id} className="border-t border-border align-top">
                  <td className="px-3 py-2 whitespace-nowrap">
                    {DateTime.fromISO(c.week_start_date).toFormat('LLL d')}
                  </td>
                  <td className="px-3 py-2">{c.cohort ?? 'No cohort'}</td>
                  <td className="px-3 py-2">
                    <CellButton c={c} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : prefs.view === 'instructor' ? (
        <InstructorGrid
          cells={cells}
          rows={rows}
          thisWeek={thisWeek}
          render={(c) => <CellButton c={c} />}
        />
      ) : (
        <div className="max-h-[70vh] overflow-auto rounded-md border border-border">
          <table className="text-sm">
            <thead className="sticky top-0 z-20 bg-card">
              <tr>
                <th className="sticky left-0 z-30 bg-card px-3 py-2" rowSpan={2}>
                  Week of
                </th>
                {tracks.map(([t, cs]) => (
                  <th
                    key={t}
                    colSpan={collapsed.has(t) ? 1 : cs.length}
                    className="border-l border-border px-3 py-1 text-left"
                  >
                    <button
                      type="button"
                      className="flex items-center gap-1 text-xs font-semibold"
                      aria-expanded={!collapsed.has(t)}
                      onClick={() => {
                        const n = new Set(collapsed);
                        if (n.has(t)) n.delete(t);
                        else n.add(t);
                        setCollapsed(n);
                      }}
                    >
                      {collapsed.has(t) ? (
                        <ChevronRight className="h-3.5 w-3.5" aria-hidden />
                      ) : (
                        <ChevronDown className="h-3.5 w-3.5" aria-hidden />
                      )}
                      {t} ({cs.length})
                    </button>
                  </th>
                ))}
              </tr>
              <tr>
                {tracks.flatMap(([t, cs]) =>
                  collapsed.has(t)
                    ? [<th key={`${t}:folded`} className="border-l border-border px-3 py-2" />]
                    : cs.map((c) => {
                        const h = health(c.id);
                        return (
                          <th
                            key={c.id}
                            scope="col"
                            className="min-w-48 border-l border-border px-3 py-2 text-left align-top"
                          >
                            <div className="flex items-center gap-1">
                              <span className="font-semibold">{c.name}</span>
                              <RegionBadge region={c.region} />
                            </div>
                            <div className="mt-1 flex flex-wrap gap-1 font-normal">
                              <Badge
                                tone={
                                  c.mode === 'Standard'
                                    ? 'success'
                                    : c.mode === 'Custom'
                                      ? 'warning'
                                      : 'neutral'
                                }
                              >
                                {c.mode === 'Custom'
                                  ? `${COHORT_BADGE.custom} (${c.changes})`
                                  : c.mode === 'Standard'
                                    ? COHORT_BADGE.standard
                                    : COHORT_BADGE.fullyCustom}
                              </Badge>
                              <Badge
                                tone={
                                  h.total > 0 && h.confirmed === h.total ? 'success' : 'neutral'
                                }
                              >
                                {confirmedCount(h.confirmed, h.total)}
                              </Badge>
                              {c.merged_into && c.merged_from && (
                                <Badge tone="accent">
                                  {COHORT_BADGE.mergedInto} {c.merged_into_name} from{' '}
                                  {DateTime.fromISO(c.merged_from).toFormat('LLL d')}
                                </Badge>
                              )}
                            </div>
                            <CohortMenu
                              name={c.name}
                              onPick={(kind) => setMenu({ kind, cohort: c.id })}
                            />
                          </th>
                        );
                      }),
                )}
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => {
                const iso = row.toISODate()!;
                const programs = new Set(
                  visibleCohorts.map((c) => breakAt(c.id, row)?.program_break_id ?? '-'),
                );
                const program =
                  visibleCohorts.length > 1 && programs.size === 1 && !programs.has('-')
                    ? breakAt(visibleCohorts[0]!.id, row)
                    : null;
                return (
                  <tr
                    key={iso}
                    aria-current={iso === thisWeek ? 'date' : undefined}
                    className={cn(
                      'border-t border-border align-top',
                      iso === thisWeek && 'bg-info-soft/40',
                    )}
                  >
                    <th
                      scope="row"
                      className="sticky left-0 z-10 bg-card px-3 py-2 text-left whitespace-nowrap"
                    >
                      {row.toFormat('LLL d')}
                      {iso === thisWeek && (
                        <div className="text-xs font-normal text-muted-foreground">This week</div>
                      )}
                    </th>
                    {program ? (
                      <td
                        colSpan={
                          visibleCohorts.length + tracks.filter(([t]) => collapsed.has(t)).length
                        }
                        className="px-3 py-2"
                      >
                        <Badge>
                          <Pause className="h-3.5 w-3.5" aria-hidden /> {MARK.programBreak}:{' '}
                          {program.reason}
                        </Badge>
                      </td>
                    ) : (
                      tracks.flatMap(([t, cs]) =>
                        collapsed.has(t)
                          ? [<td key={`${t}:${iso}`} className="border-l border-border" />]
                          : cs.map((c) => {
                              const here = cellsAt(c.id, row);
                              const br = breakAt(c.id, row);
                              return (
                                <td key={c.id} className="border-l border-border px-2 py-2">
                                  <div className="space-y-1">
                                    {br && here.length === 0 && (
                                      <Badge>
                                        <Pause className="h-3.5 w-3.5" aria-hidden /> {MARK.break}:{' '}
                                        {br.reason}
                                      </Badge>
                                    )}
                                    {here.map((x) => (
                                      <CellButton key={x.id} c={x} />
                                    ))}
                                  </div>
                                </td>
                              );
                            }),
                      )
                    )}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {open && <ClassDrawer week={open} names={names} onClose={() => setOpenWeek(null)} />}
      {(bulk === 'move' || bulk === 'cancel') && (
        <BulkChangeDialog
          action={bulk}
          weekIds={selected}
          onClose={() => {
            setBulk(null);
            setSelected([]);
          }}
        />
      )}
      {bulk === 'break' && domain && (
        <AddBreakDialog
          domainId={domain.id}
          program={false}
          cohortIds={[
            ...new Set(
              (b?.weeks ?? [])
                .filter((c) => selected.includes(c.id) && c.cohort_id)
                .map((c) => c.cohort_id!),
            ),
          ]}
          startsOn={
            (b?.weeks ?? [])
              .filter((c) => selected.includes(c.id))
              .map((c) => c.week_start_date)
              .sort()[0]
          }
          onClose={() => {
            setBulk(null);
            setSelected([]);
          }}
        />
      )}
      {bulk === 'share' &&
        (() => {
          // The earliest selected class week hosts the shared class; the others join it.
          const chosen = (weeks.data ?? [])
            .filter((w) => selected.includes(w.id))
            .sort((x, y) => x.week_start_date.localeCompare(y.week_start_date));
          const host = chosen[0];
          return (
            host && (
              <ShareDialog
                week={host}
                guests={chosen.slice(1).map((w) => w.id)}
                onClose={() => {
                  setBulk(null);
                  setSelected([]);
                }}
              />
            )
          );
        })()}
      {menu?.kind === 'break' && domain && (
        <AddBreakDialog
          domainId={domain.id}
          program={false}
          cohortId={menu.cohort}
          onClose={() => setMenu(null)}
        />
      )}
      {menu?.kind === 'holiday' && domain && (
        <AddCohortHolidayDialog
          domainId={domain.id}
          cohortId={menu.cohort}
          onClose={() => setMenu(null)}
        />
      )}
      {menu?.kind === 'merge' && domain && (
        <MergeCohortsDialog
          domainId={domain.id}
          cohortId={menu.cohort}
          onClose={() => setMenu(null)}
        />
      )}
    </div>
  );
}

/** Every status and badge the board and its side panel can show, each with one sentence. */
function Legend() {
  return (
    <section aria-labelledby="board-legend" className="mb-4 rounded-md border border-border p-3">
      <h2 id="board-legend" className="text-sm font-semibold">
        Legend
      </h2>
      {legendGroups().map((g) => (
        <div key={g.title} className="mt-3">
          <h3 className="mb-2 text-xs font-semibold text-muted-foreground uppercase">{g.title}</h3>
          <dl className="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2 xl:grid-cols-3">
            {g.items.map((i) => {
              const Icon = i.icon;
              return (
                <div key={i.label} className="min-w-0">
                  <dt className="inline">
                    <Badge tone={i.tone}>
                      {Icon && <Icon className="h-3.5 w-3.5" aria-hidden />}
                      {i.label}
                    </Badge>
                  </dt>
                  <dd className="ml-1.5 inline text-muted-foreground">{i.text}</dd>
                </div>
              );
            })}
          </dl>
        </div>
      ))}
    </section>
  );
}

/** The cohort header menu: add a break, a cohort holiday, merge, and links to its settings and instructor order. */
function CohortMenu({
  name,
  onPick,
}: {
  name: string;
  onPick: (kind: 'break' | 'holiday' | 'merge') => void;
}) {
  const [openMenu, setOpenMenu] = useState(false);
  return (
    <div className="relative mt-1 font-normal">
      <Button
        size="sm"
        variant="ghost"
        aria-expanded={openMenu}
        onClick={() => setOpenMenu(!openMenu)}
      >
        Cohort actions <span className="sr-only">for {name}</span>
      </Button>
      {openMenu && (
        <div className="absolute z-40 mt-1 flex w-56 flex-col rounded-md border border-border bg-card p-1 shadow-md">
          {(
            [
              ['break', 'Add a break'],
              ['holiday', 'Add a cohort holiday'],
              ['merge', 'Merge with another cohort'],
            ] as const
          ).map(([k, label]) => (
            <Button
              key={k}
              size="sm"
              variant="ghost"
              className="justify-start"
              onClick={() => {
                setOpenMenu(false);
                onPick(k);
              }}
            >
              {label}
            </Button>
          ))}
          <a className="rounded px-3 py-1.5 text-sm hover:bg-muted" href="/setup/domains">
            Cohort settings
          </a>
          <a className="rounded px-3 py-1.5 text-sm hover:bg-muted" href="/setup/modules">
            Instructor order
          </a>
        </div>
      )}
    </div>
  );
}

const NO_INSTRUCTOR = 'No instructor yet';
const PHONE = '(width < 768px)';
/** True on a phone sized screen, and follows the screen when it turns or resizes. */
function usePhone() {
  return useSyncExternalStore(
    (changed) => {
      const m = window.matchMedia(PHONE);
      m.addEventListener('change', changed);
      return () => m.removeEventListener('change', changed);
    },
    () => window.matchMedia(PHONE).matches,
  );
}

/**
 * By instructor: one row per instructor, one column per week. On a phone each instructor is a heading with their
 * class weeks as cards underneath, so nothing scrolls sideways and no week without a class takes room.
 */
function InstructorGrid({
  cells,
  rows,
  thisWeek,
  render,
}: {
  cells: Cell[];
  rows: DateTime[];
  thisWeek: string | null;
  render: (c: Cell) => React.ReactNode;
}) {
  const phone = usePhone();
  const people = [...new Set(cells.map((c) => c.instructor ?? NO_INSTRUCTOR))].sort();
  if (phone)
    return <InstructorCards cells={cells} people={people} thisWeek={thisWeek} render={render} />;
  return (
    <div className="max-h-[70vh] overflow-auto rounded-md border border-border">
      <table className="text-sm">
        <thead className="sticky top-0 z-20 bg-card">
          <tr>
            <th className="sticky left-0 z-30 bg-card px-3 py-2 text-left">Instructor</th>
            {rows.map((r) => (
              <th
                key={r.toISODate()}
                scope="col"
                aria-current={r.toISODate() === thisWeek ? 'date' : undefined}
                className="min-w-48 border-l border-border px-3 py-2 text-left"
              >
                {r.toFormat('LLL d')}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {people.map((p) => (
            <tr key={p} className="border-t border-border align-top">
              <th
                scope="row"
                className="sticky left-0 z-10 bg-card px-3 py-2 text-left whitespace-nowrap"
              >
                {p}
              </th>
              {rows.map((r) => (
                <td key={r.toISODate()} className="border-l border-border px-2 py-2">
                  <div className="space-y-1">
                    {cells
                      .filter(
                        (c) =>
                          (c.instructor ?? NO_INSTRUCTOR) === p &&
                          DateTime.fromISO(c.week_start_date) >= r &&
                          DateTime.fromISO(c.week_start_date) < r.plus({ weeks: 1 }),
                      )
                      .map((c) => (
                        <div key={c.id}>
                          <div className="text-xs text-muted-foreground">
                            {c.cohort ?? 'No cohort'}
                          </div>
                          {render(c)}
                        </div>
                      ))}
                  </div>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** By instructor on a phone: each instructor's class weeks as cards, in date order. */
function InstructorCards({
  cells,
  people,
  thisWeek,
  render,
}: {
  cells: Cell[];
  people: string[];
  thisWeek: string | null;
  render: (c: Cell) => React.ReactNode;
}) {
  if (people.length === 0)
    return <p className="text-sm text-muted-foreground">No class weeks match these filters.</p>;
  return (
    <div className="space-y-6">
      {people.map((p) => {
        const mine = cells
          .filter((c) => (c.instructor ?? NO_INSTRUCTOR) === p)
          .sort(
            (x, y) =>
              x.week_start_date.localeCompare(y.week_start_date) ||
              (x.cohort ?? '').localeCompare(y.cohort ?? ''),
          );
        return (
          <div key={p}>
            <h2 className="mb-2 text-base font-semibold">
              {p}{' '}
              <span className="text-sm font-normal text-muted-foreground">
                ({mine.length} class week{mine.length === 1 ? '' : 's'})
              </span>
            </h2>
            <ul className="space-y-3" aria-label={`Class weeks of ${p}`}>
              {mine.map((c) => {
                const now = sunday(DateTime.fromISO(c.week_start_date)).toISODate() === thisWeek;
                return (
                  <li
                    key={c.id}
                    aria-current={now ? 'date' : undefined}
                    className={cn('min-w-0 rounded-md', now && 'bg-info-soft/40 p-1')}
                  >
                    <div className="mb-1 text-xs text-muted-foreground">
                      Week of {DateTime.fromISO(c.week_start_date).toFormat('LLL d')}
                      {now && ' (this week)'}, {c.cohort ?? 'No cohort'}
                    </div>
                    {render(c)}
                  </li>
                );
              })}
            </ul>
          </div>
        );
      })}
    </div>
  );
}
