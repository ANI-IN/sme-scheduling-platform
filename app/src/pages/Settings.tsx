import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import {
  useSettings,
  useSystem,
  useTeam,
  useWeeks,
  type SettingRow,
  type TeamMember,
} from '@/lib/data';
import { fmtLocal, fmtPT, PT } from '@/lib/time';
import { isDiscordId, isEmail } from '@/lib/validation';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Card,
  Checkbox,
  ErrorText,
  Field,
  Input,
  PageHeader,
  Select,
  Spinner,
  td,
  th,
} from '@/components/ui';

export default function Settings() {
  const { domain } = useDomain();
  return (
    <div className="space-y-6">
      <PageHeader title="Settings" />
      {domain && <TestMode key={`${domain.id}:${domain.version}`} />}
      {domain && <DomainSettings />}
      <TeamList />
      <Holidays />
      <SystemPanel />
    </div>
  );
}

function Section({
  title,
  children,
  hint,
}: {
  title: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <Card className="p-4">
      <h2 className="font-semibold">{title}</h2>
      {hint && <p className="mb-3 text-sm text-muted-foreground">{hint}</p>}
      <div className={hint ? '' : 'mt-3'}>{children}</div>
    </Card>
  );
}

// ------------------------------------------------------------------ domain settings (PRD §16)
function DomainSettings() {
  const { domain } = useDomain();
  const { data, isLoading } = useSettings(domain?.id);
  const groups = [...new Set((data ?? []).map((s) => s.group))];
  return (
    <Section
      title={`Domain settings — ${domain?.name}`}
      hint="Changes apply to everything not yet sent. Nothing already sent is repeated or recalled."
    >
      {isLoading ? (
        <Spinner />
      ) : (
        <div className="space-y-5">
          {groups.map((g) => (
            <div key={g}>
              <h3 className="mb-2 text-sm font-semibold text-muted-foreground">{g}</h3>
              <div className="grid gap-3 md:grid-cols-2">
                {data!
                  .filter((s) => s.group === g)
                  .map((s) => (
                    <SettingEditor
                      key={`${s.key}:${JSON.stringify(s.value)}`}
                      s={s}
                      domainId={domain!.id}
                    />
                  ))}
              </div>
            </div>
          ))}
        </div>
      )}
    </Section>
  );
}

function toText(s: SettingRow, v: unknown): string {
  if (s.type === 'int_list') return (v as number[]).join(', ');
  if (s.type === 'text_list') return (v as string[]).join('\n');
  if (s.type === 'json') return JSON.stringify(v);
  return String(v);
}

