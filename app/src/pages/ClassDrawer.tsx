import { useState } from 'react';
import { DateTime } from 'luxon';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { useNameBook, type WeekRow } from '@/lib/data';
import { messageTitle, plain } from '@/lib/plain';
import { describeHistory } from '@/lib/historyText';
import { fmtLocal, fmtPTRange, ptParts } from '@/lib/time';
import { weekState } from '@/lib/status';
import { helpCategories } from '@/lib/labels';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Checkbox,
  Drawer,
  ErrorText,
  Field,
  Input,
  Select,
  Textarea,
} from '@/components/ui';

type Eligible = {
  instructor_id: string;
  name: string;
  rank: number | null;
  reason: string | null;
  warning: string | null;
  is_test: boolean;
};

export function useRun() {
  const qc = useQueryClient();
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<unknown>, ok?: string) => {
    setErr(null);
    setBusy(true);
    try {
      const r = await fn();
      await poke();
      if (ok) toast.success(ok);
      await qc.invalidateQueries();
      return r;
    } catch (e) {
      setErr(e);
      return undefined;
    } finally {
      setBusy(false);
    }
  };
  return { run, err, busy, setErr };
}

export function ClassDrawer({
  week,
  names,
  onClose,
}: {
  week: WeekRow;
  names: Map<string, string>;
  onClose: () => void;
}) {
  const confirm = useConfirm();
  const { run, err, busy } = useRun();
  const state = weekState(week, names);
  const classes = [...week.class_session].sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  const booking = week.booking.find((b) => b.status === 'Active');

  const eligible = useQuery({
    queryKey: ['request', 'eligibility', week.id],
    queryFn: async () =>
      (await rpc('week_eligibility', { p_module_week_id: week.id })) as unknown as Eligible[],
  });
  const checklist = useQuery({
    queryKey: ['checklist_item', week.id],
    queryFn: async () =>
      check(
        await supabase
          .from('checklist_item')
          .select('*')
          .in(
            'class_id',
            classes.map((c) => c.id),
          )
          .order('label'),
      ),
  });
  const timeline = useQuery({
    queryKey: ['history_event', 'timeline', week.id],
    queryFn: async () => {
      const [h, m] = await Promise.all([
        supabase
          .from('history_event')
          .select('*')
          .eq('module_week_id', week.id)
          .order('id', { ascending: false })
          .limit(300),
        supabase
          .from('message')
          .select('*')
          .eq('module_week_id', week.id)
          .order('created_at', { ascending: false })
          .limit(300),
      ]);
      return { events: check(h), messages: check(m) };
    },
  });
  const lastInstructorMsg = timeline.data?.messages.find(
    (m) => m.audience === 'Instructor' && m.direction === 'Outbound',
  );

  const [assignTo, setAssignTo] = useState('');
  const [note, setNote] = useState('');
  const [help, setHelp] = useState({ cats: [] as string[], details: '', urgency: 'NoRush' });
  const [shiftN, setShiftN] = useState(1);
  const book = useNameBook();

  const openHelp = week.help_request.some((h) =>
    ['Open', 'InProgress', 'WaitingOnInstructor'].includes(h.status),
  );
  const weekOf = DateTime.fromISO(week.week_start_date).toFormat('LLL d, yyyy');

  return (
    <Drawer
      open
      onOpenChange={(o) => !o && onClose()}
      title={`${week.module?.name ?? 'Class week'}: week of ${weekOf}`}
      description={week.cohort ? `Cohort ${week.cohort}` : undefined}
    >
      <div className="space-y-6 text-sm">
        <div className="flex flex-wrap gap-2">
          <Badge tone={state.tone}>{state.label}</Badge>
          {week.at_risk && <Badge tone="danger">At risk: {plain(week.at_risk_reason)}</Badge>}
          <Badge>{week.outreach_mode === 'Manual' ? 'Chosen list' : 'Instructor order'}</Badge>
          {week.paused && <Badge tone="accent">Requests paused</Badge>}
          {openHelp && <Badge tone="warning">Help request open</Badge>}
        </div>

        <DrawerGroup title="Classes" description="Times are Pacific.">
          {classes.map((c) => (
            <ClassEditor key={`${c.id}:${c.version}`} c={c} run={run} />
          ))}
        </DrawerGroup>

        <DrawerGroup title="Instructor">
          {booking ? (
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span>
                Confirmed: <strong>{names.get(booking.instructor_id)}</strong>
                <span className="text-muted-foreground">
                  {' '}
                  ({VIA[booking.confirmed_via] ?? booking.confirmed_via})
                </span>
              </span>
              <Button
                size="sm"
                variant="destructive"
                onClick={async () => {
                  if (
                    await confirm({
                      title: `Release ${names.get(booking.instructor_id) ?? 'this instructor'}?`,
                      body: 'The instructor is told politely, and we start asking other instructors for this class week.',
                      danger: true,
                      confirmLabel: 'Release and find a replacement',
                    })
                  )
                    await run(
                      () =>
                        rpc('release_booking', {
                          p_module_week_id: week.id,
                          p_reason: note || undefined,
                        }),
                      'Instructor released',
                    );
                }}
              >
                Release instructor
              </Button>
            </div>
          ) : (
            <p className="text-muted-foreground">
              {state.asking ? `Asking ${state.asking} now.` : 'No instructor confirmed yet.'}
            </p>
          )}
          {!booking && week.status !== 'Cancelled' && (
            <div className="space-y-2 rounded-md border border-border p-3">
              <div className="grid gap-2 sm:grid-cols-2">
                <Field label="Instructor">
                  <Select value={assignTo} onChange={(e) => setAssignTo(e.target.value)}>
                    <option value="">Choose an instructor</option>
                    {(eligible.data ?? []).map((i) => (
                      <option
                        key={i.instructor_id}
                        value={i.instructor_id}
                        disabled={
                          !!i.reason &&
                          i.reason !== 'Not verified' &&
                          i.reason !== 'Being asked now'
                        }
                      >
                        {i.name}
                        {i.rank
                          ? ` (${i.rank === 1 ? 'Primary' : `Backup ${i.rank - 1}`})`
                          : ' (not in the instructor order)'}
                        {i.reason ? `: ${plain(i.reason)}` : ''}
                      </option>
                    ))}
                  </Select>
                </Field>
                <Field label="Note" hint="Optional. Saved in Activity history.">
                  <Input value={note} onChange={(e) => setNote(e.target.value)} />
                </Field>
              </div>
              <div className="flex flex-wrap gap-2">
                <Button
                  size="sm"
                  disabled={!assignTo}
                  loading={busy}
                  onClick={() =>
                    run(
                      () =>
                        rpc('assign_manually', {
                          p_module_week_id: week.id,
                          p_instructor_id: assignTo,
                          p_note: note || undefined,
                        }),
                      'Instructor assigned',
                    )
                  }
                >
                  Assign instructor
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={!assignTo}
                  onClick={() =>
                    run(
                      () =>
                        rpc('record_offline_confirmation', {
                          p_module_week_id: week.id,
                          p_instructor_id: assignTo,
                          p_note: note || undefined,
                        }),
                      'Confirmation recorded',
                    )
                  }
                >
                  They agreed by phone or chat
                </Button>
              </div>
            </div>
          )}
        </DrawerGroup>

        <DrawerGroup title="Actions">
          <div className="flex flex-wrap items-center gap-2">
            <Button
              size="sm"
              variant="secondary"
              onClick={() =>
                run(
                  () =>
                    rpc('pause_outreach', { p_module_week_id: week.id, p_paused: !week.paused }),
                  week.paused ? 'Requests resumed' : 'Requests paused',
                )
              }
            >
              {week.paused ? 'Resume requests' : 'Pause requests'}
            </Button>
            <Button
              size="sm"
              variant="secondary"
              disabled={!lastInstructorMsg}
              title={
                lastInstructorMsg
                  ? `${messageTitle(lastInstructorMsg.template_id)} to ${lastInstructorMsg.recipient_label} by ${lastInstructorMsg.channel}`
                  : 'No message sent yet'
              }
              onClick={() =>
                run(
                  () => rpc('resend_message', { p_message_id: lastInstructorMsg!.id }),
                  'Message sent again',
                )
              }
            >
              Send last message again
            </Button>
          </div>
          <div className="flex flex-wrap items-end gap-2">
            <Field label="Move this and later class weeks by">
              <div className="flex items-center gap-2">
                <Input
                  type="number"
                  min={-26}
                  max={26}
                  value={shiftN}
                  onChange={(e) => setShiftN(Number(e.target.value))}
                  className="w-20"
                  aria-label="Number of weeks"
                />
                <span className="text-muted-foreground">weeks</span>
              </div>
            </Field>
            <Button
              size="sm"
              variant="secondary"
              onClick={async () => {
                if (
                  await confirm({
                    title: `Move this and all later class weeks by ${shiftN} week${Math.abs(shiftN) === 1 ? '' : 's'}?`,
                    body: 'Classes keep their Pacific times. Confirmed instructors are asked to confirm the new dates, and requests are planned again.',
                  })
                )
                  await run(
                    () =>
                      rpc('shift_classes', {
                        p_module_week_id: week.id,
                        p_weeks: shiftN,
                        p_include_later: true,
                      }),
                    'Dates moved',
                  );
              }}
            >
              Move dates
            </Button>
          </div>
        </DrawerGroup>

        <DrawerGroup title="Tasks for the operations team">
          {(checklist.data ?? []).length === 0 && (
            <p className="text-muted-foreground">Tasks are added when an instructor confirms.</p>
          )}
          {classes.map((c) => {
            const items = (checklist.data ?? []).filter((i) => i.class_id === c.id);
            if (!items.length) return null;
            return (
              <div key={c.id}>
                <div className="mb-1 text-xs text-muted-foreground">{plain(c.title)}</div>
                <div className="flex flex-wrap gap-x-4 gap-y-2">
                  {items.map((i) => (
                    <Checkbox
                      key={i.id}
                      label={plain(i.label)}
                      checked={i.done}
                      onChange={(v) =>
                        void run(() => rpc('set_checklist_item', { p_item_id: i.id, p_done: v }))
                      }
                    />
                  ))}
                </div>
              </div>
            );
          })}
        </DrawerGroup>

        <DrawerGroup
          title="Add a help request"
          description="For example, after an instructor asked for help on a phone call."
        >
          <div className="flex flex-wrap gap-x-4 gap-y-2">
            {helpCategories.map((c) => (
              <Checkbox
                key={c.code}
                label={c.label}
                checked={help.cats.includes(c.code)}
                onChange={(v) =>
                  setHelp({
                    ...help,
                    cats: v ? [...help.cats, c.code] : help.cats.filter((x) => x !== c.code),
                  })
                }
              />
            ))}
          </div>
          <Textarea
            placeholder="Details"
            aria-label="Details"
            maxLength={1000}
            value={help.details}
            onChange={(e) => setHelp({ ...help, details: e.target.value })}
          />
          <div className="flex flex-wrap gap-2">
            <Select
              aria-label="How soon"
              value={help.urgency}
              onChange={(e) => setHelp({ ...help, urgency: e.target.value })}
              className="w-56"
            >
              <option value="NoRush">Before the class, no rush</option>
              <option value="Within24h">Within 24 hours</option>
              <option value="Urgent">Urgent</option>
            </Select>
            <Button
              size="sm"
              variant="secondary"
              disabled={help.cats.length === 0}
              onClick={async () => {
                await run(
                  () =>
                    rpc('create_help_request', {
                      p_module_week_id: week.id,
                      p_categories: help.cats,
                      p_details: help.details,
                      p_urgency: help.urgency,
                    }),
                  'Help request added',
                );
                setHelp({ cats: [], details: '', urgency: 'NoRush' });
              }}
            >
              Add help request
            </Button>
          </div>
        </DrawerGroup>

        <ErrorText error={err} />

        <DrawerGroup title="Activity">
          {(timeline.data?.messages ?? []).length > 0 && (
            <details>
              <summary className="cursor-pointer text-link">
                Messages ({timeline.data!.messages.length})
              </summary>
              <ul className="mt-2 space-y-2">
                {timeline.data!.messages.map((m) => (
                  <li key={m.id} className="rounded-md bg-muted p-2 text-xs">
                    <div className="flex flex-wrap items-center gap-1">
                      <Badge>{messageTitle(m.template_id)}</Badge>
                      <Badge
                        tone={
                          m.status === 'Sent'
                            ? 'success'
                            : m.status === 'Failed'
                              ? 'danger'
                              : 'neutral'
                        }
                      >
                        {MSG_STATUS[m.status] ?? m.status}
                      </Badge>
                      <span className="text-muted-foreground">
                        {m.direction === 'Inbound' ? 'from' : 'to'} {m.recipient_label} by{' '}
                        {m.channel} · {fmtLocal(m.sent_at ?? m.created_at)}
                      </span>
                    </div>
                    <div className="mt-1 whitespace-pre-line text-foreground">{m.body_text}</div>
                    {m.last_error && (
                      <div className="text-danger-strong">Problem: {plain(m.last_error)}</div>
                    )}
                  </li>
                ))}
              </ul>
            </details>
          )}
          {(timeline.data?.events ?? []).length === 0 ? (
            <p className="text-muted-foreground">Nothing has happened yet.</p>
          ) : (
            <ul className="space-y-1">
              {(timeline.data?.events ?? []).map((e) => (
                <li key={e.id} className="text-xs">
                  <span className="text-muted-foreground">{fmtLocal(e.at)}</span> ·{' '}
                  {describeHistory(e, book).sentence}
                  {e.note && <span className="text-muted-foreground"> ({plain(e.note)})</span>}
                </li>
              ))}
            </ul>
          )}
        </DrawerGroup>

        <DrawerGroup title="Cancel this class week" tone="danger">
          <p className="text-muted-foreground">
            Open requests are withdrawn politely, and a confirmed instructor is told that the class
            is cancelled. This cannot be undone.
          </p>
          <div>
            <Button
              size="sm"
              variant="destructive"
              disabled={week.status === 'Cancelled'}
              onClick={async () => {
                if (
                  await confirm({
                    title: 'Cancel this whole class week?',
                    body: 'Open requests are withdrawn politely, and a confirmed instructor is told that the class is cancelled. This cannot be undone.',
                    danger: true,
                    confirmLabel: 'Cancel the class week',
                  })
                )
                  await run(
                    () => rpc('cancel_module_week', { p_module_week_id: week.id }),
                    'Class week cancelled',
                  );
              }}
            >
              Cancel class week
            </Button>
          </div>
        </DrawerGroup>
      </div>
    </Drawer>
  );
}

