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
import { Download, LifeBuoy, Plus } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useInstructors, useModules, useWeeks, type WeekRow } from '@/lib/data';
import { fmtPTRange, PT } from '@/lib/time';
import { weekState } from '@/lib/status';
import { downloadCsv, toCsv } from '@/lib/csv';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Checkbox,
  Empty,
  ErrorText,
  Input,
  Modal,
  PageHeader,
  Select,
  Spinner,
  td,
  th,
} from '@/components/ui';
import { PlanDialog } from './PlanDialog';
import { ClassDrawer, useRun } from './ClassDrawer';

type Row = {
  week: WeekRow;
  cls: WeekRow['class_session'][number];
  first: boolean;
  holiday: string | null;
};
const col = createColumnHelper<Row>();

export default function Schedule() {
  const { domain } = useDomain();
  const weeks = useWeeks(domain?.id);
  const instructors = useInstructors();
  const modules = useModules(domain?.id);
  const confirm = useConfirm();
  const { run, err } = useRun();
  const [planning, setPlanning] = useState(false);
  const [openWeek, setOpenWeek] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [showPast, setShowPast] = useState(false);
  const [moduleFilter, setModuleFilter] = useState('');
  const [search, setSearch] = useState('');
  const [queueFor, setQueueFor] = useState<string[] | null>(null);
  const [shiftN, setShiftN] = useState(1);

  const names = useMemo(
    () => new Map((instructors.data ?? []).map((i) => [i.id, i.full_name])),
    [instructors.data],
  );
  const holidays = useQuery({
    queryKey: ['holiday'],
    queryFn: async () => check(await supabase.from('holiday').select('*')),
  });
  const holidayMap = useMemo(
    () => new Map((holidays.data ?? []).map((h) => [h.date, h.name])),
    [holidays.data],
  );
  const weekIds = (weeks.data ?? []).map((w) => w.id);
  const checklist = useQuery({
    queryKey: ['checklist_item', 'grid', domain?.id, weekIds.length],
    enabled: weekIds.length > 0,
    queryFn: async () =>
      check(
        await supabase
          .from('checklist_item')
          .select('class_id, done, class_session!inner(module_week_id)')
          .in('class_session.module_week_id', weekIds),
      ),
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

  const rows = useMemo<Row[]>(() => {
    const today = DateTime.now().setZone(PT).toISODate()!;
    const out: Row[] = [];
    for (const w of weeks.data ?? []) {
      if (
        !showPast &&
        (['Completed', 'Cancelled'].includes(w.status) ||
          DateTime.fromISO(w.week_start_date).plus({ days: 7 }).toISODate()! < today)
      )
        continue;
      if (moduleFilter && w.module_id !== moduleFilter) continue;
      const classes = [...w.class_session].sort((a, b) => a.starts_at.localeCompare(b.starts_at));
      classes.forEach((c, idx) => {
        const date = DateTime.fromISO(c.starts_at).setZone(PT).toISODate()!;
        out.push({ week: w, cls: c, first: idx === 0, holiday: holidayMap.get(date) ?? null });
      });
    }
    return out;
  }, [weeks.data, showPast, moduleFilter, holidayMap]);

  const columns = useMemo(
    () => [
      col.display({
        id: 'select',
        header: '',
        cell: ({ row }) =>
          row.original.first ? (
            <input
              type="checkbox"
              aria-label="Select module week"
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
      col.accessor((r) => fmtPTRange(r.cls.starts_at, r.cls.ends_at), {
        id: 'when',
        header: 'Date, time (PT)',
        cell: ({ row, getValue }) => (
          <span
            className={
              row.original.cls.status === 'Cancelled' ? 'text-muted-foreground line-through' : ''
            }
          >
            {getValue()}
            {row.original.holiday && (
              <span className="ml-1">
                <Badge tone="amber">Holiday: {row.original.holiday}</Badge>
              </span>
            )}
          </span>
        ),
      }),
      col.accessor((r) => r.week.module?.name ?? '', { id: 'module', header: 'Module' }),
      col.accessor((r) => r.cls.class_type, { id: 'type', header: 'Class type' }),
      col.accessor((r) => r.cls.title, { id: 'title', header: 'Title' }),
      col.accessor((r) => r.week.cohort, { id: 'cohort', header: 'Cohort' }),
      col.accessor((r) => weekState(r.week, names).label, {
        id: 'status',
        header: 'Outreach status',
        cell: ({ row }) => {
          if (!row.original.first) return null;
          const s = weekState(row.original.week, names);
          return <Badge tone={s.tone}>{s.label}</Badge>;
        },
      }),
      col.accessor((r) => weekState(r.week, names).confirmed ?? '', {
        id: 'confirmed',
        header: 'Confirmed instructor',
        cell: ({ row, getValue }) => (row.original.first ? getValue() : null),
      }),
      col.accessor(
        (r) =>
          r.week.outreach_mode === 'Manual'
            ? [...r.week.manual_queue_item]
                .filter((q) => !q.asked_request_id)
                .sort((a, b) => a.position - b.position)
                .map((q) => names.get(q.instructor_id))
                .join(' → ') || 'Manual list empty'
            : 'From ranking',
        {
          id: 'toask',
          header: 'Instructors to ask',
          cell: ({ row, getValue }) =>
            row.original.first ? <span className="text-xs">{getValue()}</span> : null,
        },
      ),
      col.accessor((r) => r.week.outreach_mode, {
        id: 'mode',
        header: 'Mode',
        cell: ({ row, getValue }) => (row.original.first ? getValue() : null),
      }),
      col.accessor(
        (r) => {
          const c = checklistByWeek.get(r.week.id);
          return c ? `${c.done} of ${c.total}` : '';
        },
        {
          id: 'checklist',
          header: 'Checklist',
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
    [selected, names, checklistByWeek],
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

  const exportCsv = () =>
    downloadCsv(
      `schedule-${domain?.name}-${DateTime.now().toFormat('yyyy-LL-dd')}.csv`,
      toCsv(
        table.getFilteredRowModel().rows.map(({ original: r }) => {
          const s = weekState(r.week, names);
          return {
            date_time_pt: fmtPTRange(r.cls.starts_at, r.cls.ends_at),
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

  const open = (weeks.data ?? []).find((w) => w.id === openWeek);

  return (
    <div>
      <PageHeader title={`Schedule${domain ? ` — ${domain.name}` : ''}`}>
        <Input
          placeholder="Search"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="w-44"
        />
        <Select
          value={moduleFilter}
          onChange={(e) => setModuleFilter(e.target.value)}
          className="w-44"
        >
          <option value="">All modules</option>
          {(modules.data ?? []).map((m) => (
            <option key={m.id} value={m.id}>
              {m.name}
            </option>
          ))}
        </Select>
        <Checkbox label="Show past & cancelled" checked={showPast} onChange={setShowPast} />
        <Button variant="outline" onClick={exportCsv} disabled={rows.length === 0}>
          <Download className="h-4 w-4" /> Download as sheet
        </Button>
        <Button onClick={() => setPlanning(true)} disabled={!domain}>
          <Plus className="h-4 w-4" /> Plan classes
        </Button>
      </PageHeader>

      {selected.size > 0 && (
        <div className="mb-3 flex flex-wrap items-center gap-2 rounded-lg border border-primary bg-info-soft p-2 text-sm">
          <strong>{selected.size} module week(s) selected:</strong>
          <Button size="sm" variant="outline" onClick={() => setQueueFor([...selected])}>
            Set instructors to ask
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
                'Filled from rankings',
              )
            }
          >
            Fill from rankings
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
                'Mode set to Manual',
              )
            }
          >
            Set mode: Manual
          </Button>
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              forEachWeek(
                (w) => rpc('pause_outreach', { p_module_week_id: w.id, p_paused: true }),
                'Paused',
              )
            }
          >
            Pause
          </Button>
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              forEachWeek(
                (w) => rpc('pause_outreach', { p_module_week_id: w.id, p_paused: false }),
                'Resumed',
              )
            }
          >
            Resume
          </Button>
          <span className="flex items-center gap-1">
            <Input
              type="number"
              value={shiftN}
              onChange={(e) => setShiftN(Number(e.target.value))}
              className="h-8 w-16"
            />
            <Button
              size="sm"
              variant="outline"
              onClick={async () => {
                if (
                  !(await confirm({
                    title: `Shift ${selected.size} module week(s) by ${shiftN} week(s)?`,
                    body: 'Only the selected weeks move. Confirmed instructors are asked to confirm the new time.',
                  }))
                )
                  return;
                const ordered = [...selectedWeeks].sort((a, b) =>
                  shiftN > 0
                    ? b.week_start_date.localeCompare(a.week_start_date)
                    : a.week_start_date.localeCompare(b.week_start_date),
                );
                await run(async () => {
                  for (const w of ordered)
                    await rpc('shift_classes', {
                      p_module_week_id: w.id,
                      p_weeks: shiftN,
                      p_include_later: false,
                    });
                }, 'Shifted');
                setSelected(new Set());
              }}
            >
              Shift dates
            </Button>
          </span>
          <Button
            size="sm"
            variant="danger"
            onClick={async () => {
              if (
                await confirm({
                  title: `Cancel ${selected.size} module week(s)?`,
                  body: 'Requests are withdrawn and confirmed instructors are told.',
                  danger: true,
                  confirmLabel: 'Cancel classes',
                })
              )
                await forEachWeek(
                  (w) => rpc('cancel_module_week', { p_module_week_id: w.id }),
                  'Cancelled',
                );
            }}
          >
            Cancel classes
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setSelected(new Set())}>
            Clear
          </Button>
        </div>
      )}
      <ErrorText error={err} />

      {weeks.isLoading ? (
        <Spinner />
      ) : rows.length === 0 ? (
        <Empty title="No classes planned">
          Use “Plan classes” to create module weeks from the class pattern.
        </Empty>
      ) : (
        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full">
            <thead className="border-b bg-muted">
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

/** Bulk "Set instructors to ask": a manual queue in the order ticked. */
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
      title="Set instructors to ask"
      description="Tick instructors in the order they should be asked (one at a time). Applied to the selected module weeks; anyone being asked right now keeps their request."
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
            {order.includes(i.id) && <Badge tone="blue">{order.indexOf(i.id) + 1}</Badge>}
            {i.full_name}
            {!i.verified_at && <Badge tone="amber">Not verified</Badge>}
          </label>
        ))}
      </div>
      <div className="mt-3 flex items-center gap-2 text-sm">
        When the list runs out:
        <Select value={end} onChange={(e) => setEnd(e.target.value)} className="w-56">
          <option value="Stop">Stop and alert me</option>
          <option value="ContinueWithRanking">Continue with the ranking</option>
        </Select>
      </div>
      <ErrorText error={err} />
      <div className="mt-3 flex justify-end gap-2">
        <Button variant="outline" onClick={onDone}>
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
            }, 'Instructors to ask saved');
            onDone();
          }}
        >
          Save
        </Button>
      </div>
    </Modal>
  );
}
