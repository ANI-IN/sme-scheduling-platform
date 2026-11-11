import { useMemo, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { MailCheck, Plus, Send, Trash2, UserRound } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { instructorStatusLabel } from '@/lib/labels';
import { useDomains, useInstructors, type Instructor } from '@/lib/data';
import { ago, fmtLocal } from '@/lib/time';
import { fmtAt } from '@/lib/region';
import { isEmail } from '@/lib/validation';
import { cleanUsername, usernameProblem } from '@/lib/discord';
import { ChannelPicker, DiscordStatus } from '@/components/Discord';
import { useFormErrors } from '@/lib/useFormErrors';
import { useConfirm } from '@/components/Confirm';
import { DeleteButton } from '@/components/Lifecycle';
import { useAuth } from '@/lib/auth';
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
          .select(
            'instructor_id, module_week(first_class_at, cohort(region), module(name, domain(name)))',
          )
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
        const label = `${w.module?.name} (${w.module?.domain?.name}), ${fmtAt(w.first_class_at, w.cohort?.region)}`;
        upcoming.set(x.instructor_id, [...(upcoming.get(x.instructor_id) ?? []), label]);
      }
      const ranked = new Map<string, string[]>();
      const domains = new Map<string, Set<string>>();
      for (const x of rankings) {
        if (!x.module || x.module.status === 'Archived') continue;
        const place = x.rank === 1 ? 'Primary' : `Backup ${x.rank - 1}`;
        const label = `${x.module.name} (${x.module.domain?.name}): ${place}`;
        ranked.set(x.instructor_id, [...(ranked.get(x.instructor_id) ?? []), label]);
        if (x.module.domain?.name)
          domains.set(
            x.instructor_id,
            new Set([...(domains.get(x.instructor_id) ?? []), x.module.domain.name]),
          );
      }
      return { upcoming, ranked, domains };
    },
  });
}

const STATUS_FILTERS: { value: string; label: string; test: (i: InstructorRow) => boolean }[] = [
  { value: 'active', label: 'In use', test: (i) => i.status === 'Active' },
  { value: 'inactive', label: 'Not in use', test: (i) => i.status === 'Inactive' },
  { value: 'archived', label: 'Archived', test: (i) => i.status === 'Archived' },
  { value: 'all', label: 'Everyone', test: () => true },
];
const isUnchecked = (i: InstructorRow) => i.status === 'Active' && !i.verified_at && !i.is_test;
const isFailing = (i: InstructorRow) => !!i.email_bounced_at || !!i.discord_failed_at;

