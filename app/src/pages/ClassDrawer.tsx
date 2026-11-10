import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import type { WeekRow } from '@/lib/data';
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

  return (
    <Drawer
      open
      onOpenChange={(o) => !o && onClose()}
      title={`${week.module?.name}${week.cohort ? ` (${week.cohort})` : ''} · week of ${week.week_start_date}`}
    >
      <div className="space-y-5 text-sm">
        <div className="flex flex-wrap gap-2">
          <Badge tone={state.tone}>{state.label}</Badge>
          {week.at_risk && <Badge tone="red">At risk: {week.at_risk_reason}</Badge>}
          <Badge>{week.outreach_mode}</Badge>
          {week.help_request.some((h) =>
            ['Open', 'InProgress', 'WaitingOnInstructor'].includes(h.status),
          ) && <Badge tone="amber">🙋 Help open</Badge>}
        </div>

        <section className="space-y-3">
          <h3 className="font-medium">Classes (Pacific Time)</h3>
          {classes.map((c) => (
            <ClassEditor key={`${c.id}:${c.version}`} c={c} run={run} />
          ))}
        </section>

        <section className="space-y-2 border-t pt-4">
          <h3 className="font-medium">Instructor</h3>
          {booking ? (
            <div className="flex flex-wrap items-center gap-2">
              <span>
                Confirmed: <strong>{names.get(booking.instructor_id)}</strong> (
                {booking.confirmed_via})
              </span>
              <Button
                size="sm"
                variant="danger"
                onClick={async () => {
                  if (
                    await confirm({
                      title: 'Release this booking?',
                      body: 'The instructor is told politely and outreach restarts for this module week.',
                      danger: true,
                      confirmLabel: 'Release & find replacement',
                    })
                  )
                    await run(
                      () =>
                        rpc('release_booking', {
                          p_module_week_id: week.id,
                          p_reason: note || undefined,
                        }),
                      'Booking released',
                    );
                }}
              >
                Release booking
              </Button>
            </div>
          ) : (
            <p className="text-muted-foreground">
              {state.asking ? `Asking ${state.asking} now.` : 'No confirmed instructor.'}
            </p>
          )}
          {!booking && week.status !== 'Cancelled' && (
            <div className="flex flex-wrap items-end gap-2">
              <Field label="Assign / record confirmation">
                <Select
                  value={assignTo}
                  onChange={(e) => setAssignTo(e.target.value)}
                  className="w-72"
                >
                  <option value="">Choose an instructor…</option>
                  {(eligible.data ?? []).map((i) => (
                    <option
                      key={i.instructor_id}
                      value={i.instructor_id}
                      disabled={
                        !!i.reason && i.reason !== 'Not verified' && i.reason !== 'Being asked now'
                      }
                    >
                      {i.name}
                      {i.rank ? ` (#${i.rank})` : ' (not in this module’s list)'}
                      {i.reason ? ` — ${i.reason}` : ''}
                    </option>
                  ))}
                </Select>
              </Field>
              <Input
                placeholder="Note (optional)"
                value={note}
                onChange={(e) => setNote(e.target.value)}
                className="w-48"
              />
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
                    'Assigned',
                  )
                }
              >
                Assign manually
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={!assignTo}
                onClick={() =>
                  run(
                    () =>
                      rpc('record_offline_confirmation', {
                        p_module_week_id: week.id,
                        p_instructor_id: assignTo,
                        p_note: note || undefined,
                      }),
                    'Offline confirmation recorded',
                  )
                }
              >
                Record offline confirmation
              </Button>
            </div>
          )}
        </section>

        <section className="flex flex-wrap gap-2 border-t pt-4">
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              run(
                () => rpc('pause_outreach', { p_module_week_id: week.id, p_paused: !week.paused }),
                week.paused ? 'Outreach resumed' : 'Outreach paused',
              )
            }
          >
            {week.paused ? 'Resume outreach' : 'Pause outreach'}
          </Button>
          <Button
            size="sm"
            variant="outline"
            disabled={!lastInstructorMsg}
            title={
              lastInstructorMsg
                ? `${lastInstructorMsg.template_id} to ${lastInstructorMsg.recipient_label} via ${lastInstructorMsg.channel}`
                : 'No message yet'
            }
            onClick={() =>
              run(() => rpc('resend_message', { p_message_id: lastInstructorMsg!.id }), 'Resent')
            }
          >
            Resend last message
          </Button>
          <div className="flex items-center gap-1">
            <Input
              type="number"
              min={-26}
              max={26}
              value={shiftN}
              onChange={(e) => setShiftN(Number(e.target.value))}
              className="h-8 w-16"
            />
            <Button
              size="sm"
              variant="outline"
              onClick={async () => {
                if (
                  await confirm({
                    title: `Shift this and all later classes by ${shiftN} week(s)?`,
                    body: 'Classes keep their Pacific times. Confirmed instructors get a time-change request; outreach is recalculated.',
                  })
                )
                  await run(
                    () =>
                      rpc('shift_classes', {
                        p_module_week_id: week.id,
                        p_weeks: shiftN,
                        p_include_later: true,
                      }),
                    'Shifted',
                  );
              }}
            >
              Shift this + later
            </Button>
          </div>
          <Button
            size="sm"
            variant="danger"
            disabled={week.status === 'Cancelled'}
            onClick={async () => {
              if (
                await confirm({
                  title: 'Cancel this whole module week?',
                  body: 'Open requests are withdrawn and a confirmed instructor gets a cancellation message (M11).',
                  danger: true,
                  confirmLabel: 'Cancel module week',
                })
              )
                await run(
                  () => rpc('cancel_module_week', { p_module_week_id: week.id }),
                  'Module week cancelled',
                );
            }}
          >
            Cancel module week
          </Button>
        </section>

        <section className="space-y-2 border-t pt-4">
          <h3 className="font-medium">Checklist</h3>
          {(checklist.data ?? []).length === 0 && (
            <p className="text-muted-foreground">Created when an instructor is confirmed.</p>
          )}
          {classes.map((c) => {
            const items = (checklist.data ?? []).filter((i) => i.class_id === c.id);
            if (!items.length) return null;
            return (
              <div key={c.id}>
                <div className="text-xs text-muted-foreground">{c.title}</div>
                <div className="flex flex-wrap gap-3">
                  {items.map((i) => (
                    <Checkbox
                      key={i.id}
                      label={i.label}
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
        </section>

        <section className="space-y-2 border-t pt-4">
          <h3 className="font-medium">Create help request (e.g. after a phone call)</h3>
          <div className="flex flex-wrap gap-3">
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
            maxLength={1000}
            value={help.details}
            onChange={(e) => setHelp({ ...help, details: e.target.value })}
          />
          <div className="flex gap-2">
            <Select
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
                  'Help request created',
                );
                setHelp({ cats: [], details: '', urgency: 'NoRush' });
              }}
            >
              Create help request
            </Button>
          </div>
        </section>

        <ErrorText error={err} />

        <section className="space-y-1 border-t pt-4">
          <h3 className="font-medium">Timeline</h3>
          {(timeline.data?.messages ?? []).length > 0 && (
            <details>
              <summary className="cursor-pointer text-link">
                Messages ({timeline.data!.messages.length})
              </summary>
              <ul className="mt-1 space-y-1">
                {timeline.data!.messages.map((m) => (
                  <li key={m.id} className="rounded bg-muted p-2 text-xs">
                    <div className="flex flex-wrap gap-1">
                      <Badge>{m.template_id}</Badge>
                      <Badge
                        tone={
                          m.status === 'Sent' ? 'green' : m.status === 'Failed' ? 'red' : 'gray'
                        }
                      >
                        {m.status}
                      </Badge>
                      <span>
                        {m.direction === 'Inbound' ? 'from' : 'to'} {m.recipient_label} via{' '}
                        {m.channel} · {fmtLocal(m.sent_at ?? m.created_at)}
                      </span>
                    </div>
                    <div className="mt-1 whitespace-pre-line text-foreground">{m.body_text}</div>
                    {m.last_error && (
                      <div className="text-danger-strong">Error: {m.last_error}</div>
                    )}
                  </li>
                ))}
              </ul>
            </details>
          )}
          <ul className="space-y-1">
            {(timeline.data?.events ?? []).map((e) => (
              <li key={e.id} className="text-xs">
                <span className="text-muted-foreground">{fmtLocal(e.at)}</span> ·{' '}
                <strong>{e.actor_label}</strong> · {e.action}
                {e.note && <span className="text-muted-foreground"> — {e.note}</span>}
              </li>
            ))}
          </ul>
        </section>
      </div>
    </Drawer>
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
    <div className="rounded border p-2">
      <div className="mb-1 flex flex-wrap items-center gap-2">
        <Badge>{c.class_type}</Badge>
        <span className="font-medium">{fmtPTRange(c.starts_at, c.ends_at)}</span>
        {c.status !== 'Planned' && <Badge tone="gray">{c.status}</Badge>}
      </div>
      {c.status === 'Planned' && (
        <>
          <div className="flex flex-wrap items-end gap-2">
            <Input
              type="date"
              value={t.date}
              onChange={(ev) => setT({ ...t, date: ev.target.value })}
              className="h-8 w-36"
            />
            <Input
              type="time"
              value={t.start}
              onChange={(ev) => setT({ ...t, start: ev.target.value })}
              className="h-8 w-24"
            />
            <span>–</span>
            <Input
              type="time"
              value={t.end}
              onChange={(ev) => setT({ ...t, end: ev.target.value })}
              className="h-8 w-24"
            />
            <Button
              size="sm"
              variant="outline"
              disabled={!timeChanged}
              onClick={async () => {
                if (
                  await confirm({
                    title: 'Change the class time?',
                    body: 'If someone is confirmed, the new time is clash-checked and they are asked to confirm it. If someone is being asked, they get the updated time.',
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
                    'Time changed',
                  );
              }}
            >
              Change time
            </Button>
            <Button
              size="sm"
              variant="ghost"
              onClick={async () => {
                if (
                  await confirm({
                    title: `Cancel “${c.title}”?`,
                    body: 'If this is the only class left, the whole module week is cancelled.',
                    danger: true,
                    confirmLabel: 'Cancel class',
                  })
                )
                  await run(() => rpc('cancel_class', { p_class_id: c.id }), 'Class cancelled');
              }}
            >
              Cancel class
            </Button>
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <Input
              value={d.title}
              onChange={(ev) => setD({ ...d, title: ev.target.value })}
              className="h-8 w-64"
            />
            <Input
              placeholder="Notes"
              value={d.notes}
              onChange={(ev) => setD({ ...d, notes: ev.target.value })}
              className="h-8 w-56"
            />
            <Checkbox
              label="Problem (don’t auto-complete)"
              checked={d.problem}
              onChange={(v) => setD({ ...d, problem: v })}
            />
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
                    'Saved',
                  )
                }
              >
                Save
              </Button>
            )}
          </div>
        </>
      )}
    </div>
  );
}
