import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Plus, Send, Trash2 } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { useInstructors, useSystem, type Instructor } from '@/lib/data';
import { ago, fmtPT } from '@/lib/time';
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
  Input,
  Modal,
  PageHeader,
  Select,
  Spinner,
  Textarea,
  td,
  th,
} from '@/components/ui';

type InstructorRow = NonNullable<ReturnType<typeof useInstructors>['data']>[number];

/** Upcoming active bookings and ranking memberships across ALL domains (INS-6). */
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
        const label = `${w.module?.domain?.name} · ${w.module?.name} · ${fmtPT(w.first_class_at)}`;
        upcoming.set(x.instructor_id, [...(upcoming.get(x.instructor_id) ?? []), label]);
      }
      const ranked = new Map<string, string[]>();
      for (const x of rankings) {
        if (!x.module || x.module.status === 'Archived') continue;
        const label = `${x.module.domain?.name} · ${x.module.name} (#${x.rank})`;
        ranked.set(x.instructor_id, [...(ranked.get(x.instructor_id) ?? []), label]);
      }
      return { upcoming, ranked };
    },
  });
}

export default function Instructors() {
  const { data, isLoading, error } = useInstructors();
  const ctx = useInstructorContext();
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('Active');
  const [editing, setEditing] = useState<InstructorRow | 'new' | null>(null);

  const rows = useMemo(
    () =>
      (data ?? []).filter(
        (i) =>
          (status === 'All' || i.status === status) &&
          `${i.full_name} ${i.primary_email} ${i.instructor_email.map((e) => e.email).join(' ')}`
            .toLowerCase()
            .includes(q.toLowerCase()),
      ),
    [data, q, status],
  );

  return (
    <div>
      <PageHeader title="Instructors">
        <Input
          placeholder="Search name or email"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          className="w-56"
        />
        <Select value={status} onChange={(e) => setStatus(e.target.value)} className="w-36">
          {['Active', 'Inactive', 'Archived', 'All'].map((s) => (
            <option key={s}>{s}</option>
          ))}
        </Select>
        <Button onClick={() => setEditing('new')}>
          <Plus className="h-4 w-4" /> Add instructor
        </Button>
      </PageHeader>
      <ErrorText error={error} />
      {isLoading ? (
        <Spinner />
      ) : rows.length === 0 ? (
        <Empty title="No instructors here yet">
          Add each real person once. Existing instructors are reused across domains.
        </Empty>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full">
            <thead className="border-b bg-slate-50">
              <tr>
                <th className={th}>Name</th>
                <th className={th}>Status</th>
                <th className={th}>Modules ranked in</th>
                <th className={th}>Upcoming bookings</th>
                <th className={th}>Last response</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((i) => (
                <tr
                  key={i.id}
                  className="cursor-pointer border-b last:border-0 hover:bg-slate-50"
                  onClick={() => setEditing(i)}
                >
                  <td className={td}>
                    <div className="font-medium">{i.full_name}</div>
                    <div className="text-xs text-slate-500">{i.primary_email}</div>
                  </td>
                  <td className={td}>
                    <div className="flex flex-wrap gap-1">
                      <Badge tone={i.status === 'Active' ? 'green' : 'gray'}>{i.status}</Badge>
                      {i.verified_at ? (
                        <Badge tone="blue">✓ Verified</Badge>
                      ) : (
                        <Badge tone="amber">Not verified</Badge>
                      )}
                      {i.is_test && <Badge tone="purple">TEST</Badge>}
                      {i.email_bounced_at && <Badge tone="red">Email bounced</Badge>}
                      {i.discord_failed_at && <Badge tone="red">Discord failed</Badge>}
                    </div>
                  </td>
                  <td className={`${td} text-xs`}>
                    {(ctx.data?.ranked.get(i.id) ?? []).join(', ') || '—'}
                  </td>
                  <td className={`${td} text-xs`}>
                    {(ctx.data?.upcoming.get(i.id) ?? []).join(', ') || '—'}
                  </td>
                  <td className={`${td} text-xs`}>
                    {i.last_response_at ? `${ago(i.last_response_at)} ago` : '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {editing && (
        <InstructorDrawer
          instructor={editing === 'new' ? null : editing}
          all={data ?? []}
          upcoming={editing === 'new' ? [] : (ctx.data?.upcoming.get(editing.id) ?? [])}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function InstructorDrawer({
  instructor,
  all,
  upcoming,
  onClose,
}: {
  instructor: InstructorRow | null;
  all: InstructorRow[];
  upcoming: string[];
  onClose: () => void;
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
  if (!f.full_name.trim()) errors.full_name = 'Full name is required.';
  if (!isEmail(f.primary_email)) errors.primary_email = 'Enter a valid email address.';
  if (f.discord_user_id && !isDiscordId(f.discord_user_id))
    errors.discord_user_id = 'A Discord user ID is 17–20 digits.';
  if (f.discord_channel_link) {
    const p = parseChannelLink(f.discord_channel_link);
    if (!p)
      errors.discord_channel_link =
        'Use a link like https://discord.com/channels/<server>/<channel>.';
    else if (guild && p.serverId !== guild)
      errors.discord_channel_link = 'This channel is in a different Discord server.';
  }
  extras.forEach((e, idx) => {
    if (!isEmail(e)) errors[`extra${idx}`] = 'Enter a valid email address.';
  });
  const emails = [f.primary_email, ...extras].map((e) => e.trim().toLowerCase()).filter(Boolean);
  const dup = all.find(
    (o) =>
      o.id !== instructor?.id &&
      (o.instructor_email.some((e) => emails.includes(e.email.toLowerCase())) ||
        emails.includes(o.primary_email.toLowerCase()) ||
        (!!f.discord_user_id && o.discord_user_id === f.discord_user_id.trim())),
  );
  const v = useFormErrors(errors);
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
      for (const e of current.filter((c) => !wanted.includes(c.email))) {
        check(await supabase.from('instructor_email').delete().eq('id', e.id));
      }
      for (const e of wanted.filter((w) => !current.some((c) => c.email === w))) {
        check(await supabase.from('instructor_email').insert({ instructor_id: id!, email: e }));
      }
      toast.success(
        contactChanged
          ? 'Saved. Contact details changed — send a new test message to re-verify.'
          : 'Saved',
      );
      await refresh();
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
    toast.success(`${instructor.full_name} is now ${status.toLowerCase()}`);
    setDeact(null);
    await refresh();
  }

  return (
    <Drawer
      open
      onOpenChange={(o) => !o && onClose()}
      title={instructor ? instructor.full_name : 'Add instructor'}
    >
      <div className="space-y-3">
        {instructor && (
          <div className="flex flex-wrap gap-2 rounded-md bg-slate-50 p-3">
            {instructor.verified_at ? (
              <Badge tone="blue">✓ Verified {fmtPT(instructor.verified_at)}</Badge>
            ) : (
              <Badge tone="amber">Not verified — not asked in Live domains</Badge>
            )}
            <Button
              size="sm"
              variant="outline"
              onClick={() =>
                act(
                  () => rpc('send_test_message', { p_instructor_id: instructor.id }),
                  'Test message queued (Discord + email)',
                )
              }
            >
              <Send className="h-3.5 w-3.5" /> Send test message
            </Button>
            {!instructor.verified_at && (
              <Button
                size="sm"
                variant="ghost"
                onClick={() =>
                  act(
                    () => rpc('mark_verified_manually', { p_instructor_id: instructor.id }),
                    'Marked as verified',
                  )
                }
              >
                Seen manually
              </Button>
            )}
          </div>
        )}
        <Field label="Full name" error={v.show('full_name')}>
          <Input
            value={f.full_name}
            onBlur={v.touch('full_name')}
            onChange={(e) => setF({ ...f, full_name: e.target.value })}
          />
        </Field>
        <Field label="Primary email" error={v.show('primary_email')}>
          <Input
            value={f.primary_email}
            onBlur={v.touch('primary_email')}
            onChange={(e) => setF({ ...f, primary_email: e.target.value })}
          />
        </Field>
        <div className="space-y-2">
          <span className="text-sm font-medium text-slate-700">Extra emails (same person)</span>
          {extras.map((e, idx) => (
            <div key={idx} className="flex gap-2">
              <Input
                value={e}
                onBlur={v.touch(`extra${idx}`)}
                aria-invalid={!!v.show(`extra${idx}`)}
                onChange={(ev) =>
                  setExtras(extras.map((x, j) => (j === idx ? ev.target.value : x)))
                }
              />
              <Button
                variant="ghost"
                aria-label="Remove email"
                onClick={() => setExtras(extras.filter((_, j) => j !== idx))}
              >
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          ))}
          <Button size="sm" variant="outline" onClick={() => setExtras([...extras, ''])}>
            Add email
          </Button>
        </div>
        <Field
          label="Discord user ID"
          hint="Right-click the person in Discord → Copy User ID (17–20 digits)."
          error={v.show('discord_user_id')}
        >
          <Input
            value={f.discord_user_id}
            onBlur={v.touch('discord_user_id')}
            onChange={(e) => setF({ ...f, discord_user_id: e.target.value })}
          />
        </Field>
        <Field
          label="Discord channel link"
          hint={
            channel
              ? `Server ${channel.serverId} · channel ${channel.channelId}`
              : 'Right-click their channel → Copy Link.'
          }
          error={v.show('discord_channel_link')}
        >
          <Input
            value={f.discord_channel_link}
            onBlur={v.touch('discord_channel_link')}
            onChange={(e) => setF({ ...f, discord_channel_link: e.target.value })}
          />
        </Field>
        <Field label="Phone">
          <Input value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} />
        </Field>
        <Field label="Notes">
          <Textarea value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} />
        </Field>
        <Checkbox
          label="Test instructor (never booked in Live domains)"
          checked={f.is_test}
          onChange={(v) => setF({ ...f, is_test: v })}
        />
        {dup && (
          <p className="rounded bg-amber-50 p-2 text-sm text-amber-900">
            An instructor with this email or Discord ID already exists: {dup.full_name}
          </p>
        )}
        {contactChanged && (
          <p className="text-sm text-amber-800">
            Changing email or Discord details removes the Verified badge.
          </p>
        )}
        <ErrorText error={err} />
        <div className="flex gap-2">
          <Button onClick={save} loading={saving} disabled={!!dup}>
            Save
          </Button>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
        </div>

        {instructor && (
          <>
            <div className="border-t pt-4">
              <h3 className="mb-2 font-medium">Upcoming bookings (all domains)</h3>
              {upcoming.length ? (
                <ul className="list-disc pl-5 text-sm">
                  {upcoming.map((u) => (
                    <li key={u}>{u}</li>
                  ))}
                </ul>
              ) : (
                <p className="text-sm text-slate-500">None.</p>
              )}
            </div>
            <Unavailability instructor={instructor} />
            <div className="flex flex-wrap gap-2 border-t pt-4">
              {instructor.status === 'Active' ? (
                <Button
                  variant="outline"
                  onClick={async () => {
                    if (
                      await confirm({
                        title: `Deactivate ${instructor.full_name}?`,
                        body: 'They will not be asked again. Any open request is withdrawn politely and the next instructor is asked.',
                        danger: true,
                      })
                    )
                      await act(() => deactivate('Inactive'), 'Done');
                  }}
                >
                  Deactivate
                </Button>
              ) : (
                <Button
                  variant="outline"
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
                      'Reactivated',
                    )
                  }
                >
                  Reactivate
                </Button>
              )}
              {instructor.status !== 'Archived' && (
                <Button
                  variant="ghost"
                  onClick={async () => {
                    if (
                      await confirm({
                        title: `Archive ${instructor.full_name}?`,
                        body: 'Instructors with history are archived, never deleted.',
                        danger: true,
                      })
                    )
                      await act(() => deactivate('Archived'), 'Archived');
                  }}
                >
                  Archive
                </Button>
              )}
            </div>
          </>
        )}
      </div>
      <Modal
        open={!!deact}
        onOpenChange={(o) => !o && setDeact(null)}
        title={`Keep these ${deact?.length ?? 0} classes, or release them and find backups?`}
      >
        <div className="space-y-2">
          {deact?.map((b) => (
            <div key={b.booking_id} className="flex items-center justify-between gap-2 text-sm">
              <span>{b.label}</span>
              <Select
                className="w-48"
                value={decisions[b.booking_id]}
                onChange={(e) =>
                  setDecisions({
                    ...decisions,
                    [b.booking_id]: e.target.value as 'keep' | 'release',
                  })
                }
              >
                <option value="keep">Keep booking</option>
                <option value="release">Release & find backup</option>
              </Select>
            </div>
          ))}
          <div className="flex justify-end gap-2 pt-2">
            <Button variant="outline" onClick={() => setDeact(null)}>
              Cancel
            </Button>
            <Button onClick={() => act(() => deactivate('Inactive', decisions), 'Done')}>
              Deactivate
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
  return (
    <div className="border-t pt-4">
      <h3 className="mb-2 font-medium">Unavailable dates</h3>
      <ul className="mb-2 space-y-1 text-sm">
        {instructor.instructor_unavailability.map((u) => (
          <li key={u.id} className="flex items-center justify-between">
            <span>
              {u.from_date} → {u.to_date}{' '}
              {u.reason && <span className="text-slate-500">({u.reason})</span>}
            </span>
            <Button
              size="sm"
              variant="ghost"
              onClick={async () => {
                check(await supabase.from('instructor_unavailability').delete().eq('id', u.id));
                await qc.invalidateQueries();
              }}
            >
              Remove
            </Button>
          </li>
        ))}
        {instructor.instructor_unavailability.length === 0 && (
          <li className="text-slate-500">None.</li>
        )}
      </ul>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="From">
          <Input
            type="date"
            value={r.from}
            onChange={(e) => setR({ ...r, from: e.target.value })}
          />
        </Field>
        <Field label="To">
          <Input type="date" value={r.to} onChange={(e) => setR({ ...r, to: e.target.value })} />
        </Field>
        <Field label="Reason">
          <Input value={r.reason} onChange={(e) => setR({ ...r, reason: e.target.value })} />
        </Field>
        <Button
          variant="outline"
          disabled={!r.from || !r.to}
          onClick={async () => {
            setErr(null);
            try {
              if (r.to < r.from) throw new Error('"To" must be on or after "From".');
              check(
                await supabase.from('instructor_unavailability').insert({
                  instructor_id: instructor.id,
                  from_date: r.from,
                  to_date: r.to,
                  reason: r.reason || null,
                }),
              );
              setR({ from: '', to: '', reason: '' });
              await qc.invalidateQueries();
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Add
        </Button>
      </div>
      <ErrorText error={err} />
    </div>
  );
}

export type { Instructor };
