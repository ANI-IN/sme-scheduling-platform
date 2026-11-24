import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getFilteredRowModel,
  useReactTable,
} from '@tanstack/react-table';
import { DateTime } from 'luxon';
import { CalendarDays, Download, LifeBuoy, Plus } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, fetchAll, fetchByIds, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useAuth } from '@/lib/auth';
import {
  applyFilters,
  filtersKey,
  fixedOptions,
  hasChoices,
  matches,
  optionsFrom,
  type FilterField,
  type Getters,
} from '@/lib/filters';
import { useRememberedFilters } from '@/lib/useFilters';
import { FilterBar } from '@/components/FilterBar';
import { useCohorts, useInstructors, useModules, useWeeks, type WeekRow } from '@/lib/data';
import { PT } from '@/lib/time';
import { asRegion, classTimeLine, REGIONS, TZ, weekRegion } from '@/lib/region';
import { plannedLine } from '@/lib/planned';
import { ClassTime, RegionBadge } from '@/components/ClassTime';
import { AT_RISK, WEEK_KINDS, WEEK_STATUS, weekState, weeksById } from '@/lib/status';
import { downloadCsv, toCsv } from '@/lib/csv';
import {
  Badge,
  Button,
  Checkbox,
  Empty,
  ErrorText,
  Input,
  LoadError,
  Modal,
  PageHeader,
  Select,
  SkeletonRows,
  Toolbar,
  tableWrap,
  thead,
  td,
  th,
} from '@/components/ui';
import { PlanDialog } from './PlanDialog';
import { BulkChangeDialog } from './boardBulk';
import { AddClassDialog } from './AddClassDialog';
import { ClassDrawer, useRun } from './ClassDrawer';
import { StartAskingDialog, useDomainPlanned } from './startAsking';
import { HelpPanel, HelpPanelButton, HelpPanelProvider } from '@/components/HelpPanel';
import { ClassesControls, ClassesReading } from './helpPanelText';
import { legendGroups } from './boardBadges';

/** The statuses of a class week nobody is confirmed or asked for, which show who is planned instead. */
const PLANNED_FOR: string[] = [
  WEEK_STATUS['Not asked yet'].word,
  WEEK_STATUS.Paused.word,
  WEEK_STATUS['Setup incomplete'].word,
  WEEK_STATUS['Needs instructor'].word,
];

/** "Database Design, Weekday cohort, week of Oct 4". */
const weekLabel = (w: WeekRow) =>
  `${w.module?.name ?? 'Class week'}${w.cohort ? `, ${w.cohort}` : ''}, week of ${DateTime.fromISO(w.week_start_date).toFormat('LLL d')}`;

/** The fields of the filter bar, in order (Release 3, C13). Values are the words people read. */
export const CLASSES_FILTERS = ['cohort', 'module', 'region', 'status', 'instructor'] as const;
/** The Instructor filter's choice for a class week with nobody confirmed or being asked. */
export const NO_INSTRUCTOR = 'No instructor yet';
const NO_COHORT = 'No cohort';
/** Region is read from each class, since the classes of one class week can be taught in either region. */
const CLASS_GETTERS: Getters<WeekRow['class_session'][number]> = {
  region: (c) => asRegion(c.region),
};

type Row = {
  week: WeekRow;
  cls: WeekRow['class_session'][number];
  first: boolean;
  holiday: string | null;
};
const col = createColumnHelper<Row>();

export default function Schedule() {
  return (
    <HelpPanelProvider page="classes">
      <SchedulePage />
    </HelpPanelProvider>
  );
}

const legend = legendGroups();