function SettingEditor({ s, domainId }: { s: SettingRow; domainId: string }) {
  const qc = useQueryClient();
  const [text, setText] = useState(toText(s, s.value));
  const [err, setErr] = useState<string | null>(null);

  const parse = (): unknown => {
    switch (s.type) {
      case 'int':
        return Number(text);
      case 'bool':
        return text === 'true';
      case 'int_list':
        return text
          .split(',')
          .map((x) => Number(x.trim()))
          .filter((x) => !Number.isNaN(x));
      case 'text_list':
        return text
          .split('\n')
          .map((x) => x.trim())
          .filter(Boolean);
      case 'json':
        return JSON.parse(text);
      default:
        return text;
    }
  };

  const save = async (value?: unknown) => {
    setErr(null);
    try {
      await rpc('set_setting', {
        p_domain_id: domainId,
        p_key: s.key,
        p_value: (value ?? parse()) as never,
      });
      toast.success(`Saved: ${s.label}`);
      await qc.invalidateQueries({ queryKey: ['setting'] });
    } catch (e) {
      setErr((e as Error).message);
    }
  };

  const range = s.min !== null && s.max !== null ? `Allowed ${s.min}–${s.max}.` : '';
  const hint = [s.help, range, `Default: ${toText(s, s.default)}`].filter(Boolean).join(' ');

  if (s.key === 'help_routing') {
    const v = (s.value ?? {}) as Record<string, string>;
    return (
      <Field
        label={s.label}
        hint="Who gets each help category: module owner(s), domain ops contacts, or both."
      >
        <div className="grid grid-cols-2 gap-1">
          {Object.entries(v).map(([cat, who]) => (
            <label key={cat} className="flex items-center justify-between gap-2 text-sm">
              <span className="capitalize">{cat}</span>
              <Select
                className="h-8 w-28"
                value={who}
                onChange={(e) => void save({ ...v, [cat]: e.target.value })}
              >
                {['Owner', 'Ops', 'Both'].map((o) => (
                  <option key={o}>{o}</option>
                ))}
              </Select>
            </label>
          ))}
        </div>
        {err && <span className="text-xs text-danger-strong">{err}</span>}
      </Field>
    );
  }

  return (
    <Field label={s.label} hint={hint} error={err ?? undefined}>
      <div className="flex gap-2">
        {s.type === 'enum' || s.type === 'bool' ? (
          <Select
            value={text}
            onChange={(e) => (
              setText(e.target.value),
              void save(s.type === 'bool' ? e.target.value === 'true' : e.target.value)
            )}
          >
            {(s.type === 'bool' ? ['true', 'false'] : (s.allowed ?? [])).map((o) => (
              <option key={o} value={o}>
                {o === 'true' ? 'On' : o === 'false' ? 'Off' : o}
              </option>
            ))}
          </Select>
        ) : s.type === 'text_list' ? (
          <textarea
            className="min-h-16 w-full rounded-md border border-border px-2 py-1 text-sm"
            value={text}
            onChange={(e) => setText(e.target.value)}
          />
        ) : (
          <Input
            type={s.type === 'int' ? 'number' : s.type === 'time' ? 'time' : 'text'}
            value={text}
            onChange={(e) => setText(e.target.value)}
          />
        )}
        {s.type !== 'enum' && s.type !== 'bool' && (
          <Button variant="outline" onClick={() => void save()}>
            Save
          </Button>
        )}
        {s.overridden && (
          <Button
            variant="ghost"
            title="Reset to default"
            onClick={async () => {
              await rpc('reset_setting', { p_domain_id: domainId, p_key: s.key });
              await qc.invalidateQueries({ queryKey: ['setting'] });
            }}
          >
            Reset
          </Button>
        )}
      </div>
    </Field>
  );
}

