import { Fragment, useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { ChevronDown, ChevronRight, GripVertical } from 'lucide-react';
import {
  DndContext,
  closestCenter,
  PointerSensor,
  KeyboardSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core';
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import { rpc } from '@/lib/rpc';
import { useDomain, useDomainNow } from '@/lib/domain';
import { useCohorts, useInstructors, useSettingsMap, useWeeks, type WeekRow } from '@/lib/data';
import { ActionMenu } from '@/components/ActionMenu';
import { ago, fmtLocal } from '@/lib/time';
import { fmtAt, fmtDay, weekRegion } from '@/lib/region';
import { weekState } from '@/lib/status';
import { plain } from '@/lib/plain';
import { supabase } from '@/lib/supabase';
import { check } from '@/lib/rpc';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Empty,
  ErrorText,
  Field,
  Modal,
  Notice,
  PageHeader,
  Select,
  Skeleton,
  SkeletonRows,
  Stat,
  tableWrap,
  td,
  th,
  thead,
  trow,
} from '@/components/ui';
import { ClassDrawer, useRun } from './ClassDrawer';

type Preview = {
  asking: { name: string; sent_at: string; reminded: boolean; deadline_at: string } | null;
  next: string | null;
  line: { instructor_id: string; name: string; reason: string | null }[];
};
type Eligible = {
  instructor_id: string;
  name: string;
  rank: number | null;
  in_ranking: boolean;
  reason: string | null;
  warning: string | null;
  is_test: boolean;
};

const OPEN = ['Queued', 'Sent', 'Reminded'];
const label = (w: WeekRow, showCohort: boolean) =>
  `${w.module?.name}${showCohort ? ` (${w.cohort})` : ''} · ${[...w.class_session]
    .filter((c) => c.status !== 'Cancelled')
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at))
    .map((c) => fmtDay(c.starts_at, c.region))
    .join(' + ')}`;

export default function Outreach() {
  const { domain } = useDomain();
  const weeks = useWeeks(domain?.id);
  const instructors = useInstructors();
  const settings = useSettingsMap(domain?.id);
  const confirm = useConfirm();
  const { run, err } = useRun();
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [manualFor, setManualFor] = useState<WeekRow | null>(null);
  const [drawer, setDrawer] = useState<string | null>(null);
  const [askFor, setAskFor] = useState<WeekRow | null>(null);
  const [focus, setFocus] = useState<'' | 'asking' | 'confirmed' | 'risk' | 'needs' | 'help'>('');
  const [cohortId, setCohortId] = useState('');
  const cohorts = useCohorts(domain?.id);
  const manyCohorts = (cohorts.data ?? []).length > 1;
  const toggleFocus = (f: typeof focus) => setFocus((x) => (x === f ? '' : f));
  const names = useMemo(
    () => new Map((instructors.data ?? []).map((i) => [i.id, i.full_name])),
    [instructors.data],
  );
  const domainNow = useDomainNow();
  const now = domainNow.toUTC().toISO()!;

  const upcoming = (weeks.data ?? []).filter(
    (w) =>
      !['Completed', 'Cancelled'].includes(w.status) &&
      (w.last_class_end_at ?? '') > now &&
      (!cohortId || w.cohort_id === cohortId),
  );
  const isAsking = (w: WeekRow) =>
    w.request.some((r) => r.kind === 'Outreach' && OPEN.includes(r.status));
  const hasHelp = (w: WeekRow) =>
    w.help_request.some((h) => ['Open', 'InProgress', 'WaitingOnInstructor'].includes(h.status));
  const matchesFocus = (w: WeekRow) =>
    focus === ''
      ? true
      : focus === 'asking'
        ? isAsking(w)
        : focus === 'risk'
          ? w.at_risk
          : focus === 'needs'
            ? w.status === 'NeedsInstructor'
            : focus === 'help'
              ? hasHelp(w)
              : true;
  const allFinding = upcoming.filter((w) => !w.booking.some((b) => b.status === 'Active'));
  const allConfirmed = upcoming.filter((w) => w.booking.some((b) => b.status === 'Active'));
  const finding = focus === 'confirmed' ? [] : allFinding.filter(matchesFocus);
  const confirmed = ['asking', 'needs'].includes(focus) ? [] : allConfirmed.filter(matchesFocus);

  const previews = useQuery({
    queryKey: [
      'request',
      'previews',
      domain?.id,
      finding.map((w) => `${w.id}:${w.version}`).join(),
    ],
    enabled: finding.length > 0,
    queryFn: async () =>
      Object.fromEntries(
        await Promise.all(
          finding.map(async (w) => [
            w.id,
            (await rpc('preview_next', { p_module_week_id: w.id })) as unknown as Preview,
          ]),
        ),
      ) as Record<string, Preview>,
  });

  const checkinMsgs = useQuery({
    queryKey: ['message', 'checkins', domain?.id],
    enabled: confirmed.length > 0,
    queryFn: async () =>
      check(
        await supabase
          .from('message')
          .select('id, module_week_id, request_id, template_id, created_at')
          .in('template_id', ['M6', 'M7', 'M8'])
          .in(
            'module_week_id',
            confirmed.map((w) => w.id),
          )
          .order('created_at', { ascending: false }),
      ),
  });

  const helpOpen = (weeks.data ?? []).filter((w) =>
    w.help_request.some((h) => ['Open', 'InProgress', 'WaitingOnInstructor'].includes(h.status)),
  ).length;
  const checkinDays = ((settings.data?.checkin_days as number[] | undefined) ?? [10, 2])
    .slice()
    .sort((a, b) => b - a);

  const statusOf = (w: WeekRow, p?: Preview) => {
    if (w.paused) return <Badge tone="accent">Requests paused</Badge>;
    if (w.status === 'NeedsInstructor') return <Badge tone="danger">Needs an instructor</Badge>;
    if (w.status === 'NotReady') return <Badge tone="warning">Setup not finished</Badge>;
    if (w.status === 'Planned') return <Badge tone="neutral">Not started yet</Badge>;
    if (p?.asking && !p.next) return <Badge tone="warning">Last person to ask</Badge>;
    if (p?.asking) return <Badge tone="info">Waiting for a reply</Badge>;
    return <Badge tone="neutral">{w.at_risk ? 'At risk' : 'Ready to ask'}</Badge>;
  };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Instructor requests"
        description="Who we are asking to teach each class week, and the confirmed classes with their reminders. Select a card to show only those class weeks."
      >
        {(cohorts.data ?? []).length > 1 && (
          <Select
            aria-label="Cohort"
            value={cohortId}
            onChange={(e) => setCohortId(e.target.value)}
            className="w-56"
          >
            <option value="">All cohorts</option>
            {(cohorts.data ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
        )}
      </PageHeader>
      <div className="flex flex-wrap gap-3">
        <Stat
          label="Asking now"
          value={allFinding.filter(isAsking).length}
          tone="info"
          hint="Waiting for a reply"
          onClick={() => toggleFocus('asking')}
          active={focus === 'asking'}
        />
        <Stat
          label="Confirmed"
          value={allConfirmed.length}
          tone="success"
          hint="Instructor said yes"
          onClick={() => toggleFocus('confirmed')}
          active={focus === 'confirmed'}
        />
        <Stat
          label="At risk"
          value={upcoming.filter((w) => w.at_risk).length}
          tone="warning"
          hint="Close to the class and not settled"
          onClick={() => toggleFocus('risk')}
          active={focus === 'risk'}
        />
        <Stat
          label="Need an instructor"
          value={upcoming.filter((w) => w.status === 'NeedsInstructor').length}
          tone="danger"
          hint="Nobody left to ask"
          onClick={() => toggleFocus('needs')}
          active={focus === 'needs'}
        />
        <Stat
          label="Open help requests"
          value={helpOpen}
          tone="accent"
          hint="From instructors"
          onClick={() => toggleFocus('help')}
          active={focus === 'help'}
        />
      </div>
      {focus && (
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          Showing only some class weeks.
          <Button size="sm" variant="ghost" onClick={() => setFocus('')}>
            Show all
          </Button>
        </div>
      )}
      <ErrorText error={err} />

      <section>
        <div className="mb-3">
          <h2 className="text-base font-semibold">Still looking for an instructor</h2>
          <p className="text-sm text-muted-foreground">
            Instructors are asked one at a time. Open a row to see everyone asked so far.
          </p>
        </div>
        {weeks.isLoading ? (
          <SkeletonRows rows={4} />
        ) : finding.length === 0 ? (
          <Empty title="Every upcoming class week has an instructor">
            Nothing to follow up right now.
          </Empty>
        ) : (
          <div className={tableWrap}>
            <table className="w-full">
              <thead className={thead}>
                <tr>
                  <th className={th}>
                    <span className="sr-only">Show everyone asked</span>
                  </th>
                  <th className={`${th} min-w-44`}>Class week</th>
                  <th className={`${th} hidden lg:table-cell`}>Who to ask</th>
                  <th className={th}>Asking now</th>
                  <th className={`${th} hidden md:table-cell`}>Moves on</th>
                  <th className={`${th} hidden md:table-cell`}>Next to ask</th>
                  <th className={th}>Status</th>
                  <th className={th}>
                    <span className="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {finding.map((w) => {
                  const p = previews.data?.[w.id];
                  const open = expanded.has(w.id);
                  const asked = w.request
                    .filter((r) => r.kind === 'Outreach')
                    .sort((a, b) => a.created_at.localeCompare(b.created_at));
                  return (
                    <Fragment key={w.id}>
                      <tr className={trow}>
                        <td className={td}>
                          <button
                            className="rounded p-0.5 text-muted-foreground hover:bg-muted hover:text-foreground"
                            aria-expanded={open}
                            aria-label={open ? 'Hide everyone asked' : 'Show everyone asked'}
                            onClick={() => {
                              const n = new Set(expanded);
                              if (open) n.delete(w.id);
                              else n.add(w.id);
                              setExpanded(n);
                            }}
                          >
                            {open ? (
                              <ChevronDown className="h-4 w-4" />
                            ) : (
                              <ChevronRight className="h-4 w-4" />
                            )}
                          </button>
                        </td>
                        <td className={td}>
                          <button
                            className="text-left font-medium text-link hover:underline"
                            onClick={() => setDrawer(w.id)}
                          >
                            {label(w, manyCohorts)}
                          </button>
                          {w.at_risk && (
                            <div className="text-xs text-danger-strong">
                              At risk: {w.at_risk_reason}
                            </div>
                          )}
                        </td>
                        <td className={`${td} hidden text-xs lg:table-cell`}>
                          {w.outreach_mode === 'Manual' ? 'Chosen list' : 'Instructor order'}
                        </td>
                        <td className={td}>
                          {p?.asking ? (
                            <>
                              {p.asking.name}
                              <div className="text-xs text-muted-foreground">
                                asked {ago(p.asking.sent_at, domainNow)} ago
                                {p.asking.reminded ? ', reminded' : ''}
                              </div>
                            </>
                          ) : (
                            <span className="text-muted-foreground">Nobody yet</span>
                          )}
                        </td>
                        <td className={`${td} hidden text-xs md:table-cell`}>
                          {p?.asking ? (
                            fmtAt(p.asking.deadline_at, weekRegion(w.class_session))
                          ) : (
                            <span className="text-muted-foreground">Not yet</span>
                          )}
                        </td>
                        <td className={`${td} hidden md:table-cell`}>
                          {p ? (
                            (p.next ?? <span className="text-danger-strong">Nobody left</span>)
                          ) : (
                            <Skeleton className="h-4 w-24" />
                          )}
                        </td>
                        <td className={td}>{statusOf(w, p)}</td>
                        <td className={td}>
                          <div className="flex flex-wrap gap-1">
                            {!p?.asking &&
                              !w.paused &&
                              ['Ready', 'Planned', 'NotReady', 'NeedsInstructor'].includes(
                                w.status,
                              ) && (
                                <Button
                                  size="sm"
                                  variant="secondary"
                                  onClick={() =>
                                    run(
                                      () => rpc('start_asking_now', { p_module_week_id: w.id }),
                                      'Asking now',
                                    )
                                  }
                                >
                                  Start asking now
                                </Button>
                              )}
                            <Button
                              size="sm"
                              variant="secondary"
                              hidden={!p?.asking}
                              onClick={async () => {
                                if (
                                  await confirm({
                                    title: `Skip ${p?.asking?.name}?`,
                                    body: 'Their request is withdrawn politely and the next instructor in line is asked.',
                                    confirmLabel: 'Ask the next instructor',
                                  })
                                )
                                  await run(
                                    () => rpc('skip_to_next', { p_module_week_id: w.id }),
                                    'Asked the next instructor',
                                  );
                              }}
                            >
                              Ask the next instructor
                            </Button>
                            <ActionMenu
                              items={[
                                {
                                  label: 'Change the order for this class week',
                                  onSelect: () => setManualFor(w),
                                },
                                { label: 'Ask a specific person', onSelect: () => setAskFor(w) },
                                { label: 'Assign an instructor', onSelect: () => setDrawer(w.id) },
                                {
                                  label: 'Record a phone or chat confirmation',
                                  onSelect: () => setDrawer(w.id),
                                },
                                {
                                  label: w.paused ? 'Resume requests' : 'Pause requests',
                                  onSelect: () =>
                                    void run(
                                      () =>
                                        rpc('pause_outreach', {
                                          p_module_week_id: w.id,
                                          p_paused: !w.paused,
                                        }),
                                      w.paused ? 'Requests resumed' : 'Requests paused',
                                    ),
                                },
                              ]}
                            />
                          </div>
                        </td>
                      </tr>
                      {open && (
                        <tr className="border-b border-border bg-muted/40">
                          <td></td>
                          <td colSpan={7} className="px-2 py-2 text-sm">
                            {asked.length === 0 ? (
                              <span className="text-muted-foreground">Nobody asked yet.</span>
                            ) : (
                              <ol className="list-decimal space-y-0.5 pl-5">
                                {asked.map((r) => (
                                  <li key={r.id}>
                                    <strong>{names.get(r.instructor_id ?? '')}</strong>: asked{' '}
                                    {fmtLocal(r.sent_at)} ·{' '}
                                    {r.status === 'Accepted'
                                      ? 'said yes'
                                      : r.status === 'Declined'
                                        ? `declined${r.close_reason && r.close_reason !== 'Declined' ? ` (${r.close_reason})` : ''}`
                                        : r.status === 'Expired'
                                          ? 'no reply'
                                          : r.status === 'Withdrawn'
                                            ? `withdrawn (${r.close_reason})`
                                            : r.status === 'Reminded'
                                              ? 'reminded, waiting'
                                              : 'waiting'}
                                  </li>
                                ))}
                              </ol>
                            )}
                            {p && (
                              <div className="mt-2 text-xs text-muted-foreground">
                                Order for this week:{' '}
                                {p.line.map((l) => (
                                  <span
                                    key={l.instructor_id}
                                    className={l.reason ? 'text-muted-foreground' : ''}
                                  >
                                    {l.name}
                                    {l.reason ? ` (${l.reason})` : ''} ·{' '}
                                  </span>
                                ))}
                              </div>
                            )}
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section>
        <div className="mb-3">
          <h2 className="text-base font-semibold">Confirmed classes</h2>
          <p className="text-sm text-muted-foreground">
            Confirmed instructors get a reminder before class and can say they are all set or need
            help.
          </p>
        </div>
        {weeks.isLoading ? (
          <SkeletonRows rows={3} />
        ) : confirmed.length === 0 ? (
          <Empty title="No confirmed class weeks coming up" />
        ) : (
          <div className={tableWrap}>
            <table className="w-full">
              <thead className={thead}>
                <tr>
                  <th className={`${th} min-w-44`}>Class week</th>
                  <th className={th}>Instructor</th>
                  {checkinDays.map((d) => (
                    <th key={d} className={th}>
                      Reminder {d} day{d === 1 ? '' : 's'} before
                    </th>
                  ))}
                  <th className={th}>
                    <span className="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {confirmed.map((w) => {
                  const st = weekState(w, names);
                  const booking = w.booking.find((b) => b.status === 'Active')!;
                  const lastCheckin = checkinMsgs.data?.find((m) => m.module_week_id === w.id);
                  return (
                    <tr key={w.id} className={trow}>
                      <td className={td}>
                        <button
                          className="text-left font-medium text-link hover:underline"
                          onClick={() => setDrawer(w.id)}
                        >
                          {label(w, manyCohorts)}
                        </button>
                        {w.at_risk && (
                          <div className="text-xs text-danger-strong">
                            At risk: {w.at_risk_reason}
                          </div>
                        )}
                      </td>
                      <td className={td}>{st.confirmed}</td>
                      {checkinDays.map((d) => {
                        const r = w.request.find(
                          (x) =>
                            x.kind === 'CheckIn' &&
                            x.check_in_days === d &&
                            x.booking_id === booking.id,
                        );
                        const v = !r
                          ? ['Not sent yet', 'neutral']
                          : r.answer === 'AllSet'
                            ? ['All set', 'success']
                            : r.answer === 'NeedHelp'
                              ? ['Needs help', 'warning']
                              : r.status === 'Expired'
                                ? ['No reply', 'danger']
                                : r.status === 'Superseded'
                                  ? ['Skipped', 'neutral']
                                  : [r.status === 'Reminded' ? 'Sent twice' : 'Sent', 'info'];
                        return (
                          <td key={d} className={td}>
                            <Badge tone={v[1] as 'neutral'}>{v[0]}</Badge>
                          </td>
                        );
                      })}
                      <td className={td}>
                        <div className="flex flex-wrap gap-1">
                          <Button size="sm" variant="secondary" onClick={() => setDrawer(w.id)}>
                            Change instructor
                          </Button>
                          <Button
                            size="sm"
                            variant="ghost"
                            disabled={!lastCheckin}
                            onClick={() =>
                              run(
                                () => rpc('resend_message', { p_message_id: lastCheckin!.id }),
                                'Reminder sent again',
                              )
                            }
                          >
                            Send reminder again
                          </Button>
                          <Button
                            size="sm"
                            variant="destructive"
                            onClick={async () => {
                              if (
                                await confirm({
                                  title: `Release ${st.confirmed ?? 'this instructor'}?`,
                                  body: 'The instructor is told politely, and we start asking other instructors for this class week.',
                                  danger: true,
                                  confirmLabel: 'Release and find a replacement',
                                })
                              )
                                await run(
                                  () => rpc('release_booking', { p_module_week_id: w.id }),
                                  'Instructor released',
                                );
                            }}
                          >
                            Release
                          </Button>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
      {manualFor && <ManualPanel week={manualFor} onClose={() => setManualFor(null)} />}
      {askFor && <AskPersonDialog week={askFor} onClose={() => setAskFor(null)} />}
      {drawer && (weeks.data ?? []).find((w) => w.id === drawer) && (
        <ClassDrawer
          week={(weeks.data ?? []).find((w) => w.id === drawer)!}
          names={names}
          onClose={() => setDrawer(null)}
        />
      )}
    </div>
  );
}

function Sortable({ id, children }: { id: string; children: React.ReactNode }) {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({ id });
  return (
    <li
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className="flex items-center gap-2 rounded border bg-card px-2 py-1 text-sm"
    >
      <button
        {...attributes}
        {...listeners}
        className="cursor-grab text-muted-foreground"
        aria-label="Drag to reorder"
      >
        <GripVertical className="h-4 w-4" />
      </button>
      {children}
    </li>
  );
}

/** Manual selection panel (PRD 7.5): tick, order, end-of-list choice, keep-or-withdraw prompt. */
function ManualPanel({ week, onClose }: { week: WeekRow; onClose: () => void }) {
  const { run, err } = useRun();
  const list = useQuery({
    queryKey: ['request', 'eligibility', week.id],
    queryFn: async () =>
      (await rpc('week_eligibility', { p_module_week_id: week.id })) as unknown as Eligible[],
  });
  const [order, setOrder] = useState<string[]>(() =>
    [...week.manual_queue_item]
      .filter((q) => !q.asked_request_id)
      .sort((a, b) => a.position - b.position)
      .map((q) => q.instructor_id),
  );
  const [end, setEnd] = useState(week.manual_end_behaviour);
  const [decision, setDecision] = useState<{
    asking: string;
    mode: 'Manual' | 'Sequential';
  } | null>(null);
  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );
  const byId = new Map((list.data ?? []).map((i) => [i.instructor_id, i]));
  const blocked = (i: Eligible) => !!i.reason && i.reason !== 'Being asked now';

  const submit = async (mode: 'Manual' | 'Sequential', d?: 'keep' | 'withdraw') => {
    const res = (await run(() =>
      rpc('set_outreach_queue', {
        p_module_week_id: week.id,
        p_mode: mode,
        p_instructor_ids: mode === 'Manual' ? order : undefined,
        p_end_behaviour: end,
        p_decision: d,
        p_start_now: true,
      }),
    )) as { needs_decision?: boolean; asking?: string } | undefined;
    if (res?.needs_decision) setDecision({ asking: res.asking ?? 'someone', mode });
    else if (res) onClose();
  };

  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="Choose who to ask"
      description="Ticked instructors are asked one at a time, in the order below."
      wide
    >
      {list.isLoading ? (
        <SkeletonRows rows={5} />
      ) : (
        <div className="grid gap-4 md:grid-cols-2">
          <div className="max-h-96 space-y-1 overflow-y-auto">
            {(list.data ?? []).map((i) => (
              <label
                key={i.instructor_id}
                className={`flex items-start gap-2 rounded px-1 py-0.5 text-sm ${blocked(i) ? 'text-muted-foreground' : ''}`}
              >
                <input
                  type="checkbox"
                  className="mt-1"
                  disabled={blocked(i)}
                  checked={order.includes(i.instructor_id)}
                  onChange={(e) =>
                    setOrder(
                      e.target.checked
                        ? [...order, i.instructor_id]
                        : order.filter((x) => x !== i.instructor_id),
                    )
                  }
                />
                <span>
                  {i.name}{' '}
                  {i.rank ? (
                    <span className="text-xs text-muted-foreground">
                      {i.rank === 1 ? 'Primary' : `Backup ${i.rank - 1}`}
                    </span>
                  ) : (
                    <Badge>Not in this module's instructor order</Badge>
                  )}
                  {i.is_test && <Badge tone="accent">Test</Badge>}
                  {i.reason && <div className="text-xs">{plain(i.reason)}</div>}
                  {!i.reason && i.warning && (
                    <div className="text-xs text-warning-strong">{plain(i.warning)}</div>
                  )}
                </span>
              </label>
            ))}
          </div>
          <div>
            <h3 className="mb-1 text-sm font-medium">Order to ask (drag to change)</h3>
            {order.length === 0 ? (
              <p className="text-sm text-muted-foreground">Tick instructors on the left.</p>
            ) : (
              <DndContext
                sensors={sensors}
                collisionDetection={closestCenter}
                onDragEnd={(e: DragEndEvent) => {
                  if (e.over && e.active.id !== e.over.id)
                    setOrder((o) =>
                      arrayMove(o, o.indexOf(String(e.active.id)), o.indexOf(String(e.over!.id))),
                    );
                }}
              >
                <SortableContext items={order} strategy={verticalListSortingStrategy}>
                  <ol className="space-y-1">
                    {order.map((id, idx) => (
                      <Sortable key={id} id={id}>
                        <span className="w-5 text-xs text-muted-foreground">{idx + 1}.</span>
                        {byId.get(id)?.name}
                      </Sortable>
                    ))}
                  </ol>
                </SortableContext>
              </DndContext>
            )}
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
            <div className="mt-3 flex flex-wrap gap-2">
              <Button disabled={order.length === 0} onClick={() => void submit('Manual')}>
                Start asking
              </Button>
              <Button variant="secondary" onClick={() => void submit('Sequential')}>
                Use the instructor order instead
              </Button>
            </div>
          </div>
        </div>
      )}
      <Modal
        open={!!decision}
        onOpenChange={(o) => !o && setDecision(null)}
        title={`${decision?.asking} is being asked right now`}
      >
        <p className="mb-4 text-sm text-muted-foreground">
          Keep waiting for their answer, or withdraw the request politely and start the new list
          now?
        </p>
        <div className="flex justify-end gap-2">
          <Button
            variant="secondary"
            onClick={() => (setDecision(null), void submit(decision!.mode, 'keep'))}
          >
            Keep waiting
          </Button>
          <Button onClick={() => (setDecision(null), void submit(decision!.mode, 'withdraw'))}>
            Withdraw and start the new list
          </Button>
        </div>
      </Modal>
    </Modal>
  );
}

/** Ask one chosen instructor now; if nobody says yes, the usual instructor order continues. */
function AskPersonDialog({ week, onClose }: { week: WeekRow; onClose: () => void }) {
  const { run, err, busy } = useRun();
  const confirm = useConfirm();
  const list = useQuery({
    queryKey: ['request', 'eligibility', week.id],
    queryFn: async () =>
      (await rpc('week_eligibility', { p_module_week_id: week.id })) as unknown as Eligible[],
  });
  const [id, setId] = useState('');
  const choice = (list.data ?? []).find((i) => i.instructor_id === id);
  const send = async (decision?: 'keep' | 'withdraw') =>
    (await run(() =>
      rpc('set_outreach_queue', {
        p_module_week_id: week.id,
        p_mode: 'Manual',
        p_instructor_ids: [id],
        p_end_behaviour: 'ContinueWithRanking',
        p_decision: decision,
        p_start_now: true,
      }),
    )) as { needs_decision?: boolean; asking?: string } | undefined;
  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="Ask a specific person"
      description="They are asked now. If they say no or do not reply, the usual instructor order continues."
    >
      {list.isLoading ? (
        <SkeletonRows rows={3} />
      ) : (
        <Field label="Instructor">
          <Select value={id} onChange={(e) => setId(e.target.value)}>
            <option value="">Choose an instructor</option>
            {(list.data ?? []).map((i) => (
              <option
                key={i.instructor_id}
                value={i.instructor_id}
                disabled={!!i.reason && i.reason !== 'Being asked now'}
              >
                {i.name}
                {i.rank ? ` (${i.rank === 1 ? 'Primary' : `Backup ${i.rank - 1}`})` : ''}
                {i.reason ? `: ${plain(i.reason)}` : ''}
              </option>
            ))}
          </Select>
        </Field>
      )}
      {choice && (!choice.in_ranking || choice.warning) && (
        <Notice tone="warning">
          {!choice.in_ranking && 'This person is not in the instructor order for this module. '}
          {choice.warning && plain(choice.warning)}
        </Notice>
      )}
      <ErrorText error={err} />
      <div className="mt-4 flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Cancel
        </Button>
        <Button
          disabled={!id}
          loading={busy}
          onClick={async () => {
            let res = await send();
            if (res?.needs_decision) {
              const withdraw = await confirm({
                title: `${res.asking ?? 'Someone'} is being asked right now`,
                body: 'Withdraw that request politely and ask your chosen person now? Choose Cancel to keep waiting for their answer first.',
                confirmLabel: 'Withdraw and ask now',
              });
              res = await send(withdraw ? 'withdraw' : 'keep');
            }
            if (res) onClose();
          }}
        >
          Ask now
        </Button>
      </div>
    </Modal>
  );
}
