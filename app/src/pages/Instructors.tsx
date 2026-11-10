import { useMemo, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { MailCheck, Plus, Send, Trash2, UserRound } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { useInstructors, useSystem, type Instructor } from '@/lib/data';
import { ago, fmtLocal, fmtPT } from '@/lib/time';
import { isDiscordId, isEmail, parseChannelLink } from '@/lib/validation';
import { useFormErrors } from '@/lib/useFormErrors';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Checkbox,
  Drawer,
  Empty,
  ErrorText,
  Field,
  HelpTip,
  Input,
  Modal,
  Notice,
  PageHeader,
  Select,
  SkeletonRows,
  Textarea,
  Toolbar,
  tableWrap,
  td,
  th,
  thead,
  trowClick,
} from '@/components/ui';

export type InstructorRow = NonNullable<ReturnType<typeof useInstructors>['data']>[number];

/** Upcoming confirmed classes and instructor order places, across ALL domains. */
export function useInstructorContext() {
  return useQuery({
    queryKey: ['booking', 'instructor-context'],
    queryFn: async () => {
      const [b, r] = await Promise.all([
        supabase
          .from('booking')
          .select('instructor_id, module_week(first_class_at, module(name, domain(name)))')
          .eq('status', 'Active'),
        supabase
          .from('module_ranking')
          .select('instructor_id, rank, module(name, status, domain(name))'),
      ]);
      const bookings = check(b);
      const rankings = check(r);
      const upcoming = new Map<string, string[]>();
      const now = Date.now();
      for (const x of bookings) {
        const w = x.module_week;
        if (!w?.first_class_at || new Date(w.first_class_at).getTime() < now) continue;
        const label = `${w.module?.name} (${w.module?.domain?.name}), ${fmtPT(w.first_class_at)}`;
        upcoming.set(x.instructor_id, [...(upcoming.get(x.instructor_id) ?? []), label]);
      }
      const ranked = new Map<string, string[]>();
      for (const x of rankings) {
        if (!x.module || x.module.status === 'Archived') continue;
        const place = x.rank === 1 ? 'Primary' : `Backup ${x.rank - 1}`;
        const label = `${x.module.name} (${x.module.domain?.name}): ${place}`;
        ranked.set(x.instructor_id, [...(ranked.get(x.instructor_id) ?? []), label]);
      }
      return { upcoming, ranked };
    },
  });
}

const FILTERS: { value: string; label: string; test: (i: InstructorRow) => boolean }[] = [
  { value: 'active', label: 'Active', test: (i) => i.status === 'Active' },
  {
    value: 'unchecked',
    label: 'Contact details not checked',
    test: (i) => i.status === 'Active' && !i.verified_at && !i.is_test,
  },
  {
    value: 'problems',
    label: 'Messages failing',
    test: (i) => !!i.email_bounced_at || !!i.discord_failed_at,
  },
  { value: 'test', label: 'Test instructors', test: (i) => i.is_test },
  { value: 'Inactive', label: 'Inactive', test: (i) => i.status === 'Inactive' },
  { value: 'Archived', label: 'Archived', test: (i) => i.status === 'Archived' },
  { value: 'all', label: 'Everyone', test: () => true },
];