// ------------------------------------------------------------------ test mode + test clock (TST-1..3)
function TestMode() {
  const { domain } = useDomain();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const weeks = useWeeks(domain?.id);
  const settings = useSettings(domain?.id);
  const [chan, setChan] = useState(domain?.test_discord_channel_id ?? '');
  const [mail, setMail] = useState(domain?.test_email ?? '');
  const [clock, setClock] = useState('');
  const [mw, setMw] = useState('');
  const [err, setErr] = useState<unknown>(null);
  const [last, setLast] = useState<unknown>(null);
  if (!domain) return null;
  const isTest = domain.status === 'Test';
  const val = (k: string) => Number(settings.data?.find((s) => s.key === k)?.value ?? 0);
  const points = [
    { label: 'Readiness', days: val('readiness_days') },
    { label: `${val('outreach_days')} days (outreach)`, days: val('outreach_days') },
    { label: '14 days', days: val('owner_checkin_days') },
    { label: '10 days', days: 10 },
    { label: '2 days', days: 2 },
  ];

  async function run(fn: () => Promise<unknown>, ok?: string) {
    setErr(null);
    try {
      const r = await fn();
      setLast(r);
      await poke();
      if (ok) toast.success(ok);
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
    }
  }

  return (
    <Section
      title="Test mode"
      hint="In test mode every message goes to the test Discord channel and test email, prefixed “[TEST → would go to <name>]”."
    >
      <div className="flex flex-wrap items-end gap-3">
        <Field
          label="Test Discord channel ID"
          error={chan && !isDiscordId(chan) ? '17–20 digits' : undefined}
        >
          <Input value={chan} onChange={(e) => setChan(e.target.value)} className="w-56" />
        </Field>
        <Field label="Test email" error={mail && !isEmail(mail) ? 'Invalid email' : undefined}>
          <Input value={mail} onChange={(e) => setMail(e.target.value)} className="w-56" />
        </Field>
        <Button
          variant="outline"
          onClick={() =>
            run(
              () =>
                rpc('set_test_targets', {
                  p_domain_id: domain.id,
                  p_test_discord_channel_id: chan,
                  p_test_email: mail,
                }),
              'Saved',
            )
          }
        >
          Save
        </Button>
        <div className="ml-auto flex items-center gap-2">
          <Badge tone={isTest ? 'amber' : 'gray'}>
            {isTest ? 'Test mode ON' : `Status: ${domain.status}`}
          </Badge>
          {isTest ? (
            <Button
              variant="danger"
              onClick={async () => {
                if (
                  await confirm({
                    title: 'Turn test mode off?',
                    body: `${domain.name} goes Live: real instructors will be contacted from the next hourly check.`,
                    danger: true,
                    confirmLabel: 'Go Live',
                  })
                )
                  await run(
                    () => rpc('set_domain_status', { p_domain_id: domain.id, p_status: 'Live' }),
                    `${domain.name} is Live`,
                  );
              }}
            >
              Turn test mode off (go Live)
            </Button>
          ) : (
            <Button
              onClick={() =>
                run(
                  () => rpc('set_domain_status', { p_domain_id: domain.id, p_status: 'Test' }),
                  'Test mode on',
                )
              }
            >
              Turn test mode on
            </Button>
          )}
        </div>
      </div>
      {isTest && (
        <div className="mt-4 space-y-3 border-t pt-4">
          <p className="text-sm">
            Test clock:{' '}
            <strong>
              {domain.test_clock_at
                ? `${fmtPT(domain.test_clock_at)} (${fmtLocal(domain.test_clock_at)})`
                : 'real time'}
            </strong>
          </p>
          <div className="flex flex-wrap items-end gap-2">
            <Field label="Set clock (PT)">
              <Input
                type="datetime-local"
                value={clock}
                onChange={(e) => setClock(e.target.value)}
              />
            </Field>
            <Button
              variant="outline"
              disabled={!clock}
              onClick={() =>
                run(
                  () =>
                    rpc('set_test_clock', {
                      p_domain_id: domain.id,
                      p_at: DateTime.fromISO(clock, { zone: PT }).toUTC().toISO()!,
                    }),
                  'Clock set',
                )
              }
            >
              Set
            </Button>
            <Button
              variant="outline"
              onClick={() =>
                run(
                  () => rpc('advance_test_clock', { p_domain_id: domain.id, p_hours: 1 }),
                  'Advanced 1 hour',
                )
              }
            >
              Advance 1 hour
            </Button>
            <Button
              variant="outline"
              onClick={() =>
                run(
                  () => rpc('advance_test_clock', { p_domain_id: domain.id, p_hours: 24 }),
                  'Advanced 1 day',
                )
              }
            >
              Advance 1 day
            </Button>
            <Button
              variant="ghost"
              onClick={() =>
                run(
                  () => rpc('set_test_clock', { p_domain_id: domain.id, p_at: null as never }),
                  'Real time',
                )
              }
            >
              Use real time
            </Button>
            <Button
              onClick={() =>
                run(() => rpc('run_check_now', { p_domain_id: domain.id }), 'Hourly check ran')
              }
            >
              Run check now
            </Button>
          </div>
          <div className="flex flex-wrap items-end gap-2">
            <Field label="Jump to a point before a module week">
              <Select value={mw} onChange={(e) => setMw(e.target.value)} className="w-80">
                <option value="">Choose a module week…</option>
                {(weeks.data ?? [])
                  .filter((w) => w.first_class_at && w.status !== 'Cancelled')
                  .map((w) => (
                    <option key={w.id} value={w.id}>
                      {w.module?.name} · {fmtPT(w.first_class_at)} {w.cohort && `(${w.cohort})`}
                    </option>
                  ))}
              </Select>
            </Field>
            {points.map((p) => (
              <Button
                key={p.label}
                variant="outline"
                size="sm"
                disabled={!mw}
                onClick={() =>
                  run(
                    () =>
                      rpc('jump_test_clock', {
                        p_domain_id: domain.id,
                        p_module_week_id: mw,
                        p_days_before: p.days,
                      }),
                    `Jumped to ${p.label} before`,
                  )
                }
              >
                {p.label}
              </Button>
            ))}
          </div>
          {last != null && (
            <pre className="max-h-40 overflow-auto rounded bg-muted p-2 text-xs">
              {JSON.stringify(last, null, 2)}
            </pre>
          )}
        </div>
      )}
      <ErrorText error={err} />
    </Section>
  );
}