export default function Instructors() {
  const { data, isLoading, error } = useInstructors();
  const ctx = useInstructorContext();
  const [params, setParams] = useSearchParams();
  const show = params.get('show') ?? '';
  const status = params.get('status') ?? 'active';
  const teachesIn = params.get('domain') ?? '';
  // Outside Production the test instructors are the ones people practise with, so show them unless hidden.
  const practice = useAuth().account?.environment !== 'Production';
  const testParam = params.get('test');
  const showTest = testParam === '1' || show === 'test' || (practice && testParam !== '0');
  const set = (k: string, v: string) => {
    const n = new URLSearchParams(params);
    if (v) n.set(k, v);
    else n.delete(k);
    setParams(n, { replace: true });
  };
  const domains = useDomains();
  const [q, setQ] = useState('');
  const [editing, setEditing] = useState<InstructorRow | 'new' | null>(null);
  const statusTest =
    STATUS_FILTERS.find((f) => f.value === status)?.test ?? STATUS_FILTERS[0]!.test;
  const test = (i: InstructorRow) =>
    statusTest(i) &&
    (showTest || !i.is_test) &&
    (show !== 'unchecked' || isUnchecked(i)) &&
    (show !== 'problems' || isFailing(i)) &&
    (!teachesIn ||
      (teachesIn === 'none'
        ? !(ctx.data?.ranked.get(i.id) ?? []).length
        : !!ctx.data?.domains.get(i.id)?.has(teachesIn)));

  const rows = useMemo(
    () =>
      (data ?? []).filter(
        (i) =>
          test(i) &&
          `${i.full_name} ${i.primary_email} ${i.instructor_email.map((e) => e.email).join(' ')}`
            .toLowerCase()
            .includes(q.toLowerCase()),
      ),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [data, q, status, show, teachesIn, showTest, ctx.data],
  );
  const unchecked = (data ?? []).filter(isUnchecked).length;

  return (
    <div>
      <PageHeader title="Instructors" description="Each real person once, shared by every domain.">
        <Button onClick={() => setEditing('new')}>
          <Plus className="h-4 w-4" aria-hidden /> Add instructor
        </Button>
      </PageHeader>
      {unchecked > 0 && show !== 'unchecked' && (
        <div className="mb-4">
          <Notice tone="warning">
            {unchecked} instructor{unchecked === 1 ? ' has' : 's have'} not had their contact
            details checked. They are not asked once a domain is live.{' '}
            <button
              className="font-medium underline underline-offset-2"
              onClick={() => set('show', 'unchecked')}
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
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          Status
          <Select
            value={status}
            onChange={(e) => set('status', e.target.value === 'active' ? '' : e.target.value)}
            className="w-36"
          >
            {STATUS_FILTERS.map((f) => (
              <option key={f.value} value={f.value}>
                {f.label}
              </option>
            ))}
          </Select>
        </label>
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          Teaches in
          <Select
            value={teachesIn}
            onChange={(e) => set('domain', e.target.value)}
            className="w-48"
          >
            <option value="">Any domain</option>
            {(domains.data ?? []).map((d) => (
              <option key={d.id} value={d.name}>
                {d.name}
              </option>
            ))}
            <option value="none">Not assigned to any module</option>
          </Select>
        </label>
        <Select
          aria-label="Only show"
          value={show === 'test' ? '' : show}
          onChange={(e) => set('show', e.target.value)}
          className="w-60"
        >
          <option value="">Everyone in this list</option>
          <option value="unchecked">Contact details not checked</option>
          <option value="problems">Messages failing</option>
        </Select>
        <Checkbox
          label="Show test instructors"
          checked={showTest}
          onChange={(v) => set('test', v ? (practice ? '' : '1') : practice ? '0' : '')}
        />
        <span className="text-sm text-muted-foreground">{rows.length} shown</span>
      </Toolbar>
      <ErrorText error={error} />
      {isLoading ? (
        <SkeletonRows />
      ) : rows.length === 0 ? (
        <Empty
          title={
            q || show || teachesIn || status !== 'active'
              ? 'No instructors match'
              : 'No instructors yet'
          }
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
                <th className={`${th} hidden lg:table-cell`}>Modules</th>
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
                      {/* A real button, so the instructor can also be opened with the keyboard. */}
                      <button
                        type="button"
                        className="text-left font-medium text-link hover:underline"
                        onClick={(e) => {
                          e.stopPropagation();
                          setEditing(i);
                        }}
                      >
                        {i.full_name}
                      </button>
                      <div className="text-xs text-muted-foreground">{i.primary_email}</div>
                    </td>
                    <td className={td}>
                      <StatusBadges i={i} />
                    </td>
                    <td className={`${td} hidden lg:table-cell`}>
                      {ranked.length ? (
                        <span
                          title={ranked.join('\n')}
                          className="cursor-help underline decoration-dotted underline-offset-2"
                        >
                          {ranked.length} module{ranked.length === 1 ? '' : 's'}
                        </span>
                      ) : (
                        <span className="text-muted-foreground">Not assigned to any module</span>
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
      {i.status !== 'Active' && <Badge>{instructorStatusLabel(i.status)}</Badge>}
      {i.verified_at ? (
        <Badge tone="success">Contact checked</Badge>
      ) : (
        <Badge tone="warning">Not checked yet</Badge>
      )}
      {i.is_test && <Badge tone="accent">Test instructor</Badge>}
      {i.email_bounced_at && <Badge tone="danger">Email bounced</Badge>}
      {i.discord_failed_at && <Badge tone="danger">Discord message failed</Badge>}
      {i.discord_status !== 'Found' && (
        <DiscordStatus status={i.discord_status} problem={i.discord_problem} compact />
      )}
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
  const domains = useDomains();
  const [f, setF] = useState({
    full_name: instructor?.full_name ?? '',
    primary_email: instructor?.primary_email ?? '',
    discord_username: instructor?.discord_username ?? '',
    phone: instructor?.phone ?? '',
    notes: instructor?.notes ?? '',
    is_test: instructor?.is_test ?? false,
    monthly_class_limit: instructor?.monthly_class_limit
      ? String(instructor.monthly_class_limit)
      : '',
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
  const uProblem = usernameProblem(f.discord_username);
  if (uProblem) errors.discord_username = uProblem;
  extras.forEach((e, idx) => {
    if (!isEmail(e)) errors[`extra${idx}`] = 'Enter a valid email address.';
  });
  if (
    f.monthly_class_limit &&
    !(
      Number.isInteger(Number(f.monthly_class_limit)) &&
      Number(f.monthly_class_limit) >= 1 &&
      Number(f.monthly_class_limit) <= 100
    )
  )
    errors.monthly_class_limit = 'Enter a number from 1 to 100, or leave it empty.';
  const v = useFormErrors(errors);
  const emails = [f.primary_email, ...extras].map((e) => e.trim().toLowerCase()).filter(Boolean);
  const dup = all.find(
    (o) =>
      o.id !== instructor?.id &&
      (o.instructor_email.some((e) => emails.includes(e.email.toLowerCase())) ||
        emails.includes(o.primary_email.toLowerCase()) ||
        (!!cleanUsername(f.discord_username) &&
          o.discord_username === cleanUsername(f.discord_username) &&
          !(f.is_test && o.is_test))),
  );
  const contactChanged =
    !!instructor &&
    (instructor.primary_email !== f.primary_email.trim().toLowerCase() ||
      (instructor.discord_username ?? '') !== cleanUsername(f.discord_username));
  const refresh = () => qc.invalidateQueries();

  async function save(another = false) {
    setErr(null);
    if (!v.submit() || dup) return;
    setSaving(true);
    try {
      const row = {
        full_name: f.full_name.trim(),
        primary_email: f.primary_email.trim().toLowerCase(),
        discord_username: cleanUsername(f.discord_username) || null,
        phone: f.phone.trim() || null,
        notes: f.notes.trim() || null,
        is_test: f.is_test,
        monthly_class_limit: f.monthly_class_limit ? Number(f.monthly_class_limit) : null,
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
      if (another) {
        // Save and add another: an empty form for the next person (decision 259).
        setF({
          full_name: '',
          primary_email: '',
          discord_username: '',
          phone: '',
          notes: '',
          is_test: f.is_test,
          monthly_class_limit: '',
        });
        setExtras([]);
        v.reset();
        return;
      }
      onSaved?.(id!);
      onClose();
    } catch (e) {
      setErr(e);
      toast.error(instructor ? 'The changes were not saved' : 'The instructor was not added');
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
      `${instructor.full_name} is now ${status === 'Inactive' ? 'not in use' : 'archived'}`,
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
          {!instructor && (
            <Button
              variant="secondary"
              onClick={() => void save(true)}
              loading={saving}
              disabled={!!dup}
            >
              Save and add another
            </Button>
          )}
          <Button variant="secondary" onClick={onClose}>
            Cancel
          </Button>
          {/* UI-9: the reason a save failed shows next to the Save button. */}
          <div className="basis-full">
            <ErrorText error={err} />
          </div>
        </div>
      }
    >
      <div className="space-y-5">
        {dup && (
          <Notice tone="warning">
            An instructor with this email or Discord username already exists: {dup.full_name}. Edit
            that record instead.
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
          <Field
            label="Classes a month (optional)"
            hint="Their preferred most. We warn before asking them for more, but you can still ask."
            error={v.show('monthly_class_limit')}
          >
            <Input
              type="number"
              min={1}
              max={100}
              value={f.monthly_class_limit}
              onBlur={v.touch('monthly_class_limit')}
              onChange={(e) => setF({ ...f, monthly_class_limit: e.target.value })}
              className="w-28"
            />
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
          description="Requests and reminders go to their channel in each domain, tagging them, and also by email. Without a channel they get a direct message."
        >
          <Field
            label="Discord username"
            hint="For example maya.k, without @. The app finds their Discord account by itself."
            error={v.show('discord_username')}
          >
            <Input
              value={f.discord_username}
              onBlur={v.touch('discord_username')}
              onChange={(e) => setF({ ...f, discord_username: e.target.value })}
              autoComplete="off"
            />
          </Field>
          {instructor && (
            <div className="flex flex-wrap items-center gap-2">
              <DiscordStatus
                status={instructor.discord_status}
                problem={instructor.discord_problem}
              />
              {instructor.discord_username && (
                <Button
                  size="sm"
                  variant="outline"
                  disabled={instructor.discord_status === 'Checking'}
                  onClick={() =>
                    act(
                      () => rpc('check_discord', { p_kind: 'instructor', p_id: instructor.id }),
                      'Checking Discord. This takes up to a minute.',
                    )
                  }
                >
                  Check Discord
                </Button>
              )}
            </div>
          )}
          {instructor ? (
            <div className="space-y-2">
              <p className="text-sm font-medium">Their channel in each domain</p>
              {(domains.data ?? []).map((d) => (
                <div key={d.id} className="space-y-1">
                  <div className="text-xs text-muted-foreground">{d.name}</div>
                  <ChannelPicker
                    serverId={d.discord_server_id}
                    label={`Channel of ${instructor.full_name} in ${d.name}`}
                    value={
                      instructor.instructor_channel.find((c) => c.domain_id === d.id)?.channel_id ??
                      null
                    }
                    storedName={
                      instructor.instructor_channel.find((c) => c.domain_id === d.id)?.channel_name
                    }
                    onChange={(id) =>
                      act(
                        () =>
                          rpc('set_instructor_channel', {
                            p_instructor_id: instructor.id,
                            p_domain_id: d.id,
                            p_channel_id: id as string,
                          }),
                        id ? 'Channel saved' : 'Channel removed: they get direct messages instead',
                      )
                    }
                  />
                </div>
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">
              After you add the instructor, choose their channel in each domain here.
            </p>
          )}
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
                  ? 'Instructors who are not in use are never asked. If they are being asked now, the request is withdrawn politely and the next instructor is asked.'
                  : `This instructor is ${instructor.status === 'Inactive' ? 'not in use' : instructor.status.toLowerCase()}.`}
              </div>
              {instructor.status === 'Active' ? (
                <Button
                  variant="destructive"
                  size="sm"
                  onClick={async () => {
                    if (
                      await confirm({
                        title: `Stop using ${instructor.full_name}?`,
                        body: 'They will not be asked again. If they have confirmed classes, you will choose whether to keep each one.',
                        danger: true,
                        confirmLabel: 'Stop using',
                      })
                    )
                      await act(() => deactivate('Inactive'), 'Done');
                  }}
                >
                  Stop using
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
                      'In use again',
                    )
                  }
                >
                  Start using again
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
                        body: 'They are no longer asked and no longer appear in lists. You can start using them again at any time.',
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
              <DeleteButton kind="instructor" id={instructor.id} onDeleted={onClose} />
            </div>
          </Group>
        )}
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
              Stop using
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
