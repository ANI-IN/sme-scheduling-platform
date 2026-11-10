import { useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { RotateCcw } from 'lucide-react';
import { rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useCohorts, useModules, useWeeks, type SettingRow } from '@/lib/data';
import { useUnsavedChanges } from '@/lib/unsaved';
import { PauseAllSection } from '@/components/PauseAll';
import {
  Badge,
  Button,
  Empty,
  ErrorText,
  Field,
  Input,
  PageHeader,
  Section,
  Select,
  SkeletonRows,
  TabPanel,
  Tabs,
  Textarea,
  cn,
} from '@/components/ui';

type Scope = 'Domain' | 'Cohort' | 'Module' | 'ModuleWeek';

/** Settings groups shown together on one tab (group names come from the database). */
const TABS: { value: string; label: string; groups: string[]; description: string }[] = [
  {
    value: 'requests',
    label: 'Requests and timing',
    groups: ['Channels', 'Outreach', 'Windows', 'Quiet hours'],
    description:
      'How and when instructors are asked, how long we wait for an answer, and when messages are not sent.',
  },
  {
    value: 'before',
    label: 'Before class',
    groups: ['Check-ins', 'Checklist'],
    description: 'Reminders before class and the class tasks for the operations team.',
  },
  {
    value: 'help',
    label: 'Help and follow up',
    groups: ['Help', 'Reminders'],
    description:
      'How quickly help requests are answered and how the team is reminded about open tasks.',
  },
  {
    value: 'planning',
    label: 'Planning',
    groups: ['Planning', 'Modules'],
    description: 'Warnings about the class plan and the number of instructors per module.',
  },
];

export const GROUP_LABEL: Record<string, string> = {
  Channels: 'Message channels',
  Outreach: 'Asking instructors',
  Windows: 'Waiting for answers',
  'Quiet hours': 'Quiet hours',
  'Check-ins': 'Reminders before class',
  Checklist: 'Class tasks',
  Help: 'Help requests',
  Reminders: 'Reminders to the team',
  Planning: 'Planning',
  Modules: 'Instructors per module',
};

/** Ready made timing choices. Standard is the default; the exact numbers stay under Advanced. */
const PRESETS: {
  id: string;
  label: string;
  description: string;
  values: Record<string, number>;
}[] = [
  {
    id: 'standard',
    label: 'Standard',
    description: 'Start asking 30 days before. A day to reply when the class is far away.',
    values: {
      outreach_days: 30,
      readiness_days: 45,
      window_long_reminder_h: 24,
      window_long_move_h: 48,
      window_mid_reminder_h: 12,
      window_mid_move_h: 24,
      window_short_reminder_h: 3,
      window_short_move_h: 6,
    },
  },
  {
    id: 'relaxed',
    label: 'Relaxed',
    description: 'Start asking 35 days before and give instructors more time to reply.',
    values: {
      outreach_days: 35,
      readiness_days: 50,
      window_long_reminder_h: 36,
      window_long_move_h: 72,
      window_mid_reminder_h: 18,
      window_mid_move_h: 36,
      window_short_reminder_h: 4,
      window_short_move_h: 8,
    },
  },
  {
    id: 'strict',
    label: 'Strict',
    description: 'Start asking 25 days before and move on to the next instructor sooner.',
    values: {
      outreach_days: 25,
      readiness_days: 40,
      window_long_reminder_h: 12,
      window_long_move_h: 24,
      window_mid_reminder_h: 6,
      window_mid_move_h: 12,
      window_short_reminder_h: 2,
      window_short_move_h: 4,
    },
  },
];
const ADVANCED_GROUPS = new Set(['Windows']);

const SOURCE: Record<string, string> = {
  Default: 'Default',
  Global: 'From settings for every domain',
  Domain: 'From domain settings',
  Cohort: 'Changed for this cohort',
  Module: 'Changed for this module',
  ModuleWeek: 'Changed for this class week',
};
const SCOPE_NOUN: Record<Scope, string> = {
  Domain: 'the whole domain',
  Cohort: 'this cohort',
  Module: 'this module',
  ModuleWeek: 'this class week',
};

const ENUM_LABEL: Record<string, string> = {
  Both: 'Discord and email',
  DiscordOnly: 'Discord only',
  EmailOnly: 'Email only',
  Discord: 'Discord',
  DiscordAndEmail: 'Discord and email',
  Sequential: 'Instructor order',
  Manual: 'Chosen list',
  Stop: 'Stop and tell me',
  ContinueWithRanking: 'Continue with the instructor order',
  Alert: 'Tell the operations team and keep the instructor',
  Release: 'Release the instructor and find someone else',
};
const ROUTE_LABEL: Record<string, string> = {
  Owner: 'Module owners',
  Ops: 'Operations team',
  Both: 'Both',
};
const CATEGORY_LABEL: Record<string, string> = {
  materials: 'Class materials',
  zoom: 'Zoom link or calendar invite',
  platform: 'Platform access',
  assignment: 'Assignment or test review',
  students: 'Students and cohort',
  schedule: 'Schedule question',
  payment: 'Payment or admin',
  other: 'Something else',
};

function toText(s: SettingRow, v: unknown): string {
  if (v === null || v === undefined) return '';
  if (s.type === 'int_list') return (v as number[]).join(', ');
  if (s.type === 'text_list') return (v as string[]).join('\n');
  if (s.type === 'json') return JSON.stringify(v);
  return String(v);
}
function fromText(s: SettingRow, text: string): unknown {
  switch (s.type) {
    case 'int':
      return text.trim() === '' ? NaN : Number(text);
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
    case 'bool':
      return text === 'true';
    default:
      return text;
  }
}
function display(s: SettingRow, v: unknown): string {
  if (s.type === 'bool') return v ? 'On' : 'Off';
  if (s.type === 'enum') return ENUM_LABEL[String(v)] ?? String(v);
  if (s.type === 'time') return DateTime.fromFormat(String(v), 'HH:mm').toFormat('h:mm a');
  if (s.type === 'json') return 'the default routing';
  return toText(s, v).replace(/\n/g, ', ');
}
/** A plain problem with a value, before it is sent to the database. */
function problem(s: SettingRow, v: unknown): string | undefined {
  if (s.type === 'int') {
    const n = v as number;
    if (!Number.isInteger(n)) return 'Enter a whole number.';
    if (s.min !== null && s.max !== null && (n < s.min || n > s.max))
      return `Enter a number from ${s.min} to ${s.max}.`;
  }
  if (s.type === 'int_list' && (v as number[]).length === 0) return 'Enter at least one number.';
  return undefined;
}

export default function Automation() {
  const { domain } = useDomain();
  const qc = useQueryClient();
  const cohorts = useCohorts(domain?.id);
  const modules = useModules(domain?.id);
  const weeks = useWeeks(domain?.id);
  const [params, setParams] = useSearchParams();
  const scope = (params.get('scope') as Scope | null) ?? 'Domain';
  const scopeId = scope === 'Domain' ? domain?.id : (params.get('id') ?? undefined);
  const [tab, setTab] = useState('requests');
  const [draft, setDraft] = useState<Record<string, unknown>>({});
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);

  const settings = useQuery({
    queryKey: ['setting', scope, scopeId],
    enabled: !!scopeId,
    queryFn: async () =>
      (await rpc('effective_settings_for', {
        p_scope: scope,
        p_scope_id: scopeId!,
      })) as unknown as SettingRow[],
  });
  const rows = useMemo(() => settings.data ?? [], [settings.data]);
  const byKey = useMemo(() => new Map(rows.map((r) => [r.key, r])), [rows]);
  const dirty = Object.keys(draft).length > 0;
  useUnsavedChanges(dirty);

  /** The value shown in a field: unsaved edit first, else the saved value. */
  const current = (s: SettingRow) => (s.key in draft ? draft[s.key] : s.value);
  const effective = (key: string) => {
    const s = byKey.get(key);
    return s ? current(s) : undefined;
  };
  const stage = (key: string, v: unknown) => setDraft((d) => ({ ...d, [key]: v }));
  const problems = Object.entries(draft)
    .map(([k, v]) => (v === null ? undefined : problem(byKey.get(k)!, v)))
    .filter(Boolean);

  const changeScope = (v: string) => {
    if (dirty && !window.confirm('You have unsaved changes. Leave without saving?')) return;
    setDraft({});
    const [sc, id] = v.split(':');
    setParams(sc === 'Domain' ? {} : { scope: sc!, id: id! });
  };

  async function save() {
    if (problems.length > 0) return;
    setBusy(true);
    setErr(null);
    try {
      await rpc('set_settings_at', {
        p_scope: scope,
        p_scope_id: scopeId!,
        p_values: draft as never,
        p_reason: reason.trim() || undefined,
      });
      toast.success('Changes saved');
      setDraft({});
      setReason('');
      await qc.invalidateQueries({ queryKey: ['setting'] });
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  const week = (weeks.data ?? []).find((w) => w.id === scopeId);
  const preset = PRESETS.find((p) =>
    Object.entries(p.values).every(([k, v]) => Number(effective(k)) === v),
  );

  return (
    <div className={cn(dirty && 'pb-24')}>
      <PageHeader
        title="Automation"
        description={
          domain
            ? `How the automatic checks work for ${domain.name}. Changes apply to everything not yet sent; nothing already sent is repeated.`
            : 'Choose a domain first.'
        }
      />
      {!domain ? (
        <Empty title="No domain yet">Create a domain on the Domains page first.</Empty>
      ) : (
        <div className="space-y-5">
          <Section
            title="Settings for"
            description="Change a setting for the whole domain, or only for one cohort, one module or one class week. More specific settings win."
          >
            <Select
              aria-label="Settings for"
              value={scope === 'Domain' ? 'Domain' : `${scope}:${scopeId}`}
              onChange={(e) => changeScope(e.target.value)}
              className="max-w-md"
            >
              <option value="Domain">The whole domain ({domain.name})</option>
              {(cohorts.data ?? []).length > 0 && (
                <optgroup label="A cohort">
                  {(cohorts.data ?? []).map((c) => (
                    <option key={c.id} value={`Cohort:${c.id}`}>
                      Cohort: {c.name}
                    </option>
                  ))}
                </optgroup>
              )}
              <optgroup label="A module">
                {(modules.data ?? []).map((m) => (
                  <option key={m.id} value={`Module:${m.id}`}>
                    Module: {m.name}
                  </option>
                ))}
              </optgroup>
              {scope === 'ModuleWeek' && (
                <option value={`ModuleWeek:${scopeId}`}>
                  Class week: {week?.module?.name ?? 'one class week'}
                  {week?.first_class_at
                    ? `, ${DateTime.fromISO(week.first_class_at).setZone('America/Los_Angeles').toFormat('ccc LLL d')}`
                    : ''}
                </option>
              )}
            </Select>
          </Section>

          <ErrorText error={settings.error} />
          {settings.isLoading || !scopeId ? (
            <SkeletonRows rows={8} />
          ) : (
            <Tabs
              value={tab}
              onValueChange={setTab}
              tabs={TABS.map(({ value, label }) => ({ value, label }))}
            >
              {TABS.map((t) => (
                <TabPanel key={t.value} value={t.value} className="space-y-4">
                  <p className="text-sm text-muted-foreground">{t.description}</p>
                  {t.value === 'requests' && (
                    <>
                      <Timeline get={effective} />
                      <Section
                        title="Timing"
                        description="Choose how quickly instructors are asked and moved on. You can change each number under Advanced."
                      >
                        <div className="grid gap-3 sm:grid-cols-3">
                          {PRESETS.map((p) => (
                            <button
                              key={p.id}
                              type="button"
                              aria-pressed={preset?.id === p.id}
                              onClick={() => setDraft((d) => ({ ...d, ...p.values }))}
                              className={cn(
                                'rounded-lg border p-3 text-left text-sm hover:bg-muted/50',
                                preset?.id === p.id
                                  ? 'border-primary ring-1 ring-primary'
                                  : 'border-border',
                              )}
                            >
                              <div className="font-semibold">{p.label}</div>
                              <div className="mt-0.5 text-muted-foreground">{p.description}</div>
                            </button>
                          ))}
                        </div>
                        {!preset && (
                          <p className="mt-2 text-xs text-muted-foreground">
                            The current numbers are your own mix (see Advanced).
                          </p>
                        )}
                      </Section>
                    </>
                  )}
                  {t.groups.map((g) => {
                    const list = rows.filter((s) => s.group === g);
                    if (!list.length) return null;
                    const body = (
                      <div className="grid gap-x-6 gap-y-5 md:grid-cols-2">
                        {list.map((s) => (
                          <SettingField
                            key={s.key}
                            s={s}
                            scope={scope}
                            value={current(s)}
                            changed={s.key in draft}
                            onChange={(v) => stage(s.key, v)}
                            onReset={() => stage(s.key, null)}
                          />
                        ))}
                      </div>
                    );
                    return ADVANCED_GROUPS.has(g) ? (
                      <Section key={g} title={`Advanced: ${GROUP_LABEL[g] ?? g}`}>
                        <details>
                          <summary className="cursor-pointer text-sm font-medium text-link">
                            Show the exact numbers
                          </summary>
                          <div className="mt-4">{body}</div>
                        </details>
                      </Section>
                    ) : (
                      <Section key={g} title={GROUP_LABEL[g] ?? g}>
                        {body}
                      </Section>
                    );
                  })}
                  {t.value === 'help' && <PauseAllSection />}
                </TabPanel>
              ))}
            </Tabs>
          )}
        </div>
      )}

      {dirty && (
        <div className="fixed inset-x-0 bottom-0 z-30 border-t border-border bg-card/95 px-4 py-3 shadow-lg backdrop-blur md:left-64">
          <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-3">
            <span className="text-sm font-medium">
              You have unsaved changes for {SCOPE_NOUN[scope]}.
            </span>
            {scope !== 'Domain' && (
              <Input
                aria-label="Reason (optional)"
                placeholder="Reason (optional, saved in Activity history)"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                className="w-72"
              />
            )}
            {problems.length > 0 && (
              <span className="text-sm text-danger-strong">
                Fix the fields marked in red first.
              </span>
            )}
            <div className="ml-auto flex gap-2">
              <Button variant="secondary" onClick={() => setDraft({})} disabled={busy}>
                Discard
              </Button>
              <Button onClick={() => void save()} loading={busy} disabled={problems.length > 0}>
                Save changes
              </Button>
            </div>
            <ErrorText error={err} />
          </div>
        </div>
      )}
    </div>
  );
}

/** A picture of what happens before a class, with the current numbers. */
function Timeline({ get }: { get: (key: string) => unknown }) {
  const n = (k: string) => Number(get(k) ?? 0);
  const checkins = ((get('checkin_days') as number[] | undefined) ?? [])
    .slice()
    .sort((a, b) => b - a);
  const points = [
    { days: n('readiness_days'), label: 'Setup check' },
    { days: n('outreach_days'), label: 'Start asking instructors' },
    { days: n('owner_checkin_days'), label: 'Ask the module owner' },
    ...checkins.map((d, i) => ({
      days: d,
      label: i === checkins.length - 1 ? 'Final reminder before class' : 'Reminder before class',
    })),
  ]
    .filter((p) => p.days > 0)
    .sort((a, b) => b.days - a.days);
  const max = Math.max(...points.map((p) => p.days), 1);
  const close = n('short_notice_days');
  const veryClose = n('urgent_band_days');
  return (
    <Section
      title="What happens before a class"
      description="Days before the first class of a class week. Close to the class, replies are expected faster and problems are urgent."
    >
      <div className="relative mt-2 mb-10 h-2 rounded-full bg-muted" aria-hidden>
        <div
          className="absolute inset-y-0 right-0 rounded-r-full bg-warning-soft"
          style={{ width: `${(close / max) * 100}%` }}
        />
        <div
          className="absolute inset-y-0 right-0 rounded-r-full bg-danger-soft"
          style={{ width: `${(veryClose / max) * 100}%` }}
        />
        {points.map((p) => (
          <div
            key={p.label + p.days}
            className="absolute top-1/2 h-3 w-3 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-card bg-primary"
            style={{ left: `${100 - (p.days / max) * 100}%` }}
          />
        ))}
      </div>
      <ol className="grid gap-1 text-sm sm:grid-cols-2">
        {points.map((p) => (
          <li key={p.label + p.days} className="flex gap-2">
            <span className="w-16 shrink-0 font-semibold tabular-nums">{p.days} days</span>
            <span>{p.label}</span>
          </li>
        ))}
        <li className="flex gap-2">
          <span className="w-16 shrink-0 font-semibold tabular-nums">{close} days</span>
          <span>Close to the class: problems are urgent</span>
        </li>
        <li className="flex gap-2">
          <span className="w-16 shrink-0 font-semibold tabular-nums">{veryClose} days</span>
          <span>Very close to the class: fastest replies, shorter quiet hours</span>
        </li>
      </ol>
    </Section>
  );
}

function SettingField({
  s,
  scope,
  value,
  changed,
  onChange,
  onReset,
}: {
  s: SettingRow;
  scope: Scope;
  value: unknown;
  changed: boolean;
  onChange: (v: unknown) => void;
  onReset: () => void;
}) {
  const [text, setText] = useState(toText(s, value));
  const [touched, setTouched] = useState(false);
  const shownText = changed ? text : toText(s, value);
  const resetting = changed && value === null;
  const own = s.source === scope && !changed;
  const range = s.min !== null && s.max !== null ? `From ${s.min} to ${s.max}.` : '';
  const err = touched && changed && value !== null ? problem(s, value) : undefined;
  const meta = (
    <span className="mt-1 flex flex-wrap items-center gap-2">
      <Badge tone={own || changed ? 'info' : 'neutral'}>
        {resetting
          ? 'Will use the value above'
          : changed
            ? 'Not saved yet'
            : SOURCE[s.source ?? 'Default']}
      </Badge>
      {own && (
        <button
          type="button"
          onClick={onReset}
          className="inline-flex items-center gap-1 text-xs text-link hover:underline"
        >
          <RotateCcw className="h-3 w-3" aria-hidden />
          {scope === 'Domain' ? 'Reset to default' : 'Use the value above'}
        </button>
      )}
    </span>
  );
  const hint = (
    <>
      {[s.help, range].filter(Boolean).join(' ')} Default: {display(s, s.default)}.{meta}
    </>
  );

  if (s.key === 'help_routing') {
    const v = ((resetting ? s.value : value) ?? {}) as Record<string, string>;
    return (
      <Field label={s.label} hint={hint} className="md:col-span-2">
        <div className="grid gap-2 sm:grid-cols-2">
          {Object.entries(v).map(([cat, who]) => (
            <div
              key={cat}
              className="flex items-center justify-between gap-2 rounded-md border border-border px-3 py-1.5 text-sm"
            >
              <span>{CATEGORY_LABEL[cat] ?? cat}</span>
              <Select
                className="h-8 w-44"
                value={who}
                aria-label={`Who gets help requests about ${CATEGORY_LABEL[cat] ?? cat}`}
                onChange={(e) => onChange({ ...v, [cat]: e.target.value })}
              >
                {['Owner', 'Ops', 'Both'].map((o) => (
                  <option key={o} value={o}>
                    {ROUTE_LABEL[o]}
                  </option>
                ))}
              </Select>
            </div>
          ))}
        </div>
      </Field>
    );
  }

  return (
    <Field label={s.label} hint={hint} error={err}>
      {s.type === 'enum' || s.type === 'bool' ? (
        <Select
          value={resetting ? toText(s, s.value) : String(value)}
          onChange={(e) => onChange(fromText(s, e.target.value))}
        >
          {(s.type === 'bool' ? ['true', 'false'] : (s.allowed ?? [])).map((o) => (
            <option key={o} value={o}>
              {o === 'true' ? 'On' : o === 'false' ? 'Off' : (ENUM_LABEL[o] ?? o)}
            </option>
          ))}
        </Select>
      ) : s.type === 'text_list' ? (
        <Textarea
          value={shownText}
          onBlur={() => setTouched(true)}
          onChange={(e) => {
            setText(e.target.value);
            onChange(fromText(s, e.target.value));
          }}
          className="min-h-24"
          aria-describedby={undefined}
        />
      ) : (
        <Input
          type={s.type === 'int' ? 'number' : s.type === 'time' ? 'time' : 'text'}
          value={resetting ? toText(s, s.value) : shownText}
          onBlur={() => setTouched(true)}
          onChange={(e) => {
            setText(e.target.value);
            onChange(fromText(s, e.target.value));
          }}
          className={s.type === 'int' ? 'w-28' : undefined}
        />
      )}
      {s.type === 'text_list' && (
        <span className="text-xs text-muted-foreground">One per line.</span>
      )}
    </Field>
  );
}

export function ScopeLink({
  scope,
  id,
  children,
}: {
  scope: Scope;
  id: string;
  children: React.ReactNode;
}) {
  return (
    <Link to={`/settings/automation?scope=${scope}&id=${id}`} className="text-link hover:underline">
      {children}
    </Link>
  );
}