// ------------------------------------------------------------------ team list
function TeamList() {
  const { data } = useTeam();
  const qc = useQueryClient();
  const [n, setN] = useState({ name: '', email: '', discord_user_id: '', label: 'Ops' });
  const [err, setErr] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, ok?: string) => {
    setErr(null);
    try {
      await fn();
      if (ok) toast.success(ok);
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
    }
  };
  const update = (t: TeamMember, patch: Partial<TeamMember>) =>
    run(async () =>
      check(
        await supabase
          .from('team_member')
          .update({ ...patch, version: t.version })
          .eq('id', t.id)
          .select(),
      ),
    );
  return (
    <Section
      title="Team"
      hint="Owners, ops contacts and leads are chosen from this list. Placeholders from the seed are marked — replace them."
    >
      <div className="overflow-x-auto">
        <table className="w-full">
          <thead>
            <tr className="border-b">
              <th className={th}>Name</th>
              <th className={th}>Email</th>
              <th className={th}>Discord ID</th>
              <th className={th}>Label</th>
              <th className={th}>Digest</th>
              <th className={th}>Active</th>
              <th className={th}></th>
            </tr>
          </thead>
          <tbody>
            {(data ?? []).map((t) => (
              <TeamRow key={t.id} t={t} update={update} run={run} />
            ))}
          </tbody>
        </table>
      </div>
      <div className="mt-3 flex flex-wrap items-end gap-2">
        <Input
          placeholder="Name"
          value={n.name}
          onChange={(e) => setN({ ...n, name: e.target.value })}
          className="w-40"
        />
        <Input
          placeholder="Email"
          value={n.email}
          onChange={(e) => setN({ ...n, email: e.target.value })}
          className="w-56"
        />
        <Input
          placeholder="Discord user ID"
          value={n.discord_user_id}
          onChange={(e) => setN({ ...n, discord_user_id: e.target.value })}
          className="w-48"
        />
        <Select
          value={n.label}
          onChange={(e) => setN({ ...n, label: e.target.value })}
          className="w-24"
        >
          {['Ops', 'PM', 'Lead'].map((l) => (
            <option key={l}>{l}</option>
          ))}
        </Select>
        <Button
          variant="outline"
          disabled={
            !n.name.trim() ||
            !isEmail(n.email) ||
            (!!n.discord_user_id && !isDiscordId(n.discord_user_id))
          }
          onClick={() =>
            run(async () => {
              check(
                await supabase
                  .from('team_member')
                  .insert({ ...n, discord_user_id: n.discord_user_id || null }),
              );
              setN({ name: '', email: '', discord_user_id: '', label: 'Ops' });
            }, 'Team member added')
          }
        >
          Add
        </Button>
      </div>
      <ErrorText error={err} />
    </Section>
  );
}

