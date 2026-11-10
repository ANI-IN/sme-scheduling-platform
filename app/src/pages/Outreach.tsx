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
import { useInstructors, useSettingsMap, useWeeks, type WeekRow } from '@/lib/data';
import { ago, fmtLocal, fmtPT } from '@/lib/time';
import { weekState } from '@/lib/status';
import { supabase } from '@/lib/supabase';
import { check } from '@/lib/rpc';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Empty,
  ErrorText,
  Modal,
  PageHeader,
  Select,
  Spinner,
  Stat,
  td,
  th,
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
const label = (w: WeekRow) =>
  `${w.module?.name}${w.cohort ? ` (${w.cohort})` : ''} · ${[...w.class_session]
    .filter((c) => c.status !== 'Cancelled')
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at))
    .map((c) => fmtPT(c.starts_at).split(',')[0])
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
  const names = useMemo(
    () => new Map((instructors.data ?? []).map((i) => [i.id, i.full_name])),
    [instructors.data],
  );
  const domainNow = useDomainNow();
  const now = domainNow.toUTC().toISO()!;

  const upcoming = (weeks.data ?? []).filter(
    (w) => !['Completed', 'Cancelled'].includes(w.status) && (w.last_class_end_at ?? '') > now,
  );
  const finding = upcoming.filter((w) => !w.booking.some((b) => b.status === 'Active'));
  const confirmed = upcoming.filter((w) => w.booking.some((b) => b.status === 'Active'));

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
    if (w.paused) return <Badge tone="purple">Paused</Badge>;
    if (w.status === 'NeedsInstructor') return <Badge tone="red">Needs instructor</Badge>;
    if (['Planned', 'NotReady'].includes(w.status)) return <Badge tone="amber">Not ready</Badge>;
    if (p?.asking && !p.next) return <Badge tone="amber">Last option</Badge>;
    if (p?.asking) return <Badge tone="blue">Waiting</Badge>;
    return <Badge tone="gray">{w.at_risk ? 'At risk' : 'Ready'}</Badge>;
  };

  return (
    <div className="space-y-6">
      <PageHeader title={`Outreach${domain ? ` — ${domain.name}` : ''}`} />
      <div className="flex flex-wrap gap-3">
        <Stat
          label="Asking"
          value={
            finding.filter((w) =>
              w.request.some((r) => r.kind === 'Outreach' && OPEN.includes(r.status)),
            ).length
          }
          tone="blue"
        />
        <Stat label="Confirmed" value={confirmed.length} tone="green" />
        <Stat label="At risk" value={upcoming.filter((w) => w.at_risk).length} tone="amber" />
        <Stat
          label="Needs instructor"
          value={upcoming.filter((w) => w.status === 'NeedsInstructor').length}
          tone="red"
        />
        <Stat label="Help open" value={helpOpen} tone="purple" />
      </div>
      <ErrorText error={err} />

      <section>
        <h2 className="mb-2 font-semibold">A. Finding instructors</h2>
        {weeks.isLoading ? (
          <Spinner />
        ) : finding.length === 0 ? (
          <Empty title="Every upcoming module week has an instructor">
            Nothing to chase right now.
          </Empty>
        ) : (
          <div className="overflow-x-auto rounded-lg border bg-card">
            <table className="w-full">
              <thead className="border-b bg-muted">
                <tr>
                  <th className={th}></th>
                  <th className={th}>Module week</th>
                  <th className={th}>Mode</th>
                  <th className={th}>Now asking</th>
                  <th className={th}>Deadline</th>
                  <th className={th}>Next in line</th>
                  <th className={th}>Status</th>
                  <th className={th}>Actions</th>
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
                      <tr className="border-b">
                        <td className={td}>
                          <button
                            aria-label="Show everyone asked"
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
                            {label(w)}
                          </button>
                          {w.at_risk && (
                            <div className="text-xs text-danger-strong">
                              At risk: {w.at_risk_reason}
                            </div>
                          )}
                        </td>
                        <td className={td}>{w.outreach_mode}</td>
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
                            '—'
                          )}
                        </td>
                        <td className={`${td} text-xs`}>
                          {p?.asking ? `Moves on at ${fmtPT(p.asking.deadline_at)}` : '—'}
                        </td>
                        <td className={td}>
                          {p ? (
                            (p.next ?? <span className="text-danger-strong">Nobody left</span>)
                          ) : (
                            <Spinner />
                          )}
                        </td>
                        <td className={td}>{statusOf(w, p)}</td>
                        <td className={td}>
                          <div className="flex flex-wrap gap-1">
                            <Button
                              size="sm"
                              variant="outline"
                              disabled={!p?.asking}
                              onClick={async () => {
                                if (
                                  await confirm({
                                    title: `Skip ${p?.asking?.name}?`,
                                    body: 'Their request is withdrawn politely and the next instructor is asked.',
                                  })
                                )
                                  await run(
                                    () => rpc('skip_to_next', { p_module_week_id: w.id }),
                                    'Asked the next instructor',
                                  );
                              }}
                            >
                              Skip to next
                            </Button>
                            <Button size="sm" variant="outline" onClick={() => setManualFor(w)}>
                              Change mode
                            </Button>
                            <Button size="sm" variant="outline" onClick={() => setDrawer(w.id)}>
                              Assign manually
                            </Button>
                            <Button
                              size="sm"
                              variant="ghost"
                              onClick={() =>
                                run(
                                  () =>
                                    rpc('pause_outreach', {
                                      p_module_week_id: w.id,
                                      p_paused: !w.paused,
                                    }),
                                  w.paused ? 'Resumed' : 'Paused',
                                )
                              }
                            >
                              {w.paused ? 'Resume' : 'Pause'}
                            </Button>
                          </div>
                        </td>
                      </tr>
                      {open && (
                        <tr className="border-b bg-muted">
                          <td></td>
                          <td colSpan={7} className="px-2 py-2 text-sm">
                            {asked.length === 0 ? (
                              <span className="text-muted-foreground">Nobody asked yet.</span>
                            ) : (
                              <ol className="list-decimal space-y-0.5 pl-5">
                                {asked.map((r) => (
                                  <li key={r.id}>
                                    <strong>{names.get(r.instructor_id ?? '')}</strong> — asked{' '}
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
                                Line:{' '}
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
        <h2 className="mb-2 font-semibold">B. Confirmed and check-ins</h2>
        {confirmed.length === 0 ? (
          <Empty title="No confirmed module weeks coming up" />
        ) : (
          <div className="overflow-x-auto rounded-lg border bg-card">
            <table className="w-full">
              <thead className="border-b bg-muted">
                <tr>
                  <th className={th}>Module week</th>
                  <th className={th}>Instructor</th>
                  {checkinDays.map((d) => (
                    <th key={d} className={th}>
                      {d}-day check-in
                    </th>
                  ))}
                  <th className={th}>Actions</th>
                </tr>
              </thead>
              <tbody>
                {confirmed.map((w) => {
                  const st = weekState(w, names);
                  const booking = w.booking.find((b) => b.status === 'Active')!;
                  const lastCheckin = checkinMsgs.data?.find((m) => m.module_week_id === w.id);
                  return (
                    <tr key={w.id} className="border-b last:border-0">
                      <td className={td}>
                        <button
                          className="text-left font-medium text-link hover:underline"
                          onClick={() => setDrawer(w.id)}
                        >
                          {label(w)}
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
                          ? ['—', 'gray']
                          : r.answer === 'AllSet'
                            ? ['All set', 'green']
                            : r.answer === 'NeedHelp'
                              ? ['Need help', 'amber']
                              : r.status === 'Expired'
                                ? ['No reply', 'red']
                                : r.status === 'Superseded'
                                  ? ['Skipped', 'gray']
                                  : [r.status === 'Reminded' ? 'Sent, reminded' : 'Sent', 'blue'];
                        return (
                          <td key={d} className={td}>
                            <Badge tone={v[1] as 'gray'}>{v[0]}</Badge>
                          </td>
                        );
                      })}
                      <td className={td}>
                        <div className="flex flex-wrap gap-1">
                          <Button
                            size="sm"
                            variant="danger"
                            onClick={async () => {
                              if (
                                await confirm({
                                  title: 'Release this booking?',
                                  body: 'The instructor is told politely and outreach restarts.',
                                  danger: true,
                                  confirmLabel: 'Release & find replacement',
                                })
                              )
                                await run(
                                  () => rpc('release_booking', { p_module_week_id: w.id }),
                                  'Released',
                                );
                            }}
                          >
                            Release
                          </Button>
                          <Button size="sm" variant="outline" onClick={() => setDrawer(w.id)}>
                            Change instructor
                          </Button>
                          <Button
                            size="sm"
                            variant="ghost"
                            disabled={!lastCheckin}
                            onClick={() =>
                              run(
                                () => rpc('resend_message', { p_message_id: lastCheckin!.id }),
                                'Check-in resent',
                              )
                            }
                          >
                            Resend check-in
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
        <Spinner />
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
                    <span className="text-xs text-muted-foreground">#{i.rank}</span>
                  ) : (
                    <Badge>Not in this module’s list</Badge>
                  )}
                  {i.is_test && <Badge tone="purple">TEST</Badge>}
                  {i.reason && <div className="text-xs">{i.reason}</div>}
                  {!i.reason && i.warning && (
                    <div className="text-xs text-warning-strong">⚠ {i.warning}</div>
                  )}
                </span>
              </label>
            ))}
          </div>
          <div>
            <h3 className="mb-1 text-sm font-medium">Order (drag to change)</h3>
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
              <Select value={end} onChange={(e) => setEnd(e.target.value)} className="w-56">
                <option value="Stop">Stop and alert me</option>
                <option value="ContinueWithRanking">Continue with the ranking</option>
              </Select>
            </div>
            <ErrorText error={err} />
            <div className="mt-3 flex flex-wrap gap-2">
              <Button disabled={order.length === 0} onClick={() => void submit('Manual')}>
                Start outreach
              </Button>
              <Button variant="outline" onClick={() => void submit('Sequential')}>
                Use the ranking (sequential) instead
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
            variant="outline"
            onClick={() => (setDecision(null), void submit(decision!.mode, 'keep'))}
          >
            Keep waiting
          </Button>
          <Button onClick={() => (setDecision(null), void submit(decision!.mode, 'withdraw'))}>
            Withdraw and start
          </Button>
        </div>
      </Modal>
    </Modal>
  );
}