export default function Instructors() {
  const { data, isLoading, error } = useInstructors();
  const ctx = useInstructorContext();
  const [params, setParams] = useSearchParams();
  const filter = params.get('show') ?? 'active';
  const [q, setQ] = useState('');
  const [editing, setEditing] = useState<InstructorRow | 'new' | null>(null);
  const test = FILTERS.find((f) => f.value === filter)?.test ?? FILTERS[0]!.test;

  const rows = useMemo(
    () =>
      (data ?? []).filter(
        (i) =>
          test(i) &&
          `${i.full_name} ${i.primary_email} ${i.instructor_email.map((e) => e.email).join(' ')}`
            .toLowerCase()
            .includes(q.toLowerCase()),
      ),
    [data, q, test],
  );
  const unchecked = (data ?? []).filter(FILTERS[1]!.test).length;

  return (
    <div>
      <PageHeader title="Instructors" description="Each real person once, shared by every domain.">
        <Button onClick={() => setEditing('new')}>
          <Plus className="h-4 w-4" aria-hidden /> Add instructor
        </Button>
      </PageHeader>
      {unchecked > 0 && filter !== 'unchecked' && (
        <div className="mb-4">
          <Notice tone="warning">
            {unchecked} instructor{unchecked === 1 ? ' has' : 's have'} not had their contact
            details checked. They are not asked once a domain is live.{' '}
            <button
              className="font-medium underline underline-offset-2"
              onClick={() => setParams({ show: 'unchecked' })}
            >
              Show them
            </button>
          </Notice>
        </div>
      )}
      <Toolbar>
        <Input
          placeholder="Search by name or email"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          className="w-64"
          aria-label="Search"
        />
        <Select
          value={filter}
          onChange={(e) => setParams({ show: e.target.value })}
          className="w-64"
          aria-label="Show"
        >
          {FILTERS.map((f) => (
            <option key={f.value} value={f.value}>
              {f.label}
            </option>
          ))}
        </Select>
        <span className="text-sm text-muted-foreground">{rows.length} shown</span>
      </Toolbar>
      <ErrorText error={error} />
      {isLoading ? (
        <SkeletonRows />
      ) : rows.length === 0 ? (
        <Empty
          title={q || filter !== 'active' ? 'No instructors match' : 'No instructors yet'}
          icon={<UserRound className="h-5 w-5" />}
          action={<Button onClick={() => setEditing('new')}>Add instructor</Button>}
        >
          Add each real person once. The same record is used in every domain.
        </Empty>
      ) : (
        <div className={tableWrap}>
          <table className="w-full">
            <thead className={thead}>
              <tr>
                <th className={th}>Name</th>
                <th className={th}>Status</th>
                <th className={`${th} hidden lg:table-cell`}>Teaches</th>
                <th className={`${th} hidden md:table-cell`}>Upcoming classes</th>
                <th className={`${th} hidden md:table-cell`}>Last reply</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((i) => {
                const ranked = ctx.data?.ranked.get(i.id) ?? [];
                const upcoming = ctx.data?.upcoming.get(i.id) ?? [];
                return (
                  <tr key={i.id} className={trowClick} onClick={() => setEditing(i)}>
                    <td className={td}>
                      <div className="font-medium">{i.full_name}</div>
                      <div className="text-xs text-muted-foreground">{i.primary_email}</div>
                    </td>
                    <td className={td}>
                      <StatusBadges i={i} />
                    </td>
                    <td className={`${td} hidden lg:table-cell`}>
                      {ranked.length ? (
                        <span title={ranked.join('\n')}>
                          {ranked.length} module{ranked.length === 1 ? '' : 's'}
                        </span>
                      ) : (
                        <span className="text-muted-foreground">Not in any order</span>
                      )}
                    </td>
                    <td
                      className={`${td} hidden tabular-nums md:table-cell`}
                      title={upcoming.join('\n')}
                    >
                      {upcoming.length || <span className="text-muted-foreground">None</span>}
                    </td>
                    <td className={`${td} hidden text-muted-foreground md:table-cell`}>
                      {i.last_response_at ? `${ago(i.last_response_at)} ago` : 'Never'}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {editing && (
        <InstructorDrawer
          instructor={editing === 'new' ? null : editing}
          all={data ?? []}
          ranked={editing === 'new' ? [] : (ctx.data?.ranked.get(editing.id) ?? [])}
          upcoming={editing === 'new' ? [] : (ctx.data?.upcoming.get(editing.id) ?? [])}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function StatusBadges({ i }: { i: InstructorRow }) {
  return (
    <div className="flex flex-wrap gap-1">
      {i.status !== 'Active' && <Badge>{i.status}</Badge>}
      {i.verified_at ? (
        <Badge tone="success">Contact checked</Badge>
      ) : (
        <Badge tone="warning">Not checked yet</Badge>
      )}
      {i.is_test && <Badge tone="accent">Test instructor</Badge>}
      {i.email_bounced_at && <Badge tone="danger">Email bounced</Badge>}
      {i.discord_failed_at && <Badge tone="danger">Discord message failed</Badge>}
    </div>
  );
}

function Group({
  title,
  description,
  children,
}: {
  title: string;
  description?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="space-y-3 border-b border-border pb-5 last:border-0">
      <div>
        <h3 className="text-sm font-semibold">{title}</h3>
        {description && <p className="text-xs text-muted-foreground">{description}</p>}
      </div>
      {children}
    </section>
  );
}

export function InstructorDrawer({
  instructor,
  all,
  ranked = [],
  upcoming = [],
  onClose,
  onSaved,
}: {
  instructor: InstructorRow | null;
  all: InstructorRow[];
  ranked?: string[];
  upcoming?: string[];
  onClose: () => void;
  onSaved?: (id: string) => void;
}) {
  const qc = useQueryClient();
  const confirm = useConfirm();
  const system = useSystem();
  const guild = system.data?.config.discord_guild_id ?? null;
  const [f, setF] = useState({
    full_name: instructor?.full_name ?? '',
    primary_email: instructor?.primary_email ?? '',
    discord_user_id: instructor?.discord_user_id ?? '',
    discord_channel_link: instructor?.discord_channel_link ?? '',
    phone: instructor?.phone ?? '',
    notes: instructor?.notes ?? '',
    is_test: instructor?.is_test ?? false,
  });
  const [extras, setExtras] = useState<string[]>(
    instructor?.instructor_email.filter((e) => !e.is_primary).map((e) => e.email) ?? [],
  );
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const [deact, setDeact] = useState<{ booking_id: string; label: string }[] | null>(null);
  const [decisions, setDecisions] = useState<Record<string, 'keep' | 'release'>>({});

  const errors: Record<string, string> = {};
  if (!f.full_name.trim()) errors.full_name = 'Enter the full name.';
  if (!isEmail(f.primary_email)) errors.primary_email = 'Enter a valid email address.';
  if (f.discord_user_id && !isDiscordId(f.discord_user_id))
    errors.discord_user_id = 'A Discord user ID is 17 to 20 digits.';
  if (f.discord_channel_link) {
    const p = parseChannelLink(f.discord_channel_link);
    if (!p)
      errors.discord_channel_link = 'Paste the link that starts with https://discord.com/channels/';
    else if (guild && p.serverId !== guild)
      errors.discord_channel_link = 'This channel is in a different Discord server.';
  }
  extras.forEach((e, idx) => {
    if (!isEmail(e)) errors[`extra${idx}`] = 'Enter a valid email address.';
  });
  const v = useFormErrors(errors);
  const emails = [f.primary_email, ...extras].map((e) => e.trim().toLowerCase()).filter(Boolean);
  const dup = all.find(
    (o) =>
      o.id !== instructor?.id &&
      (o.instructor_email.some((e) => emails.includes(e.email.toLowerCase())) ||
        emails.includes(o.primary_email.toLowerCase()) ||
        (!!f.discord_user_id && o.discord_user_id === f.discord_user_id.trim())),
  );
  const channel = parseChannelLink(f.discord_channel_link);
  const contactChanged =
    !!instructor &&
    (instructor.primary_email !== f.primary_email.trim().toLowerCase() ||
      (instructor.discord_user_id ?? '') !== f.discord_user_id.trim() ||
      (instructor.discord_channel_id ?? '') !== (channel?.channelId ?? ''));
  const refresh = () => qc.invalidateQueries();

  async function save() {
    setErr(null);
    if (!v.submit() || dup) return;
    setSaving(true);
    try {
      const row = {
        full_name: f.full_name.trim(),
        primary_email: f.primary_email.trim().toLowerCase(),
        discord_user_id: f.discord_user_id.trim() || null,
        discord_channel_link: f.discord_channel_link.trim() || null,
        discord_channel_id: channel?.channelId ?? null,
        discord_server_id: channel?.serverId ?? null,
        phone: f.phone.trim() || null,
        notes: f.notes.trim() || null,
        is_test: f.is_test,
      };
      let id = instructor?.id;
      if (instructor) {
        check(
          await supabase
            .from('instructor')
            .update({ ...row, version: instructor.version })
            .eq('id', instructor.id)
            .select(),
        );
      } else {
        const created = check(await supabase.from('instructor').insert(row).select().single())!;
        id = created.id;
      }
      const current = instructor?.instructor_email.filter((e) => !e.is_primary) ?? [];
      const wanted = extras.map((e) => e.trim().toLowerCase()).filter(Boolean);
      for (const e of current.filter((c) => !wanted.includes(c.email)))
        check(await supabase.from('instructor_email').delete().eq('id', e.id));
      for (const e of wanted.filter((w) => !current.some((c) => c.email === w)))
        check(await supabase.from('instructor_email').insert({ instructor_id: id!, email: e }));
      toast.success(
        contactChanged
          ? 'Saved. The contact details changed, so send a new contact check.'
          : instructor
            ? 'Changes saved'
            : 'Instructor added',
      );
      await refresh();
      onSaved?.(id!);
      onClose();
    } catch (e) {
      setErr(e);
    } finally {
      setSaving(false);
    }
  }

  async function act(fn: () => Promise<unknown>, ok: string) {
    setErr(null);
    try {
      await fn();
      await poke();
      toast.success(ok);
      await refresh();
    } catch (e) {
      setErr(e);
    }
  }

  async function deactivate(
    status: 'Inactive' | 'Archived',
    withDecisions?: Record<string, string>,
  ) {
    if (!instructor) return;
    const res = (await rpc('deactivate_instructor', {
      p_instructor_id: instructor.id,
      p_status: status,
      p_decisions: withDecisions ?? undefined,
    })) as { needs_decision?: boolean; bookings?: { booking_id: string; label: string }[] };
    if (res?.needs_decision && res.bookings) {
      setDecisions(Object.fromEntries(res.bookings.map((b) => [b.booking_id, 'keep'])));
      setDeact(res.bookings);
      return;
    }
    await poke();
    toast.success(
      `${instructor.full_name} is now ${status === 'Inactive' ? 'inactive' : 'archived'}`,
    );
    setDeact(null);
    await refresh();
  }

  return (
    <Drawer
      open
      onOpenChange={(o) => !o && onClose()}
      title={instructor ? instructor.full_name : 'Add instructor'}
      description={
        instructor
          ? instructor.primary_email
          : 'Add each real person once. They can then be used in any domain.'
      }
      footer={
        <div className="flex flex-wrap items-center gap-2">
          <Button onClick={() => void save()} loading={saving} disabled={!!dup}>
            {instructor ? 'Save changes' : 'Add instructor'}
          </Button>
          <Button variant="secondary" onClick={onClose}>
            Cancel
          </Button>
        </div>
      }
    >
      <div className="space-y-5">
        {dup && (
          <Notice tone="warning">
            An instructor with this email or Discord ID already exists: {dup.full_name}. Edit that
            record instead.
          </Notice>
        )}

        <Group title="Basic details">
          <Field label="Full name" required error={v.show('full_name')}>
            <Input
              value={f.full_name}
              onBlur={v.touch('full_name')}
              onChange={(e) => setF({ ...f, full_name: e.target.value })}
            />
          </Field>
          <Field
            label="Email"
            required
            hint="Messages are sent to this address."
            error={v.show('primary_email')}
          >
            <Input
              value={f.primary_email}
              onBlur={v.touch('primary_email')}
              onChange={(e) => setF({ ...f, primary_email: e.target.value })}
            />
          </Field>
          <div className="space-y-2">
            <span className="block text-sm font-medium">
              Other emails{' '}
              <HelpTip>
                Other addresses this person uses. Replies from them are matched to this instructor.
              </HelpTip>
            </span>
            {extras.map((e, idx) => (
              <div key={idx}>
                <div className="flex gap-2">
                  <Input
                    value={e}
                    aria-label={`Other email ${idx + 1}`}
                    onBlur={v.touch(`extra${idx}`)}
                    aria-invalid={!!v.show(`extra${idx}`)}
                    onChange={(ev) =>
                      setExtras(extras.map((x, j) => (j === idx ? ev.target.value : x)))
                    }
                  />
                  <Button
                    variant="ghost"
                    size="icon"
                    aria-label="Remove this email"
                    onClick={() => setExtras(extras.filter((_, j) => j !== idx))}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
                {v.show(`extra${idx}`) && (
                  <span className="text-xs text-danger-strong">{v.show(`extra${idx}`)}</span>
                )}
              </div>
            ))}
            <Button size="sm" variant="secondary" onClick={() => setExtras([...extras, ''])}>
              Add another email
            </Button>
          </div>
          <Field label="Phone" hint="Only for the team, for example to call in an emergency.">
            <Input value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} />
          </Field>
          <Field label="Notes">
            <Textarea value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} />
          </Field>
          <Checkbox
            label="Test instructor"
            hint="For trying things out. Test instructors are never booked in a live domain."
            checked={f.is_test}
            onChange={(c) => setF({ ...f, is_test: c })}
          />
        </Group>

        <Group
          title="Discord"
          description={
            <>
              How to copy the details: in Discord, open User Settings, then Advanced, and turn on
              Developer Mode. Then right click the person and choose Copy User ID, and right click
              their channel and choose Copy Link.
            </>
          }
        >
          <Field
            label="Discord user ID"
            hint="17 to 20 digits. Used to tag them in their channel."
            error={v.show('discord_user_id')}
          >
            <Input
              value={f.discord_user_id}
              onBlur={v.touch('discord_user_id')}
              onChange={(e) => setF({ ...f, discord_user_id: e.target.value })}
            />
          </Field>
          <Field
            label="Their channel link"
            hint={
              channel ? 'Link recognised.' : 'For example https://discord.com/channels/123…/456…'
            }
            error={v.show('discord_channel_link')}
          >
            <Input
              value={f.discord_channel_link}
              onBlur={v.touch('discord_channel_link')}
              onChange={(e) => setF({ ...f, discord_channel_link: e.target.value })}
            />
          </Field>
        </Group>

        {instructor && (
          <Group
            title="Contact check"
            description="A short message on Discord and by email that they confirm with one tap. Only checked instructors are asked in a live domain."
          >
            <div className="flex flex-wrap items-center gap-2">
              {instructor.verified_at ? (
                <Badge tone="success">Checked {fmtLocal(instructor.verified_at)}</Badge>
              ) : (
                <Badge tone="warning">Not checked yet</Badge>
              )}
              {instructor.email_bounced_at && <Badge tone="danger">Email bounced</Badge>}
              {instructor.discord_failed_at && <Badge tone="danger">Discord message failed</Badge>}
            </div>
            {contactChanged && (
              <Notice tone="warning">
                Saving new email or Discord details removes the check, so send a new one afterwards.
              </Notice>
            )}
            <div className="flex flex-wrap gap-2">
              <Button
                size="sm"
                variant="secondary"
                onClick={() =>
                  act(
                    () => rpc('send_test_message', { p_instructor_id: instructor.id }),
                    'Contact check sent by Discord and email',
                  )
                }
              >
                <Send className="h-3.5 w-3.5" aria-hidden /> Send contact check
              </Button>
              {!instructor.verified_at && (
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() =>
                    act(
                      () => rpc('mark_verified_manually', { p_instructor_id: instructor.id }),
                      'Marked as checked',
                    )
                  }
                >
                  <MailCheck className="h-3.5 w-3.5" aria-hidden /> Mark as checked
                </Button>
              )}
            </div>
          </Group>
        )}

        {instructor && (
          <Group title="Availability">
            <div className="text-sm">
              <div className="mb-1 font-medium">Upcoming classes (every domain)</div>
              {upcoming.length ? (
                <ul className="list-disc space-y-0.5 pl-5">
                  {upcoming.map((u) => (
                    <li key={u}>{u}</li>
                  ))}
                </ul>
              ) : (
                <p className="text-muted-foreground">None.</p>
              )}
            </div>
            <div className="text-sm">
              <div className="mb-1 font-medium">Instructor order</div>
              {ranked.length ? (
                <ul className="list-disc space-y-0.5 pl-5">
                  {ranked.map((u) => (
                    <li key={u}>{u}</li>
                  ))}
                </ul>
              ) : (
                <p className="text-muted-foreground">Not in any module's order yet.</p>
              )}
            </div>
            <Unavailability instructor={instructor} />
            <div className="flex flex-wrap gap-2 rounded-md border border-border p-3">
              <div className="w-full text-sm text-muted-foreground">
                {instructor.status === 'Active'
                  ? 'Inactive instructors are not asked. If they are being asked now, the request is withdrawn politely and the next instructor is asked.'
                  : `This instructor is ${instructor.status.toLowerCase()}.`}
              </div>
              {instructor.status === 'Active' ? (
                <Button
                  variant="destructive"
                  size="sm"
                  onClick={async () => {
                    if (
                      await confirm({
                        title: `Make ${instructor.full_name} inactive?`,
                        body: 'They will not be asked again. If they have confirmed classes, you will choose whether to keep each one.',
                        danger: true,
                        confirmLabel: 'Make inactive',
                      })
                    )
                      await act(() => deactivate('Inactive'), 'Done');
                  }}
                >
                  Make inactive
                </Button>
              ) : (
                <Button
                  size="sm"
                  variant="secondary"
                  onClick={() =>
                    act(
                      async () =>
                        check(
                          await supabase
                            .from('instructor')
                            .update({ status: 'Active', version: instructor.version })
                            .eq('id', instructor.id)
                            .select(),
                        ),
                      'Active again',
                    )
                  }
                >
                  Make active again
                </Button>
              )}
              {instructor.status !== 'Archived' && (
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={async () => {
                    if (
                      await confirm({
                        title: `Archive ${instructor.full_name}?`,
                        body: 'Instructors with history are archived, never deleted. They no longer appear in lists.',
                        danger: true,
                        confirmLabel: 'Archive',
                      })
                    )
                      await act(() => deactivate('Archived'), 'Archived');
                  }}
                >
                  Archive
                </Button>
              )}
            </div>
          </Group>
        )}
        <ErrorText error={err} />
      </div>
      <Modal
        open={!!deact}
        onOpenChange={(o) => !o && setDeact(null)}
        title={`Keep these ${deact?.length ?? 0} classes?`}
        description="Choose for each class whether they still teach it, or release them and find someone else."
      >
        <div className="space-y-2">
          {deact?.map((b) => (
            <div
              key={b.booking_id}
              className="flex flex-wrap items-center justify-between gap-2 text-sm"
            >
              <span>{b.label}</span>
              <Select
                className="w-56"
                value={decisions[b.booking_id]}
                onChange={(e) =>
                  setDecisions({
                    ...decisions,
                    [b.booking_id]: e.target.value as 'keep' | 'release',
                  })
                }
              >
                <option value="keep">Keep, they still teach it</option>
                <option value="release">Release and find someone else</option>
              </Select>
            </div>
          ))}
          <div className="flex justify-end gap-2 pt-2">
            <Button variant="secondary" onClick={() => setDeact(null)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={() => act(() => deactivate('Inactive', decisions), 'Done')}
            >
              Make inactive
            </Button>
          </div>
        </div>
      </Modal>
    </Drawer>
  );
}

function Unavailability({ instructor }: { instructor: InstructorRow }) {
  const qc = useQueryClient();
  const [r, setR] = useState({ from: '', to: '', reason: '' });
  const [err, setErr] = useState<unknown>(null);
  const v = useFormErrors({
    from: !r.from ? 'Choose the first day.' : undefined,
    to: !r.to
      ? 'Choose the last day.'
      : r.from && r.to < r.from
        ? 'The last day must be on or after the first day.'
        : undefined,
  });
  return (
    <div className="text-sm">
      <div className="mb-1 font-medium">Dates they cannot teach</div>
      <ul className="mb-2 space-y-1">
        {instructor.instructor_unavailability.map((u) => (
          <li
            key={u.id}
            className="flex items-center justify-between rounded-md border border-border px-3 py-1.5"
          >
            <span>
              {u.from_date} to {u.to_date}{' '}
              {u.reason && <span className="text-muted-foreground">({u.reason})</span>}
            </span>
            <Button
              size="sm"
              variant="ghost"
              onClick={async () => {
                check(await supabase.from('instructor_unavailability').delete().eq('id', u.id));
                toast.success('Dates removed');
                await qc.invalidateQueries();
              }}
            >
              Remove
            </Button>
          </li>
        ))}
        {instructor.instructor_unavailability.length === 0 && (
          <li className="text-muted-foreground">None.</li>
        )}
      </ul>
      <div className="flex flex-wrap items-start gap-2">
        <Field label="First day" error={v.show('from')}>
          <Input
            type="date"
            value={r.from}
            onBlur={v.touch('from')}
            onChange={(e) => setR({ ...r, from: e.target.value })}
          />
        </Field>
        <Field label="Last day" error={v.show('to')}>
          <Input
            type="date"
            value={r.to}
            onBlur={v.touch('to')}
            onChange={(e) => setR({ ...r, to: e.target.value })}
          />
        </Field>
        <Field label="Reason (optional)">
          <Input value={r.reason} onChange={(e) => setR({ ...r, reason: e.target.value })} />
        </Field>
        <Button
          variant="secondary"
          className="mt-6"
          onClick={async () => {
            setErr(null);
            if (!v.submit()) return;
            try {
              check(
                await supabase.from('instructor_unavailability').insert({
                  instructor_id: instructor.id,
                  from_date: r.from,
                  to_date: r.to,
                  reason: r.reason || null,
                }),
              );
              setR({ from: '', to: '', reason: '' });
              v.reset();
              toast.success('Dates added');
              await qc.invalidateQueries();
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Add dates
        </Button>
      </div>
      <ErrorText error={err} />
    </div>
  );
}

export type { Instructor };