function TeamRow({
  t,
  update,
  run,
}: {
  t: TeamMember;
  update: (t: TeamMember, p: Partial<TeamMember>) => Promise<void>;
  run: (fn: () => Promise<unknown>, ok?: string) => Promise<void>;
}) {
  const [f, setF] = useState({
    name: t.name,
    email: t.email,
    discord_user_id: t.discord_user_id ?? '',
  });
  const dirty =
    f.name !== t.name || f.email !== t.email || f.discord_user_id !== (t.discord_user_id ?? '');
  return (
    <tr className="border-b last:border-0">
      <td className={td}>
        <Input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
        {t.is_placeholder && <Badge tone="amber">Placeholder — replace</Badge>}
      </td>
      <td className={td}>
        <Input value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
      </td>
      <td className={td}>
        <Input
          value={f.discord_user_id}
          onChange={(e) => setF({ ...f, discord_user_id: e.target.value })}
        />
      </td>
      <td className={td}>
        <Select value={t.label} onChange={(e) => void update(t, { label: e.target.value })}>
          {['Ops', 'PM', 'Lead'].map((l) => (
            <option key={l}>{l}</option>
          ))}
        </Select>
      </td>
      <td className={td}>
        <div className="flex items-center gap-2">
          <Checkbox
            label=""
            checked={t.receives_digest}
            onChange={(v) => void update(t, { receives_digest: v })}
          />
          <Select
            value={t.digest_channel}
            onChange={(e) => void update(t, { digest_channel: e.target.value })}
            className="w-28"
          >
            {['Discord', 'Email', 'Both'].map((l) => (
              <option key={l}>{l}</option>
            ))}
          </Select>
        </div>
      </td>
      <td className={td}>
        <Checkbox label="" checked={t.active} onChange={(v) => void update(t, { active: v })} />
      </td>
      <td className={`${td} whitespace-nowrap`}>
        {dirty && (
          <Button
            size="sm"
            disabled={!isEmail(f.email) || (!!f.discord_user_id && !isDiscordId(f.discord_user_id))}
            onClick={() =>
              void update(t, {
                name: f.name.trim(),
                email: f.email.trim(),
                discord_user_id: f.discord_user_id || null,
                is_placeholder: false,
              })
            }
          >
            Save
          </Button>
        )}
        <Button
          size="sm"
          variant="ghost"
          onClick={() =>
            run(async () => {
              await rpc('send_test_alert', { p_team_member_id: t.id });
              await poke();
            }, 'Test alert queued')
          }
        >
          Send test alert
        </Button>
      </td>
    </tr>
  );
}

