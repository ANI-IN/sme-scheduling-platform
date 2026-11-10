import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DateTime } from 'luxon';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useInstructors, useMe, useTeam, useWeeks, type AttentionItem } from '@/lib/data';
import { ago, fmtLocal, fmtPT } from '@/lib/time';
import { messageTitle, plain, plainLabel } from '@/lib/plain';
import { attentionTypeLabel, helpCategories, helpStatusLabel } from '@/lib/labels';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Checkbox,
  Empty,
  ErrorText,
  Field,
  Input,
  Modal,
  Select,
  SkeletonRows,
  Textarea,
  Toolbar,
} from '@/components/ui';
import { ClassDrawer, useRun } from './ClassDrawer';

/** Tasks waiting for a person (shown on Home). */
export function TaskList() {
  const { domain } = useDomain();
  const team = useTeam();
  const me = useMe();
  const weeks = useWeeks(domain?.id);
  const instructors = useInstructors();
  const confirm = useConfirm();
  const { run, err } = useRun();
  const [f, setF] = useState({ type: '', assigned: '', urgent: false, mine: false, done: false });
  const [drawer, setDrawer] = useState<string | null>(null);
  const [help, setHelp] = useState<string | null>(null);
  const [doneFor, setDoneFor] = useState<AttentionItem | null>(null);
  const [replyFor, setReplyFor] = useState<AttentionItem | null>(null);
  const [replyText, setReplyText] = useState('');
  const [note, setNote] = useState('');

  const items = useQuery({
    queryKey: ['attention_item', domain?.id, f.done],
    enabled: !!domain,
    queryFn: async () => {
      let q = supabase
        .from('attention_item')
        .select('*')
        .or(`domain_id.eq.${domain!.id},domain_id.is.null`)
        .order('created_at', { ascending: false })
        .limit(500);
      if (!f.done) q = q.neq('status', 'Done');
      else q = q.gte('done_at', DateTime.now().minus({ days: 7 }).toISO()!);
      return check(await q);
    },
  });

  const names = useMemo(
    () => new Map((instructors.data ?? []).map((i) => [i.id, i.full_name])),
    [instructors.data],
  );
  const teamNames = useMemo(
    () => new Map((team.data ?? []).map((t) => [t.id, t.name])),
    [team.data],
  );
  const all = items.data ?? [];
  const rows = all
    .filter((a) => (f.done ? a.status === 'Done' : a.status !== 'Done'))
    .filter((a) => !f.type || a.type === f.type)
    .filter((a) => !f.assigned || a.assigned_to === f.assigned)
    .filter((a) => !f.urgent || a.severity === 'Urgent')
    .filter(
      (a) =>
        !f.mine ||
        (me && (a.assigned_to === me.id || (!a.assigned_to && a.recipients.includes(me.id)))),
    )
    .sort((a, b) =>
      a.severity === b.severity
        ? b.created_at.localeCompare(a.created_at)
        : a.severity === 'Urgent'
          ? -1
          : 1,
    );

  const openWeek = (weeks.data ?? []).find((w) => w.id === drawer);

  return (
    <div>
      <Toolbar>
        <Select
          aria-label="Type of task"
          value={f.type}
          onChange={(e) => setF({ ...f, type: e.target.value })}
          className="w-60"
        >
          <option value="">All types</option>
          {Object.entries(attentionTypeLabel).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </Select>
        <Select
          aria-label="Assigned to"
          value={f.assigned}
          onChange={(e) => setF({ ...f, assigned: e.target.value })}
          className="w-60"
        >
          <option value="">Assigned to anyone</option>
          {(team.data ?? []).map((t) => (
            <option key={t.id} value={t.id}>
              {t.name}
            </option>
          ))}
        </Select>
        <Checkbox
          label="Urgent only"
          checked={f.urgent}
          onChange={(v) => setF({ ...f, urgent: v })}
        />
        <Checkbox label="Mine only" checked={f.mine} onChange={(v) => setF({ ...f, mine: v })} />
        <Checkbox
          label="Show done in the last 7 days"
          checked={f.done}
          onChange={(v) => setF({ ...f, done: v })}
        />
      </Toolbar>
      <ErrorText error={err} />
      {items.isLoading ? (
        <SkeletonRows rows={4} />
      ) : rows.length === 0 ? (
        <Empty title={f.done ? 'Nothing done in the last 7 days' : 'Nothing needs your attention'}>
          {f.type || f.assigned || f.urgent || f.mine
            ? 'No tasks match these filters.'
            : 'Tasks appear here when the automation needs a person to act.'}
        </Empty>
      ) : (
        <ul className="space-y-2">
          {rows.map((a) => (
            <li
              key={a.id}
              className={`rounded-lg border bg-card p-3 ${a.severity === 'Urgent' && a.status !== 'Done' ? 'border-destructive/40' : 'border-border'}`}
            >
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div className="space-y-1">
                  <div className="flex flex-wrap items-center gap-1">
                    {a.severity === 'Urgent' && <Badge tone="danger">Urgent</Badge>}
                    <Badge tone="info">{attentionTypeLabel[a.type] ?? a.type}</Badge>
                    {a.status === 'Acknowledged' && (
                      <Badge tone="accent">
                        On it{a.assigned_to ? `: ${teamNames.get(a.assigned_to)}` : ''}
                      </Badge>
                    )}
                    {a.is_test && <Badge tone="warning">Test</Badge>}
                    {a.escalated_at && <Badge tone="danger">Escalated</Badge>}
                  </div>
                  <div className="font-medium">{plainLabel(a.title)}</div>
                  {a.detail && (
                    <div className="text-sm whitespace-pre-line text-muted-foreground">
                      {plain(a.detail)}
                    </div>
                  )}
                  <div className="text-xs text-muted-foreground">
                    Waiting {ago(a.created_at)} · added {fmtLocal(a.created_at)}
                    {a.assigned_to
                      ? ` · assigned to ${teamNames.get(a.assigned_to)}`
                      : a.recipients.length
                        ? ` · for ${a.recipients.map((r) => teamNames.get(r)).join(', ')}`
                        : ''}
                    {a.done_note && ` · done: ${a.done_note}`}
                  </div>
                </div>
                {a.status !== 'Done' && (
                  <div className="flex flex-wrap items-center gap-1">
                    {a.status === 'Open' && (
                      <Button
                        size="sm"
                        onClick={() =>
                          run(
                            () => rpc('attention_ack', { p_item_id: a.id }),
                            'Reminders paused for 24 hours',
                          )
                        }
                      >
                        I’m on it
                      </Button>
                    )}
                    <Select
                      aria-label="Assign to a team member"
                      className="h-8 w-40"
                      value=""
                      onChange={(e) =>
                        e.target.value &&
                        void run(
                          () =>
                            rpc('attention_assign', {
                              p_item_id: a.id,
                              p_team_member_id: e.target.value,
                            }),
                          'Assigned',
                        )
                      }
                    >
                      <option value="">Assign to</option>
                      {(team.data ?? [])
                        .filter((t) => t.active)
                        .map((t) => (
                          <option key={t.id} value={t.id}>
                            {t.name}
                          </option>
                        ))}
                    </Select>
                    {a.module_week_id && (
                      <Button
                        size="sm"
                        variant="secondary"
                        onClick={() => setDrawer(a.module_week_id)}
                      >
                        {['RankingExhausted', 'ClassAtRisk', 'LateReply'].includes(a.type)
                          ? 'Assign an instructor'
                          : 'Open class'}
                      </Button>
                    )}
                    {a.help_request_id && (
                      <Button
                        size="sm"
                        variant="secondary"
                        onClick={() => setHelp(a.help_request_id)}
                      >
                        Open help request
                      </Button>
                    )}
                    {a.type === 'TypedReply' &&
                      a.module_week_id &&
                      (weeks.data ?? [])
                        .find((w) => w.id === a.module_week_id)
                        ?.booking.some((b) => b.status === 'Active') && (
                        <Button
                          size="sm"
                          variant="destructive"
                          onClick={async () => {
                            if (
                              await confirm({
                                title: 'Release and find a replacement?',
                                body: 'Only do this if the message really is a cancellation. The instructor is told, and we start asking other instructors.',
                                danger: true,
                                confirmLabel: 'Release and find a replacement',
                              })
                            )
                              await run(async () => {
                                await rpc('release_booking', {
                                  p_module_week_id: a.module_week_id!,
                                  p_reason: 'Typed cancellation',
                                });
                                await rpc('attention_done', {
                                  p_item_id: a.id,
                                  p_note: 'Released after typed cancellation',
                                });
                              }, 'Instructor released');
                          }}
                        >
                          Release and find a replacement
                        </Button>
                      )}
                    {a.instructor_id && !a.help_request_id && (
                      <Button
                        size="sm"
                        variant="secondary"
                        onClick={() => (setReplyText(''), setReplyFor(a))}
                      >
                        Reply
                      </Button>
                    )}
                    <Button size="sm" variant="ghost" onClick={() => (setNote(''), setDoneFor(a))}>
                      Mark done
                    </Button>
                  </div>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
      <Modal open={!!doneFor} onOpenChange={(o) => !o && setDoneFor(null)} title="Mark done">
        <Field label="Note (optional)">
          <Input value={note} onChange={(e) => setNote(e.target.value)} />
        </Field>
        <div className="mt-3 flex justify-end">
          <Button
            onClick={() => (
              void run(
                () => rpc('attention_done', { p_item_id: doneFor!.id, p_note: note || undefined }),
                'Marked done',
              ),
              setDoneFor(null)
            )}
          >
            Mark done
          </Button>
        </div>
      </Modal>
      <Modal
        open={!!replyFor}
        onOpenChange={(o) => !o && setReplyFor(null)}
        title={`Reply to ${replyFor?.instructor_id ? names.get(replyFor.instructor_id) : ''}`}
        description="Sent in their Discord channel and by email. Nothing about the booking changes."
      >
        <Textarea
          aria-label="Your reply"
          value={replyText}
          onChange={(e) => setReplyText(e.target.value)}
        />
        <div className="mt-3 flex justify-end">
          <Button
            disabled={!replyText.trim()}
            onClick={() => (
              void run(
                () => rpc('reply_to_instructor', { p_item_id: replyFor!.id, p_text: replyText }),
                'Reply sent',
              ),
              setReplyFor(null)
            )}
          >
            Send reply
          </Button>
        </div>
      </Modal>
      {openWeek && <ClassDrawer week={openWeek} names={names} onClose={() => setDrawer(null)} />}
      {help && <HelpPanel id={help} onClose={() => setHelp(null)} />}
    </div>
  );
}

/** Working a help request in the app (PRD 10.6). */
export function HelpPanel({ id, onClose }: { id: string; onClose: () => void }) {
  const team = useTeam();
  const confirm = useConfirm();
  const { run, err } = useRun();
  const h = useQuery({
    queryKey: ['help_request', id],
    queryFn: async () => {
      const [r, m] = await Promise.all([
        supabase
          .from('help_request')
          .select(
            '*, module_week(module(name), first_class_at), instructor:requester_instructor_id(full_name)',
          )
          .eq('id', id)
          .single(),
        supabase.from('message').select('*').eq('help_request_id', id).order('created_at'),
      ]);
      return { req: check(r), messages: check(m) };
    },
  });
  const [reply, setReply] = useState('');
  const [resolves, setResolves] = useState(false);
  const [note, setNote] = useState('');
  const req = h.data?.req;
  const teamNames = new Map((team.data ?? []).map((t) => [t.id, t.name]));
  const closed = req && ['Resolved', 'Closed', 'ConvertedToCancellation'].includes(req.status);
  return (
    <Modal open onOpenChange={(o) => !o && onClose()} title="Help request" wide>
      {!req ? (
        <SkeletonRows rows={4} />
      ) : (
        <div className="space-y-4 text-sm">
          <div className="flex flex-wrap gap-2">
            <Badge tone={req.severity === 'Urgent' ? 'danger' : 'neutral'}>{req.severity}</Badge>
            <Badge tone="info">{helpStatusLabel[req.status]}</Badge>
            <span>
              From{' '}
              <strong>
                {(req.instructor as { full_name: string } | null)?.full_name ??
                  (req.requester_team_member_id
                    ? teamNames.get(req.requester_team_member_id)
                    : 'the operations team')}
              </strong>{' '}
              · {(req.module_week as { module: { name: string } | null } | null)?.module?.name} ·
              class{' '}
              {fmtPT((req.module_week as { first_class_at: string | null } | null)?.first_class_at)}
            </span>
          </div>
          <div>
            <strong>Needs:</strong>{' '}
            {req.categories
              .map((c) => helpCategories.find((x) => x.code === c)?.label ?? c)
              .join(', ')}
            {req.details && <p className="mt-1 whitespace-pre-line">{req.details}</p>}
          </div>
          <div className="text-muted-foreground">
            Urgency: {req.urgency} · reply by {req.reply_channel} · answer by{' '}
            {fmtLocal(req.response_target_at)} ({fmtPT(req.response_target_at)}) · sent to{' '}
            {req.routed_to.map((r) => teamNames.get(r)).join(', ')}
            {req.assigned_to && ` · taken by ${teamNames.get(req.assigned_to)}`}
          </div>
          {(h.data?.messages ?? []).length > 0 && (
            <ul className="space-y-1">
              {h.data!.messages.map((m) => (
                <li
                  key={m.id}
                  className={`rounded p-2 text-xs ${m.direction === 'Inbound' ? 'bg-warning-soft' : 'bg-muted'}`}
                >
                  <strong>
                    {m.direction === 'Inbound'
                      ? `From ${m.recipient_label}`
                      : `${messageTitle(m.template_id)} to ${m.recipient_label} (${m.channel})`}
                  </strong>{' '}
                  · {fmtLocal(m.created_at)}
                  <div className="whitespace-pre-line">{m.body_text}</div>
                </li>
              ))}
            </ul>
          )}
          {!closed && (
            <>
              <div className="flex flex-wrap gap-2">
                {req.status !== 'InProgress' && (
                  <Button
                    size="sm"
                    onClick={() => run(() => rpc('help_ack', { p_help_id: id }), 'You’re on it')}
                  >
                    I’m on it
                  </Button>
                )}
                <Select
                  aria-label="Reassign to a team member"
                  className="h-8 w-48"
                  value=""
                  onChange={(e) =>
                    e.target.value &&
                    void run(
                      () =>
                        rpc('help_reassign', { p_help_id: id, p_team_member_id: e.target.value }),
                      'Reassigned',
                    )
                  }
                >
                  <option value="">Reassign to</option>
                  {(team.data ?? []).map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.name}
                    </option>
                  ))}
                </Select>
                <Button
                  size="sm"
                  variant="destructive"
                  onClick={async () => {
                    if (
                      await confirm({
                        title: 'Treat this as a cancellation?',
                        body: 'Use this when the help request really means “I can’t teach”. The instructor is released and we start asking other instructors.',
                        danger: true,
                        confirmLabel: 'Treat as a cancellation',
                      })
                    )
                      await run(
                        () => rpc('help_convert_to_cancellation', { p_help_id: id }),
                        'Treated as a cancellation',
                      );
                  }}
                >
                  Treat as a cancellation
                </Button>
              </div>
              <Field label="Reply to the instructor (sent by their chosen channel)">
                <Textarea value={reply} onChange={(e) => setReply(e.target.value)} />
              </Field>
              <div className="flex items-center gap-3">
                <Checkbox label="This resolves it" checked={resolves} onChange={setResolves} />
                <Button
                  disabled={!reply.trim()}
                  onClick={() =>
                    run(
                      () =>
                        rpc('help_reply', { p_help_id: id, p_text: reply, p_resolves: resolves }),
                      'Reply sent',
                    ).then(() => setReply(''))
                  }
                >
                  Send reply
                </Button>
              </div>
              <div className="flex flex-wrap items-end gap-2 border-t pt-3">
                <Field label="Note (required to resolve outside the app or close)">
                  <Input value={note} onChange={(e) => setNote(e.target.value)} className="w-80" />
                </Field>
                <Button
                  variant="secondary"
                  disabled={!note.trim()}
                  onClick={() =>
                    run(
                      () =>
                        rpc('help_set_status', {
                          p_help_id: id,
                          p_status: 'Resolved',
                          p_note: note,
                        }),
                      'Resolved',
                    )
                  }
                >
                  Resolved outside the app
                </Button>
                <Button
                  variant="ghost"
                  disabled={!note.trim()}
                  onClick={() =>
                    run(
                      () =>
                        rpc('help_set_status', { p_help_id: id, p_status: 'Closed', p_note: note }),
                      'Closed',
                    )
                  }
                >
                  Close (no action needed)
                </Button>
              </div>
            </>
          )}
          <ErrorText error={err} />
        </div>
      )}
    </Modal>
  );
}
