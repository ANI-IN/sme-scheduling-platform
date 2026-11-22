import { useState } from 'react';
import { DateTime } from 'luxon';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { useNameBook, type WeekRow } from '@/lib/data';
import { discordNames } from '@/lib/discordNames';
import { messageTitle, plain } from '@/lib/plain';
import { describeHistory } from '@/lib/historyText';
import { fmtLocal } from '@/lib/time';
import { asRegion, localParts, timeFieldLabel } from '@/lib/region';
import { ClassTime, RegionBadge, RegionSelect, TimeCheck, timeReady } from '@/components/ClassTime';
import { weekState } from '@/lib/status';
import { helpCategories } from '@/lib/labels';
import { useConfirm } from '@/components/Confirm';
import { WarningsDialog, type CheckWarning } from '@/components/WarningsDialog';
import { DeleteButton } from '@/components/Lifecycle';
import { useDomain } from '@/lib/domain';
import { AddClassDialog } from './AddClassDialog';
import { ResetToStandard } from './setup/standardParts';
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
      if (ok) toast.success(ok);
      // Show the result at once, then ask n8n to deliver; refresh again when it has started.
      await qc.invalidateQueries();
      void poke().then(() => qc.invalidateQueries());
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
  const [assignWarn, setAssignWarn] = useState<{
    fn: 'assign_manually' | 'record_offline_confirmation';
    warnings: CheckWarning[];
  } | null>(null);
  // Assigning checks the instructor's day and monthly limit first; going ahead needs a reason (decision 297).
  async function assignOrRecord(
    fn: 'assign_manually' | 'record_offline_confirmation',
    why?: string,
  ) {
    const args = {
      p_module_week_id: week.id,
      p_instructor_id: assignTo,
      p_note: note || undefined,
      ...(why === undefined ? {} : { p_accept_warnings: true, p_reason: why || undefined }),
    };
    const res = (await run(() =>
      fn === 'assign_manually'
        ? rpc('assign_manually', args)
        : rpc('record_offline_confirmation', args),
    )) as { needs_confirmation?: boolean; warnings?: CheckWarning[] } | undefined;
    if (!res) return;
    if (res.needs_confirmation) {
      setAssignWarn({ fn, warnings: res.warnings ?? [] });
      return;
    }
    toast.success(fn === 'assign_manually' ? 'Instructor assigned' : 'Confirmation recorded');
  }
  const [help, setHelp] = useState({ cats: [] as string[], details: '', urgency: 'NoRush' });
  const [shiftN, setShiftN] = useState(1);
  const [addingClass, setAddingClass] = useState(false);
  const [task, setTask] = useState({ label: '', classId: '' });
  const { domain } = useDomain();
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
      footer={err ? <ErrorText error={err} /> : undefined}
      description={
        week.cohort
          ? /cohort/i.test(week.cohort)
            ? week.cohort
            : `Cohort ${week.cohort}`
          : undefined
      }
    >
      <div className="space-y-6 text-sm">
        <div className="flex flex-wrap gap-2">
          <Badge tone={state.tone}>{state.short}</Badge>
          {week.at_risk && state.kind !== 'At risk' && <Badge tone="danger">At risk</Badge>}
          <Badge>{week.outreach_mode === 'Manual' ? 'Chosen list' : 'Instructor order'}</Badge>
          {week.paused && <Badge tone="accent">Requests paused</Badge>}
          {openHelp && <Badge tone="warning">Help request open</Badge>}
        </div>
        {week.at_risk && week.at_risk_reason && (
          <p className="-mt-4 text-danger-strong">{plain(week.at_risk_reason)}</p>
        )}

        <DrawerGroup
          title="Classes"
          description="Each class shows the time where it is taught. US classes also show the India time."
        >
          {classes.map((c) => (
            <ClassEditor key={`${c.id}:${c.version}`} c={c} run={run} />
          ))}
        </DrawerGroup>

        {week.standard_position !== null && <StandardGroup week={week} />}

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
                  onClick={() => void assignOrRecord('assign_manually')}
                >
                  Assign and confirm instructor
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={!assignTo}
                  onClick={() => void assignOrRecord('record_offline_confirmation')}
                >
                  Record a phone or chat confirmation
                </Button>
              </div>
              <WarningsDialog
                warnings={assignWarn?.warnings ?? null}
                title={
                  assignWarn?.fn === 'record_offline_confirmation'
                    ? 'Record this confirmation anyway?'
                    : 'Assign anyway?'
                }
                confirmLabel={
                  assignWarn?.fn === 'record_offline_confirmation'
                    ? 'Record anyway'
                    : 'Assign anyway'
                }
                busy={busy}
                onCancel={() => setAssignWarn(null)}
                onConfirm={(why) => {
                  const fn = assignWarn!.fn;
                  setAssignWarn(null);
                  void assignOrRecord(fn, why);
                }}
              />
            </div>
          )}
        </DrawerGroup>

        <DrawerGroup title="Tasks for the operations team">
          {(checklist.data ?? []).length === 0 && (
            <p className="text-muted-foreground">
              The usual tasks are added when an instructor confirms. You can add extra tasks for a
              class at any time.
            </p>
          )}
          {classes.some((c) => c.status === 'Planned') && (
            <div className="flex flex-wrap items-end gap-2">
              <Field label="Extra task">
                <Input
                  value={task.label}
                  placeholder="For example: book the bigger room"
                  onChange={(e) => setTask({ ...task, label: e.target.value })}
                />
              </Field>
              <Field label="For class">
                <Select
                  value={task.classId || classes.find((c) => c.status === 'Planned')?.id || ''}
                  onChange={(e) => setTask({ ...task, classId: e.target.value })}
                >
                  {classes
                    .filter((c) => c.status === 'Planned')
                    .map((c) => (
                      <option key={c.id} value={c.id}>
                        {plain(c.title)}
                      </option>
                    ))}
                </Select>
              </Field>
              <Button
                size="sm"
                variant="secondary"
                disabled={!task.label.trim()}
                onClick={async () => {
                  const classId =
                    task.classId || classes.find((c) => c.status === 'Planned')?.id || '';
                  await run(
                    () => rpc('add_checklist_item', { p_class_id: classId, p_label: task.label }),
                    'Task added',
                  );
                  setTask({ label: '', classId });
                }}
              >
                Add task
              </Button>
            </div>
          )}
          {classes.map((c) => {
            const items = (checklist.data ?? []).filter((i) => i.class_id === c.id);
            if (!items.length) return null;
            return (
              <div key={c.id}>
                <div className="mb-1 text-xs text-muted-foreground">{plain(c.title)}</div>
                <div className="flex flex-wrap gap-x-4 gap-y-2">
                  {items.map((i) => (
                    <span key={i.id} className="inline-flex items-center gap-1">
                      <Checkbox
                        label={plain(i.label)}
                        checked={i.done}
                        onChange={(v) =>
                          void run(() => rpc('set_checklist_item', { p_item_id: i.id, p_done: v }))
                        }
                      />
                      {i.added_manually && (
                        <button
                          type="button"
                          className="text-xs text-muted-foreground hover:text-danger-strong"
                          aria-label={`Remove the task ${i.label}`}
                          onClick={() =>
                            void run(
                              () => rpc('remove_checklist_item', { p_item_id: i.id }),
                              'Task removed',
                            )
                          }
                        >
                          Remove
                        </button>
                      )}
                    </span>
                  ))}
                </div>
              </div>
            );
          })}
        </DrawerGroup>

        <details className="group border-t border-border pt-4">
          <summary className="cursor-pointer font-semibold text-link">More options</summary>
          <div className="mt-2 space-y-4">
            <DrawerGroup title="Class week">
              <div className="flex flex-wrap items-center gap-2">
                {/* OUT-3: a confirmed class week has nobody to ask, so there is nothing to pause. */}
                {(!booking || week.paused) && (
                  <Button
                    size="sm"
                    variant="secondary"
                    onClick={() =>
                      run(
                        () =>
                          rpc('pause_outreach', {
                            p_module_week_id: week.id,
                            p_paused: !week.paused,
                          }),
                        week.paused ? 'Requests resumed' : 'Requests paused',
                      )
                    }
                  >
                    {week.paused ? 'Resume requests' : 'Pause requests'}
                  </Button>
                )}
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
                {!booking && !state.asking && week.status !== 'Cancelled' && (
                  <Button
                    size="sm"
                    variant="secondary"
                    onClick={() =>
                      run(
                        () => rpc('start_asking_now', { p_module_week_id: week.id }),
                        'Asking now',
                      )
                    }
                  >
                    Start asking now
                  </Button>
                )}
                {week.status !== 'Cancelled' && (
                  <Button size="sm" variant="secondary" onClick={() => setAddingClass(true)}>
                    Add a class to this week
                  </Button>
                )}
              </div>
              {week.status !== 'Cancelled' && (
                <Checkbox
                  label="The same instructor teaches every class of this week"
                  hint={
                    week.same_instructor
                      ? 'Turn off to find a different instructor for each class (only while nobody is confirmed or being asked).'
                      : 'Each class has its own instructor and its own request.'
                  }
                  checked={week.same_instructor}
                  onChange={async (on) => {
                    if (
                      await confirm({
                        title: on
                          ? 'Use one instructor for the whole class week?'
                          : 'Find a different instructor for each class?',
                        body: on
                          ? 'The classes are joined back into one class week with one request.'
                          : 'Each class becomes its own class week with its own request and instructor.',
                      })
                    )
                      await run(
                        () =>
                          rpc('set_week_same_instructor', {
                            p_module_week_id: week.id,
                            p_on: on,
                          }),
                        on
                          ? 'One instructor for the whole week'
                          : 'Each class has its own instructor',
                      );
                  }}
                />
              )}
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
                        body: 'Each class keeps its local time. Confirmed instructors are asked to confirm the new dates, and requests are planned again.',
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
          </div>
        </details>

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
                    <div className="mt-1 whitespace-pre-line text-foreground">
                      {discordNames(m.body_text)}
                    </div>
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

        <DrawerGroup
          title={week.status === 'Cancelled' ? 'Cancelled' : 'Cancel or delete this class week'}
          tone="danger"
        >
          <p className="text-muted-foreground">
            {week.status === 'Cancelled'
              ? 'This class week is cancelled. Restore it to plan its classes still to come again; the automation then asks for an instructor as for any new class week.'
              : 'Cancel: open requests are withdrawn politely, and a confirmed instructor is told that the class is cancelled. You can restore it later. Delete removes it for good, after doing the same.'}
          </p>
          <div className="flex flex-wrap gap-2">
            {week.status === 'Cancelled' ? (
              <Button
                size="sm"
                variant="secondary"
                onClick={() =>
                  run(
                    () => rpc('restore_module_week', { p_module_week_id: week.id }),
                    'Class week restored',
                  )
                }
              >
                Restore class week
              </Button>
            ) : (
              <Button
                size="sm"
                variant="destructive"
                disabled={week.status === 'Completed'}
                onClick={async () => {
                  if (
                    await confirm({
                      title: 'Cancel this whole class week?',
                      body: 'Open requests are withdrawn politely, and a confirmed instructor is told that the class is cancelled. You can restore it later, but they are not told again.',
                      danger: true,
                      confirmLabel: 'Cancel the class week',
                      cancelLabel: 'Keep the class week',
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
            )}
            <DeleteButton kind="class_week" id={week.id} onDeleted={onClose} />
          </div>
        </DrawerGroup>
      </div>
      {addingClass && domain && (
        <AddClassDialog domain={domain} week={week} onClose={() => setAddingClass(false)} />
      )}
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

type Compare = {
  follows_standard: boolean;
  standard?: {
    module: string;
    week_start_date: string;
    classes: { title: string; shown: string }[];
  };
  current?: { classes: { title: string; shown: string }[] };
  differs?: boolean;
  customized_at?: string | null;
  reset?: { actions: string[]; not_updated: string | null };
};

/** A class week planned from a standard schedule: its standard version next to the current one (decision 299). */
function StandardGroup({ week }: { week: WeekRow }) {
  const cmp = useQuery({
    queryKey: ['module_week', 'standard_compare', week.id],
    queryFn: async () =>
      (await rpc('standard_compare', { p_module_week_id: week.id })) as unknown as Compare,
  });
  const c = cmp.data;
  if (!c?.follows_standard || !c.standard || !c.current) return null;
  const list = (classes: { title: string; shown: string }[]) =>
    classes.length === 0 ? (
      <p className="text-muted-foreground">No classes.</p>
    ) : (
      <ul className="space-y-1">
        {classes.map((k, i) => (
          <li key={i}>
            <span className="font-medium">{plain(k.title)}</span>
            <span className="block text-xs text-muted-foreground">{plain(k.shown)}</span>
          </li>
        ))}
      </ul>
    );
  return (
    <DrawerGroup
      title="Standard schedule"
      description="This class week was planned from a standard schedule."
    >
      <div className="flex flex-wrap items-center gap-2">
        {c.customized_at ? (
          <>
            <Badge tone="warning">Custom</Badge>
            <span className="text-muted-foreground">
              Changed for this cohort on {DateTime.fromISO(c.customized_at).toFormat('LLL d, yyyy')}
              .
            </span>
          </>
        ) : c.differs ? (
          <>
            <Badge tone="success">Standard</Badge>
            <span className="text-muted-foreground">
              The standard changed after this class week was planned.
            </span>
          </>
        ) : (
          <>
            <Badge tone="success">Standard</Badge>
            <span className="text-muted-foreground">It follows its standard.</span>
          </>
        )}
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="rounded-md border border-border p-3">
          <div className="mb-1 text-xs font-semibold text-muted-foreground uppercase">
            Standard: {c.standard.module}
          </div>
          {list(c.standard.classes)}
        </div>
        <div className="rounded-md border border-border p-3">
          <div className="mb-1 text-xs font-semibold text-muted-foreground uppercase">Now</div>
          {list(c.current.classes)}
        </div>
      </div>
      {c.reset?.not_updated ? (
        c.differs || c.customized_at ? (
          <p className="text-muted-foreground">
            Reset to standard is not possible here: {plain(c.reset.not_updated)}
          </p>
        ) : null
      ) : (
        c.differs && <ResetToStandard moduleWeekId={week.id} />
      )}
    </DrawerGroup>
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
  const region = asRegion(c.region);
  const s = localParts(c.starts_at, region);
  const e = localParts(c.ends_at, region);
  const [t, setT] = useState({ date: s.date, start: s.time, end: e.time, region });
  const [fold, setFold] = useState<number | null>(null);
  const [timeWarn, setTimeWarn] = useState<{
    args: Parameters<typeof changeTime>[0];
    warnings: CheckWarning[];
  } | null>(null);
  const [d, setD] = useState({ title: c.title, notes: c.notes ?? '', problem: c.problem_flag });
  const timeChanged =
    t.date !== s.date || t.start !== s.time || t.end !== e.time || t.region !== region;
  async function changeTime(
    args: { p_class_id: string; p_date: string; p_start: string; p_end: string } & Record<
      string,
      unknown
    >,
    why?: string,
  ) {
    const res = (await run(() =>
      rpc('change_class_time', {
        ...args,
        ...(why === undefined ? {} : { p_accept_warnings: true, p_reason: why || undefined }),
      }),
    )) as { needs_confirmation?: boolean; warnings?: CheckWarning[] } | undefined;
    if (res && !res.needs_confirmation) toast.success('Class time changed');
    return res;
  }
  const ready = timeReady(t.date, [t.start, t.end], t.region, fold);
  const detailsChanged =
    d.title !== c.title || d.notes !== (c.notes ?? '') || d.problem !== c.problem_flag;
  return (
    <div className="rounded-md border border-border p-3">
      <WarningsDialog
        warnings={timeWarn?.warnings ?? null}
        title="Change the time anyway?"
        confirmLabel="Change anyway"
        onCancel={() => setTimeWarn(null)}
        onConfirm={(why) => {
          const args = timeWarn!.args;
          setTimeWarn(null);
          void changeTime(args, why);
        }}
      />
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <Badge>{c.class_type}</Badge>
        <RegionBadge region={c.region} />
        <ClassTime start={c.starts_at} end={c.ends_at} region={c.region} className="font-medium" />
        {c.status !== 'Planned' && (
          <Badge tone={c.status === 'Cancelled' ? 'danger' : 'neutral'}>{c.status}</Badge>
        )}
      </div>
      {c.status === 'Planned' && (
        <div className="space-y-2">
          <p className="text-xs font-medium text-muted-foreground">
            {timeFieldLabel(t.region, t.date)}
          </p>
          <div className="flex flex-wrap items-center gap-2">
            <Input
              type="date"
              aria-label="Date"
              value={t.date}
              onChange={(ev) => {
                setT({ ...t, date: ev.target.value });
                setFold(null);
              }}
              className="h-8 w-40"
            />
            <Input
              type="time"
              aria-label="Start time"
              value={t.start}
              onChange={(ev) => {
                setT({ ...t, start: ev.target.value });
                setFold(null);
              }}
              className="h-8 w-32"
            />
            <span className="text-muted-foreground">to</span>
            <Input
              type="time"
              aria-label="End time"
              value={t.end}
              onChange={(ev) => {
                setT({ ...t, end: ev.target.value });
                setFold(null);
              }}
              className="h-8 w-32"
            />
            <Button
              size="sm"
              variant="secondary"
              disabled={!timeChanged || !ready}
              onClick={async () => {
                if (
                  !(await confirm({
                    title: 'Change the class time?',
                    body: 'If an instructor is confirmed, we check the new time against their other classes and ask them to confirm it. If someone is being asked, they get the new time.',
                  }))
                )
                  return;
                const args = {
                  p_class_id: c.id,
                  p_date: t.date,
                  p_start: t.start,
                  p_end: t.end,
                  p_expected_version: c.version,
                  p_region: t.region,
                  p_fold: fold ?? undefined,
                };
                const res = await changeTime(args);
                // Holidays, unusual hours, the cohort's other classes or the instructor's day: the same checks as
                // adding a class. Going ahead needs a reason (decision 297).
                if (res?.needs_confirmation) setTimeWarn({ args, warnings: res.warnings ?? [] });
              }}
            >
              Change time
            </Button>
          </div>
          <TimeCheck
            date={t.date}
            times={[t.start, t.end]}
            region={t.region}
            fold={fold}
            onFold={setFold}
          />
          <details className="text-sm">
            <summary className="cursor-pointer text-xs text-muted-foreground">
              More options for this class
            </summary>
            <div className="mt-2 space-y-1">
              <RegionSelect
                value={t.region}
                onChange={(r) => {
                  setT({ ...t, region: r });
                  setFold(null);
                }}
              />
              <p className="text-xs text-muted-foreground">
                Usually every class follows its cohort. Change this only for a class taught in the
                other time zone. The date and times above are then read in that time zone.
              </p>
            </div>
          </details>
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
                      cancelLabel: 'Keep the class',
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