// ------------------------------------------------------------------ holidays
function Holidays() {
  const qc = useQueryClient();
  const { data } = useQuery({
    queryKey: ['holiday'],
    queryFn: async () => check(await supabase.from('holiday').select('*').order('date')),
  });
  const [h, setH] = useState({ date: '', name: '' });
  const [err, setErr] = useState<unknown>(null);
  return (
    <Section title="Holidays" hint="Used by the class planner to highlight holiday weeks.">
      <ul className="mb-2 grid gap-1 text-sm sm:grid-cols-2">
        {(data ?? []).map((x) => (
          <li key={x.id} className="flex items-center justify-between rounded bg-muted px-2 py-1">
            <span>
              {DateTime.fromISO(x.date).toFormat('ccc LLL d, yyyy')} — {x.name}
            </span>
            <Button
              size="sm"
              variant="ghost"
              onClick={async () => {
                check(await supabase.from('holiday').delete().eq('id', x.id));
                await qc.invalidateQueries({ queryKey: ['holiday'] });
              }}
            >
              Remove
            </Button>
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap gap-2">
        <Input
          type="date"
          value={h.date}
          onChange={(e) => setH({ ...h, date: e.target.value })}
          className="w-44"
        />
        <Input
          placeholder="Name"
          value={h.name}
          onChange={(e) => setH({ ...h, name: e.target.value })}
          className="w-56"
        />
        <Button
          variant="outline"
          disabled={!h.date || !h.name.trim()}
          onClick={async () => {
            setErr(null);
            try {
              check(await supabase.from('holiday').insert({ date: h.date, name: h.name.trim() }));
              setH({ date: '', name: '' });
              await qc.invalidateQueries({ queryKey: ['holiday'] });
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Add holiday
        </Button>
      </div>
      <ErrorText error={err} />
    </Section>
  );
}

// ------------------------------------------------------------------ system (SYS-1, connections)
function SystemPanel() {
  const { data } = useSystem();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const conn = useQuery({
    queryKey: ['message', 'connection'],
    queryFn: async () =>
      (await rpc('connection_status', {})) as Record<string, string | number | null>,
  });
  const [err, setErr] = useState<unknown>(null);
  if (!data) return null;
  const on = data.state.outreach_enabled;
  return (
    <Section title="System">
      <div className="flex flex-wrap items-center gap-3">
        <Badge tone={on ? 'green' : 'red'}>
          {on ? 'Outreach running' : 'Kill switch ON — instructor messages paused'}
        </Badge>
        <Button
          variant={on ? 'danger' : 'primary'}
          onClick={async () => {
            if (
              await confirm({
                title: on ? 'Pause ALL outreach?' : 'Resume outreach?',
                body: on
                  ? 'No instructor will be messaged in any domain until you turn this back on. Team alerts continue.'
                  : 'Instructor messages resume at the next hourly check.',
                danger: on,
              })
            ) {
              try {
                await rpc('set_kill_switch', { p_outreach_enabled: !on });
                await poke();
                await qc.invalidateQueries();
              } catch (e) {
                setErr(e);
              }
            }
          }}
        >
          {on ? 'Pause all outreach (kill switch)' : 'Turn kill switch off'}
        </Button>
      </div>
      <div className="mt-3 grid gap-2 text-sm sm:grid-cols-2">
        <div>
          Company email domain: <strong>{data.config.company_email_domain || 'not set'}</strong>
        </div>
        <div>
          Last hourly run: <strong>{fmtLocal(data.state.last_hourly_run_at)}</strong> (
          {data.state.last_hourly_status ?? 'never'})
        </div>
        <div>Daily heartbeat: {fmtLocal(data.state.last_heartbeat_at)}</div>
        <div>
          Discord: last send {fmtLocal(conn.data?.discord_last_sent as string)} · failed 24h:{' '}
          {conn.data?.discord_failed_24h ?? 0}
        </div>
        <div>
          Gmail: last send {fmtLocal(conn.data?.email_last_sent as string)} · failed 24h:{' '}
          {conn.data?.email_failed_24h ?? 0}
        </div>
        <div>
          n8n: last action processed {fmtLocal(conn.data?.last_action_processed as string)} ·
          waiting to send: {conn.data?.pending ?? 0}
        </div>
      </div>
      <ConfigForm key={data.config.version} config={data.config} />
      <ErrorText error={err} />
    </Section>
  );
}

function ConfigForm({
  config,
}: {
  config: NonNullable<ReturnType<typeof useSystem>['data']>['config'];
}) {
  const qc = useQueryClient();
  const [err, setErr] = useState<unknown>(null);
  const [cfg, setCfg] = useState<Record<string, string>>({
    discord_guild_id: config.discord_guild_id ?? '',
    response_base_url: config.response_base_url ?? '',
    app_base_url: config.app_base_url ?? '',
    admin_discord_channel_id: config.admin_discord_channel_id ?? '',
    scheduling_email: config.scheduling_email ?? '',
  });
  const fields: [string, string, string][] = [
    [
      'discord_guild_id',
      'Company Discord server ID',
      'Instructor channel links must be in this server.',
    ],
    [
      'admin_discord_channel_id',
      'Admin alert channel ID',
      'Failures and the daily heartbeat go here.',
    ],
    [
      'response_base_url',
      'Response page URL (n8n WF2)',
      'e.g. https://your-n8n/webhook/respond — used in every instructor link.',
    ],
    ['app_base_url', 'App URL', 'Linked from team alerts.'],
    ['scheduling_email', 'Scheduling sender email', 'The Gmail account n8n sends from.'],
  ];
  return (
    <>
      <div className="mt-4 grid gap-3 border-t pt-4 md:grid-cols-2">
        {fields.map(([k, label, hint]) => (
          <Field key={k} label={label} hint={hint}>
            <Input value={cfg[k] ?? ''} onChange={(e) => setCfg({ ...cfg, [k]: e.target.value })} />
          </Field>
        ))}
      </div>
      <Button
        className="mt-3"
        variant="outline"
        onClick={async () => {
          setErr(null);
          try {
            await rpc('set_app_config', { p_config: { ...cfg, version: config.version } });
            toast.success('System settings saved');
            await qc.invalidateQueries();
          } catch (e) {
            setErr(e);
          }
        }}
      >
        Save system settings
      </Button>
      <ErrorText error={err} />
    </>
  );
}