function SchedulePage() {
  const { domain } = useDomain();
  const auth = useAuth();
  const weeks = useWeeks(domain?.id);
  const instructors = useInstructors();
  const modules = useModules(domain?.id);
  const cohorts = useCohorts(domain?.id);
  const { run, err } = useRun();
  const [planning, setPlanning] = useState(false);
  const [openWeek, setOpenWeek] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [showPast, setShowPast] = useState(false);
  // Cohort, module, region, status and instructor: several choices each, remembered per person and domain.
  const [filters, setFilters] = useRememberedFilters(
    filtersKey('classes', auth.account?.member?.email),
    domain?.id,
    CLASSES_FILTERS,
  );
  const [adding, setAdding] = useState(false);
  const [search, setSearch] = useState('');
  const [queueFor, setQueueFor] = useState<string[] | null>(null);
  const [bulk, setBulk] = useState<'move' | 'cancel' | null>(null);
  const [starting, setStarting] = useState(false);

  const names = useMemo(
    () => new Map((instructors.data ?? []).map((i) => [i.id, i.full_name])),
    [instructors.data],
  );
  const byId = useMemo(() => weeksById(weeks.data), [weeks.data]);
  const holidays = useQuery({
    queryKey: ['holiday'],
    queryFn: async () => check(await supabase.from('holiday').select('*')),
  });
  // Holidays by local date and region; a holiday without a region applies to both.
  const holidayMap = useMemo(() => {
    const m = new Map<string, string>();
    for (const h of holidays.data ?? [])
      for (const r of h.region ? [h.region] : REGIONS) {
        const k = `${h.date}|${r}`;
        m.set(k, m.has(k) ? `${m.get(k)}, ${h.name}` : h.name);
      }
    return m;
  }, [holidays.data]);
  const weekIds = (weeks.data ?? []).map((w) => w.id);
  // Who is planned for each coming class week nobody is confirmed or asked for yet (the database's own line).
  const plannedIds = useMemo(
    () =>
      new Set(
        (weeks.data ?? [])
          .filter(
            (w) =>
              PLANNED_FOR.includes(weekState(w, names, byId).kind) &&
              !!w.first_class_at &&
              new Date(w.first_class_at) > new Date(),
          )
          .map((w) => w.id),
      ),
    [weeks.data, names, byId],
  );
  // Loaded at once with the class weeks (decision 342); shown only for the class weeks above.
  const planned = useDomainPlanned(domain?.id);
  const checklist = useQuery({
    queryKey: ['checklist_item', 'grid', domain?.id, weekIds.length],
    enabled: weekIds.length > 0,
    // Every class week of the domain: 100 class weeks per request, each read a page at a time (decision 294).
    queryFn: () =>
      fetchByIds(weekIds, async (ids) => ({
        data: await fetchAll((from, to) =>
          supabase
            .from('checklist_item')
            .select('id, class_id, done, class_session!inner(module_week_id)')
            .in('class_session.module_week_id', ids)
            .order('id')
            .range(from, to),
        ),
        error: null,
      })),
  });
  const checklistByWeek = useMemo(() => {
    const m = new Map<string, { done: number; total: number }>();
    for (const i of checklist.data ?? []) {
      const k = (i.class_session as unknown as { module_week_id: string }).module_week_id;
      const v = m.get(k) ?? { done: 0, total: 0 };
      v.total++;
      if (i.done) v.done++;
      m.set(k, v);
    }
    return m;
  }, [checklist.data]);

  // What each filter reads from a class week (Region is read from each class, CLASS_GETTERS).
  const weekGetters = useMemo<Getters<WeekRow>>(
    () => ({
      cohort: (w) => w.cohort ?? NO_COHORT,
      module: (w) => w.module?.name,
      status: (w) => {
        const s = weekState(w, names, byId);
        // "At risk" shows every week at risk, confirmed or not; the others match the status itself.
        return s.atRisk ? [s.kind, AT_RISK] : s.kind;
      },
      instructor: (w) => {
        const s = weekState(w, names, byId);
        return s.confirmed ?? s.asking ?? NO_INSTRUCTOR;
      },
    }),
    [names, byId],
  );

  // The class weeks shown before any filter: the upcoming ones, or every one with Show past and cancelled.
  const inView = useMemo(() => {
    const today = DateTime.now().setZone(PT).toISODate()!;
    return (weeks.data ?? []).filter(
      (w) =>
        showPast ||
        !(
          ['Completed', 'Cancelled'].includes(w.status) ||
          DateTime.fromISO(w.week_start_date).plus({ days: 7 }).toISODate()! < today
        ),
    );
  }, [weeks.data, showPast]);

  const rows = useMemo<Row[]>(() => {
    const out: Row[] = [];
    for (const w of applyFilters(inView, filters, weekGetters)) {
      const classes = [...w.class_session]
        .filter((c) => matches(c, filters, CLASS_GETTERS))
        .sort((a, b) => a.starts_at.localeCompare(b.starts_at));
      classes.forEach((c, idx) => {
        const r = asRegion(c.region);
        const date = DateTime.fromISO(c.starts_at).setZone(TZ[r]).toISODate()!;
        out.push({
          week: w,
          cls: c,
          first: idx === 0,
          holiday: holidayMap.get(`${date}|${r}`) ?? null,
        });
      });
    }
    return out;
  }, [inView, filters, weekGetters, holidayMap]);
  // Only the statuses some class week has, in their natural order, without names.
  const statuses = useMemo(() => {
    const have = new Set<string>();
    for (const w of weeks.data ?? []) {
      const s = weekState(w, names, byId);
      have.add(s.kind);
      if (s.atRisk) have.add(AT_RISK);
    }
    // Over and cancelled weeks only show with "Show past and cancelled". At risk is a flag, so it comes last.
    return [...WEEK_KINDS, AT_RISK].filter(
      (k) =>
        have.has(k) &&
        (showPast || (k !== WEEK_STATUS.Completed.word && k !== WEEK_STATUS.Cancelled.word)),
    );
  }, [weeks.data, names, byId, showPast]);

  const filterFields = useMemo<FilterField[]>(
    () => [
      {
        key: 'cohort',
        label: 'Cohort',
        options: optionsFrom(
          [...(cohorts.data ?? []).map((c) => c.name), ...inView.map((w) => w.cohort ?? NO_COHORT)],
          (n) => n,
        ),
      },
      {
        key: 'module',
        label: 'Module',
        options: optionsFrom(
          [...(modules.data ?? []).map((m) => m.name), ...inView.map((w) => w.module?.name ?? '')],
          (n) => n || null,
        ),
      },
      { key: 'region', label: 'Region', options: fixedOptions(REGIONS) },
      { key: 'status', label: 'Status', options: fixedOptions(statuses) },
      {
        key: 'instructor',
        label: 'Instructor',
        options: optionsFrom(inView, weekGetters.instructor!),
      },
    ],
    [cohorts.data, modules.data, inView, statuses, weekGetters],
  );

  const columns = useMemo(
    () => [
      col.display({
        id: 'select',
        header: '',
        cell: ({ row }) =>
          row.original.first ? (
            <input
              type="checkbox"
              aria-label="Select this class week"
              checked={selected.has(row.original.week.id)}
              onChange={(e) => {
                const next = new Set(selected);
                if (e.target.checked) next.add(row.original.week.id);
                else next.delete(row.original.week.id);
                setSelected(next);
              }}
            />
          ) : null,
      }),
      col.accessor((r) => classTimeLine(r.cls.starts_at, r.cls.ends_at, r.cls.region), {
        id: 'when',
        header: 'When',
        cell: ({ row }) => (
          <span className="block">
            <ClassTime
              start={row.original.cls.starts_at}
              end={row.original.cls.ends_at}
              region={row.original.cls.region}
              cancelled={row.original.cls.status === 'Cancelled'}
            />
            {row.original.holiday && (
              <span className="mt-0.5 block">
                <Badge tone="warning">Holiday: {row.original.holiday}</Badge>
              </span>
            )}
          </span>
        ),
      }),
      col.accessor(
        (r) =>
          `${r.week.module?.name ?? ''} ${r.cls.class_type} ${r.cls.title} ${r.week.cohort} ${asRegion(r.cls.region)}`,
        {
          id: 'class',
          header: 'Class',
          cell: ({ row }) => (
            <div>
              <div className="font-medium">
                {row.original.first && (
                  <button
                    type="button"
                    className="text-left font-medium text-link hover:underline"
                    aria-label={`Open ${row.original.week.module?.name ?? 'class week'}, week of ${DateTime.fromISO(row.original.week.week_start_date).toFormat('LLL d')}`}
                    onClick={(e) => {
                      e.stopPropagation();
                      setOpenWeek(row.original.week.id);
                    }}
                  >
                    {row.original.week.module?.name}
                  </button>
                )}
                {row.original.first && row.original.week.cohort && (
                  <span className="ml-1 text-xs font-normal text-muted-foreground">
                    {row.original.week.cohort}
                  </span>
                )}
              </div>
              <div className="flex flex-wrap items-center gap-1 text-xs text-muted-foreground">
                {row.original.cls.class_type}
                <RegionBadge region={row.original.cls.region} />
              </div>
            </div>
          ),
        },
      ),
      col.accessor((r) => weekState(r.week, names, byId).short, {
        id: 'status',
        header: 'Status',
        cell: ({ row }) => {
          if (!row.original.first) return null;
          const s = weekState(row.original.week, names, byId);
          return <Badge tone={s.tone}>{s.short}</Badge>;
        },
      }),
      col.accessor(
        (r) => {
          const s = weekState(r.week, names, byId);
          if (s.confirmed) return `${WEEK_STATUS.Confirmed.word}: ${s.confirmed}`;
          if (s.asking) return `${WEEK_STATUS.Waiting.word}: ${s.asking}`;
          const p = plannedIds.has(r.week.id) ? planned.data?.get(r.week.id) : undefined;
          return (p && plannedLine(p, DateTime.now(), weekRegion(r.week.class_session))) ?? '';
        },
        {
          id: 'confirmed',
          header: 'Instructor',
          cell: ({ row, getValue }) => (row.original.first ? getValue() : null),
        },
      ),
      col.accessor(
        (r) =>
          r.week.outreach_mode === 'Manual'
            ? [...r.week.manual_queue_item]
                .filter((q) => !q.asked_request_id)
                .sort((a, b) => a.position - b.position)
                .map((q) => names.get(q.instructor_id))
                .join(', ') || 'Chosen list is empty'
            : 'Instructor order',
        {
          id: 'toask',
          header: 'Who to ask',
          cell: ({ row, getValue }) =>
            row.original.first ? (
              <span className="line-clamp-2 text-xs text-muted-foreground" title={getValue()}>
                {row.original.week.outreach_mode === 'Manual' ? 'Chosen list: ' : ''}
                {getValue()}
              </span>
            ) : null,
        },
      ),
      col.accessor(
        (r) => {
          const c = checklistByWeek.get(r.week.id);
          return c ? `${c.done} of ${c.total}` : '';
        },
        {
          id: 'checklist',
          header: 'Tasks',
          cell: ({ row, getValue }) => (row.original.first ? getValue() : null),
        },
      ),
      col.display({
        id: 'help',
        header: 'Help',
        cell: ({ row }) =>
          row.original.first &&
          row.original.week.help_request.some((h) =>
            ['Open', 'InProgress', 'WaitingOnInstructor'].includes(h.status),
          ) ? (
            <LifeBuoy className="h-4 w-4 text-warning-strong" aria-label="Help request open" />
          ) : null,
      }),
    ],
    [selected, names, byId, checklistByWeek, planned.data, plannedIds],
  );

  // TanStack Table manages its own memoisation; the React Compiler skips this component.
  // eslint-disable-next-line react-hooks/incompatible-library
  const table = useReactTable({
    data: rows,
    columns,
    state: { globalFilter: search },
    onGlobalFilterChange: setSearch,
    getCoreRowModel: getCoreRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
  });

  const selectedWeeks = (weeks.data ?? []).filter((w) => selected.has(w.id));
  const forEachWeek = async (fn: (w: WeekRow) => Promise<unknown>, ok: string) => {
    await run(async () => {
      for (const w of selectedWeeks) await fn(w);
    }, ok);
    setSelected(new Set());
  };

  const exportCsv = () => {
    void rpc('log_export', {
      p_what: 'Upcoming classes',
      p_rows: table.getFilteredRowModel().rows.length,
      p_filters: {
        search,
        ...filters,
        show_past: showPast,
      },
      p_domain_id: domain?.id,
    }).catch(() => {});
    downloadCsv(
      `schedule-${domain?.name}-${DateTime.now().toFormat('yyyy-LL-dd')}.csv`,
      toCsv(
        table.getFilteredRowModel().rows.map(({ original: r }) => {
          const s = weekState(r.week, names, byId);
          return {
            date_time: classTimeLine(r.cls.starts_at, r.cls.ends_at, r.cls.region),
            region: asRegion(r.cls.region),
            time_zone: TZ[asRegion(r.cls.region)],
            starts_utc: r.cls.starts_at,
            module: r.week.module?.name,
            class_type: r.cls.class_type,
            title: r.cls.title,
            cohort: r.week.cohort,
            outreach_status: s.label,
            confirmed_instructor: s.confirmed ?? '',
            outreach_mode: r.week.outreach_mode,
            checklist: checklistByWeek.get(r.week.id)
              ? `${checklistByWeek.get(r.week.id)!.done}/${checklistByWeek.get(r.week.id)!.total}`
              : '',
            class_status: r.cls.status,
            holiday: r.holiday ?? '',
          };
        }),
      ),
    );
  };

  const open = (weeks.data ?? []).find((w) => w.id === openWeek);

  return (
    <div>
      <PageHeader
        title="Upcoming classes"
        description="Every planned class, grouped by class week. Each class shows the time where it is taught, and US classes also show the India time. Select a row for details and actions."
      >
        <Button variant="secondary" onClick={exportCsv} disabled={rows.length === 0}>
          <Download className="h-4 w-4" aria-hidden /> Download as spreadsheet
        </Button>
        <Button variant="secondary" onClick={() => setAdding(true)} disabled={!domain}>
          <Plus className="h-4 w-4" aria-hidden /> Add one class
        </Button>
        <Button onClick={() => setPlanning(true)} disabled={!domain}>
          <Plus className="h-4 w-4" aria-hidden /> Plan classes
        </Button>
      </PageHeader>
      <HelpPanel
        groups={legend}
        readTitle="How to read this page"
        read={<ClassesReading />}
        controlsTitle="Page controls"
        controls={<ClassesControls />}
        onlyLabel="Only what's on this page"
      />
      <Toolbar>
        {/* First in the toolbar: the panel covers only the right side of the screen, never this button. */}
        <HelpPanelButton />
        <Input
          placeholder="Search classes"
          aria-label="Search classes"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="w-56"
        />
        <Checkbox label="Show past and cancelled" checked={showPast} onChange={setShowPast} />
      </Toolbar>
      <FilterBar fields={filterFields} value={filters} onChange={setFilters} />

      {selected.size > 0 && (
        <div className="mb-3 flex flex-wrap items-center gap-2 rounded-lg border border-primary/40 bg-primary-soft p-2 text-sm">
          <strong className="px-1">
            {selected.size} class week{selected.size === 1 ? '' : 's'} selected
          </strong>
          <Button size="sm" onClick={() => setStarting(true)}>
            Start asking now
          </Button>
          <Button size="sm" variant="secondary" onClick={() => setQueueFor([...selected])}>
            Choose who to ask
          </Button>
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              forEachWeek(
                (w) =>
                  rpc('set_outreach_queue', {
                    p_module_week_id: w.id,
                    p_mode: 'Sequential',
                    p_decision: 'keep',
                  }),
                'Using the instructor order',
              )
            }
          >
            Use the instructor order
          </Button>
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              forEachWeek(
                (w) =>
                  rpc('set_outreach_queue', {
                    p_module_week_id: w.id,
                    p_mode: 'Manual',
                    p_instructor_ids: [...w.manual_queue_item]
                      .filter((q) => !q.asked_request_id)
                      .sort((a, b) => a.position - b.position)
                      .map((q) => q.instructor_id),
                    p_decision: 'keep',
                  }),
                'Using a chosen list',
              )
            }
          >
            Use a chosen list
          </Button>
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              forEachWeek(
                // Confirmed class weeks have nobody to ask, so they are left as they are.
                async (w) =>
                  w.booking.some((b) => b.status === 'Active')
                    ? undefined
                    : rpc('pause_outreach', { p_module_week_id: w.id, p_paused: true }),
                'Paused requests for the class weeks still looking for an instructor',
              )
            }
          >
            Pause requests
          </Button>
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              forEachWeek(
                (w) => rpc('pause_outreach', { p_module_week_id: w.id, p_paused: false }),
                'Requests resumed',
              )
            }
          >
            Resume requests
          </Button>
          {/* The same preview, checks and reasons as on the Schedule board (bulk_change_weeks). */}
          <Button size="sm" variant="outline" onClick={() => setBulk('move')}>
            Move by weeks
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setSelected(new Set())}>
            Clear selection
          </Button>
          <Button
            size="sm"
            variant="destructive"
            className="ml-auto"
            onClick={() => setBulk('cancel')}
          >
            Cancel classes
          </Button>
        </div>
      )}
      <ErrorText error={err} />
      {starting && (
        <StartAskingDialog
          weeks={selectedWeeks.map((w) => ({ id: w.id, label: weekLabel(w) }))}
          onDone={() => setSelected(new Set())}
          onClose={() => setStarting(false)}
        />
      )}
      {bulk && (
        <BulkChangeDialog
          action={bulk}
          weekIds={selectedWeeks.map((w) => w.id)}
          onSaved={() => setSelected(new Set())}
          onClose={() => setBulk(null)}
        />
      )}

      {weeks.isLoading ? (
        <SkeletonRows rows={8} />
      ) : weeks.error ? (
        <LoadError what="the classes" onRetry={() => weeks.refetch()} />
      ) : table.getFilteredRowModel().rows.length === 0 && (search || hasChoices(filters)) ? (
        <Empty
          title="No classes match these filters"
          icon={<CalendarDays className="h-5 w-5" />}
          action={
            <Button
              variant="secondary"
              onClick={() => {
                setSearch('');
                setFilters({});
              }}
            >
              Clear filters
            </Button>
          }
        />
      ) : rows.length === 0 ? (
        <Empty
          title={
            !showPast && (weeks.data ?? []).length > 0
              ? 'No upcoming classes'
              : 'No classes planned yet'
          }
          icon={<CalendarDays className="h-5 w-5" />}
          action={
            <Button onClick={() => setPlanning(true)} disabled={!domain}>
              Plan classes
            </Button>
          }
        >
          {!showPast && (weeks.data ?? []).length > 0
            ? 'Every class week is over or cancelled. Turn on "Show past and cancelled" to see them, or plan new classes.'
            : "Plan classes creates class weeks from each module's class times."}
        </Empty>
      ) : (
        <div className={tableWrap}>
          <table className="w-full">
            <thead className={thead}>
              {table.getHeaderGroups().map((hg) => (
                <tr key={hg.id}>
                  {hg.headers.map((h) => (
                    <th key={h.id} className={th}>
                      {flexRender(h.column.columnDef.header, h.getContext())}
                    </th>
                  ))}
                </tr>
              ))}
            </thead>
            <tbody>
              {table.getRowModel().rows.map((r) => (
                <tr
                  key={r.id}
                  className={`cursor-pointer hover:bg-muted ${r.original.first ? 'border-t-2 border-border' : ''} ${r.original.holiday ? 'bg-warning-soft' : ''}`}
                  onClick={(e) => {
                    if ((e.target as HTMLElement).tagName !== 'INPUT')
                      setOpenWeek(r.original.week.id);
                  }}
                >
                  {r.getVisibleCells().map((c) => (
                    <td key={c.id} className={td}>
                      {flexRender(c.column.columnDef.cell, c.getContext())}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {planning && domain && <PlanDialog domain={domain} onClose={() => setPlanning(false)} />}
      {adding && domain && <AddClassDialog domain={domain} onClose={() => setAdding(false)} />}
      {open && <ClassDrawer week={open} names={names} onClose={() => setOpenWeek(null)} />}
      {queueFor && (
        <QueueDialog
          weekIds={queueFor}
          onDone={() => (setQueueFor(null), setSelected(new Set()))}
        />
      )}
    </div>
  );
}

/** Bulk "Choose who to ask": a chosen list in the order ticked. */
function QueueDialog({ weekIds, onDone }: { weekIds: string[]; onDone: () => void }) {
  const instructors = useInstructors();
  const { run, err } = useRun();
  const [order, setOrder] = useState<string[]>([]);
  const [end, setEnd] = useState('Stop');
  const active = (instructors.data ?? []).filter((i) => i.status === 'Active');
  return (
    <Modal
      open
      onOpenChange={(o) => !o && onDone()}
      title="Choose who to ask"
      description="Tick instructors in the order they should be asked, one at a time. This applies to every selected class week. Anyone being asked right now keeps their request."
    >
      <div className="max-h-72 space-y-1 overflow-y-auto">
        {active.map((i) => (
          <label key={i.id} className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={order.includes(i.id)}
              onChange={(e) =>
                setOrder(e.target.checked ? [...order, i.id] : order.filter((x) => x !== i.id))
              }
            />
            {order.includes(i.id) && <Badge tone="info">{order.indexOf(i.id) + 1}</Badge>}
            {i.full_name}
          </label>
        ))}
      </div>
      <div className="mt-3 flex items-center gap-2 text-sm">
        When the list runs out:
        <Select
          aria-label="When the list runs out"
          value={end}
          onChange={(e) => setEnd(e.target.value)}
          className="w-64"
        >
          <option value="Stop">Stop and tell me</option>
          <option value="ContinueWithRanking">Carry on with the instructor order</option>
        </Select>
      </div>
      <ErrorText error={err} />
      <div className="mt-3 flex justify-end gap-2">
        <Button variant="secondary" onClick={onDone}>
          Cancel
        </Button>
        <Button
          disabled={order.length === 0}
          onClick={async () => {
            await run(async () => {
              for (const id of weekIds)
                await rpc('set_outreach_queue', {
                  p_module_week_id: id,
                  p_mode: 'Manual',
                  p_instructor_ids: order,
                  p_end_behaviour: end,
                  p_decision: 'keep',
                });
            }, 'Saved who to ask');
            onDone();
          }}
        >
          Save
        </Button>
      </div>
    </Modal>
  );
}