const VIA: Record<string, string> = {
  Instructor: 'they said yes',
  Offline: 'agreed by phone or chat',
  Manual: 'assigned by the team',
};
const MSG_STATUS: Record<string, string> = {
  Scheduled: 'Scheduled',
  Pending: 'Waiting to send',
  Sending: 'Sending',
  Sent: 'Sent',
  Failed: 'Not delivered',
  Received: 'Received',
  Cancelled: 'Not sent',
};

function DrawerGroup({
  title,
  description,
  tone,
  children,
}: {
  title: string;
  description?: string;
  tone?: 'danger';
  children: React.ReactNode;
}) {
  return (
    <section className="space-y-3 border-t border-border pt-4">
      <div>
        <h3 className={tone === 'danger' ? 'font-semibold text-danger-strong' : 'font-semibold'}>
          {title}
        </h3>
        {description && <p className="text-xs text-muted-foreground">{description}</p>}
      </div>
      {children}
    </section>
  );
}

function ClassEditor({
  c,
  run,
}: {
  c: WeekRow['class_session'][number];
  run: ReturnType<typeof useRun>['run'];
}) {
  const confirm = useConfirm();
  const s = ptParts(c.starts_at);
  const e = ptParts(c.ends_at);
  const [t, setT] = useState({ date: s.date, start: s.time, end: e.time });
  const [d, setD] = useState({ title: c.title, notes: c.notes ?? '', problem: c.problem_flag });
  const timeChanged = t.date !== s.date || t.start !== s.time || t.end !== e.time;
  const detailsChanged =
    d.title !== c.title || d.notes !== (c.notes ?? '') || d.problem !== c.problem_flag;
  return (
    <div className="rounded-md border border-border p-3">
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <Badge>{c.class_type}</Badge>
        <span className="font-medium">{fmtPTRange(c.starts_at, c.ends_at)}</span>
        {c.status !== 'Planned' && (
          <Badge tone={c.status === 'Cancelled' ? 'danger' : 'neutral'}>{c.status}</Badge>
        )}
      </div>
      {c.status === 'Planned' && (
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <Input
              type="date"
              aria-label="Date"
              value={t.date}
              onChange={(ev) => setT({ ...t, date: ev.target.value })}
              className="h-8 w-40"
            />
            <Input
              type="time"
              aria-label="Start time"
              value={t.start}
              onChange={(ev) => setT({ ...t, start: ev.target.value })}
              className="h-8 w-28"
            />
            <span className="text-muted-foreground">to</span>
            <Input
              type="time"
              aria-label="End time"
              value={t.end}
              onChange={(ev) => setT({ ...t, end: ev.target.value })}
              className="h-8 w-28"
            />
            <Button
              size="sm"
              variant="secondary"
              disabled={!timeChanged}
              onClick={async () => {
                if (
                  await confirm({
                    title: 'Change the class time?',
                    body: 'If an instructor is confirmed, we check the new time against their other classes and ask them to confirm it. If someone is being asked, they get the new time.',
                  })
                )
                  await run(
                    () =>
                      rpc('change_class_time', {
                        p_class_id: c.id,
                        p_date: t.date,
                        p_start: t.start,
                        p_end: t.end,
                        p_expected_version: c.version,
                      }),
                    'Class time changed',
                  );
              }}
            >
              Change time
            </Button>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Input
              aria-label="Class title"
              value={d.title}
              onChange={(ev) => setD({ ...d, title: ev.target.value })}
              className="h-8 w-64"
            />
            <Input
              placeholder="Notes"
              aria-label="Notes"
              value={d.notes}
              onChange={(ev) => setD({ ...d, notes: ev.target.value })}
              className="h-8 w-56"
            />
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Checkbox
              label="Something went wrong (do not mark as completed)"
              checked={d.problem}
              onChange={(v) => setD({ ...d, problem: v })}
            />
            <div className="ml-auto flex gap-2">
              {detailsChanged && (
                <Button
                  size="sm"
                  onClick={() =>
                    run(
                      () =>
                        rpc('update_class_details', {
                          p_class_id: c.id,
                          p_title: d.title,
                          p_class_type: c.class_type,
                          p_notes: d.notes,
                          p_problem_flag: d.problem,
                          p_expected_version: c.version,
                        }),
                      'Class saved',
                    )
                  }
                >
                  Save
                </Button>
              )}
              <Button
                size="sm"
                variant="ghost"
                className="text-danger-strong"
                onClick={async () => {
                  if (
                    await confirm({
                      title: `Cancel “${plain(c.title)}”?`,
                      body: 'If this is the only class left in the week, the whole class week is cancelled.',
                      danger: true,
                      confirmLabel: 'Cancel the class',
                    })
                  )
                    await run(() => rpc('cancel_class', { p_class_id: c.id }), 'Class cancelled');
                }}
              >
                Cancel class
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
