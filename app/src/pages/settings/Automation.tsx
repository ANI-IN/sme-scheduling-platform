import { useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { RotateCcw } from 'lucide-react';
import { rpc } from '@/lib/rpc';
import { refresh } from '@/lib/live';
import type { SaveStatus } from '@/lib/autosave';
import { SaveState } from '@/components/SaveState';
import { useDomain } from '@/lib/domain';
import { useCohorts, type SettingRow } from '@/lib/data';
import { useUnsavedChanges } from '@/lib/unsaved';
import { PauseAllSection } from '@/components/PauseAll';
import {
  Badge,
  Button,
  Empty,
  ErrorText,
  Field,
  Input,
  Notice,
  PageHeader,
  Section,
  Select,
  SkeletonRows,
  Switch,
  Textarea,
  cn,
} from '@/components/ui';

type Scope = 'Domain' | 'Cohort';

/** The main choices shown first; everything else is under "More options". */
const ASKING = ['outreach_days', 'default_outreach_mode', 'welcome_message'];
const REMINDER_PARTS: { title: string; keys: string[] }[] = [
  {
    title: 'While we wait for an answer',
    keys: [
      'answer_reminders',
      'window_long_reminder_h',
      'window_mid_reminder_h',
      'window_short_reminder_h',
    ],
  },
  {
    title: 'After an instructor is assigned',
    keys: [
      'remind_instructor_after_assign',
      'checkin_days',
      'remind_team_after_assign',
      'owner_checkin_days',
      'checklist_nudge_days',
    ],
  },
  {
    title: 'Open tasks for the team',
    keys: [
      'reminder_r2_normal_h',
      'reminder_r2_urgent_h',
      'reminder_escalate_normal_h',
      'reminder_escalate_urgent_h',
      'daily_summary',
    ],
  },
];
/** Number fields where 0 switches the reminder off. */
const ZERO_OFF = new Set([
  'window_long_reminder_h',
  'window_mid_reminder_h',
  'window_short_reminder_h',
  'owner_checkin_days',
  'checklist_nudge_days',
  'reminder_r2_normal_h',
  'reminder_r2_urgent_h',
  'reminder_escalate_normal_h',
  'reminder_escalate_urgent_h',
]);
/** Which switch a number belongs to: the number is greyed out while its switch is off. */
const SWITCH_FOR: Record<string, string> = {
  window_long_reminder_h: 'answer_reminders',
  window_mid_reminder_h: 'answer_reminders',
  window_short_reminder_h: 'answer_reminders',
  checkin_days: 'remind_instructor_after_assign',
  owner_checkin_days: 'remind_team_after_assign',
  checklist_nudge_days: 'remind_team_after_assign',
};
const MORE_GROUPS = [
  'Outreach',
  'Windows',
  'Quiet hours',
  'LastReminder',
  'Checklist',
  'Help',
  'Planning',
  'Modules',
];

const GROUP_LABEL: Record<string, string> = {
  Outreach: 'Asking instructors',
  Windows: 'How long we wait for an answer',
  'Quiet hours': 'Quiet hours',
  LastReminder: 'When the last reminder before class gets no answer',
  Checklist: 'Class tasks',
  Help: 'Help requests',
  Reminders: 'Reminders to the team',
  Planning: 'Planning',
  Modules: 'Instructors per module',
};

/** Ready made timing choices for asking and moving on. Standard is the default. */
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
      window_long_move_h: 48,
      window_mid_move_h: 24,
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
      window_long_move_h: 72,
      window_mid_move_h: 36,
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
      window_long_move_h: 24,
      window_mid_move_h: 12,
      window_short_move_h: 4,
    },
  },
];

const SOURCE: Record<string, string> = {
  Default: 'Default',
  Domain: 'From domain settings',
  Cohort: 'Changed for this cohort',
};
const SCOPE_NOUN: Record<Scope, string> = {
  Domain: 'the whole domain',
  Cohort: 'this cohort',
};

const ENUM_LABEL: Record<string, string> = {
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
  materials: 'Class materials or content',
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
  if (s.type === 'int_list' && (v as number[]).length === 0 && s.key !== 'checkin_days')
    return 'Enter at least one number.';
  return undefined;
}

export default function Automation() {
  const { domain } = useDomain();
  const qc = useQueryClient();
  const cohorts = useCohorts(domain?.id);
  const [params, setParams] = useSearchParams();
  const scope = (params.get('scope') as Scope | null) ?? 'Domain';
  const scopeId = scope === 'Domain' ? domain?.id : (params.get('id') ?? undefined);
  const [draft, setDraft] = useState<Record<string, unknown>>({});
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  // Switches save as soon as they change (C15). Until the list loads again they show what was just saved.
  const [justSaved, setJustSaved] = useState<Record<string, unknown>>({});
  const [switchState, setSwitchState] = useState<Record<string, SaveStatus>>({});

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
  // Fresh settings arrived: they already have what was just saved.
  const [seenRows, setSeenRows] = useState(settings.data);
  if (seenRows !== settings.data) {
    setSeenRows(settings.data);
    if (!settings.isFetching && Object.keys(justSaved).length > 0) setJustSaved({});
  }
  const byKey = useMemo(() => new Map(rows.map((r) => [r.key, r])), [rows]);
  const dirty = Object.keys(draft).length > 0;
  useUnsavedChanges(dirty);

  /** The value shown in a field: unsaved edit first, else the saved value. */
  const current = (s: SettingRow) =>
    s.key in draft ? draft[s.key] : s.key in justSaved ? justSaved[s.key] : s.value;
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
    setJustSaved({});
    setSwitchState({});
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
      // Until the settings load again, show what was just saved rather than the old values.
      setJustSaved((j) => ({
        ...j,
        ...Object.fromEntries(Object.entries(draft).filter(([, v]) => v !== null)),
      }));
      setDraft({});
      setReason('');
      refresh(qc, 'setting');
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  /**
   * A switch saves at once: it only turns one thing on or off, and turning it back is as easy. The numbers, times
   * and lists keep the Save changes bar, because they move when instructors are asked and reminded: the timeline
   * above shows the new plan before it is saved, and a cohort change can carry a reason.
   */
  async function saveSwitch(key: string, value: boolean | null) {
    setSwitchState((x) => ({ ...x, [key]: { state: 'saving', error: null } }));
    try {
      await rpc('set_settings_at', {
        p_scope: scope,
        p_scope_id: scopeId!,
        p_values: { [key]: value } as never,
      });
      // "Use the value above" shows the value above once the settings load again.
      if (value !== null) setJustSaved((j) => ({ ...j, [key]: value }));
      setSwitchState((x) => ({ ...x, [key]: { state: 'saved', error: null } }));
      refresh(qc, 'setting');
    } catch (e) {
      setSwitchState((x) => ({
        ...x,
        [key]: { state: 'error', error: e instanceof Error ? e.message : String(e) },
      }));
    }
  }

  // The daily summary covers every cohort a person helps with, and the welcome message goes once per domain, so
  // both are set for the domain only.
  const DOMAIN_ONLY = new Set(['daily_summary', 'welcome_message']);
  const fields = (keys: string[]) =>
    keys
      .filter((k) => scope === 'Domain' || !DOMAIN_ONLY.has(k))
      .map((k) => {
        const s = byKey.get(k);
        if (!s) return null;
        const sw = SWITCH_FOR[k];
        return (
          <SettingField
            key={k}
            s={s}
            scope={scope}
            value={current(s)}
            changed={k in draft}
            off={sw !== undefined && effective(sw) === false}
            onChange={(v) => (s.type === 'bool' ? void saveSwitch(k, v as boolean) : stage(k, v))}
            onReset={() => (s.type === 'bool' ? void saveSwitch(k, null) : stage(k, null))}
            saveStatus={switchState[k]}
          />
        );
      });
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
            description="Settings apply to the whole domain. A cohort can change any of them for its own classes."
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
            </Select>
          </Section>

          <ErrorText error={settings.error} />
          {settings.isLoading || !scopeId ? (
            <SkeletonRows rows={8} />
          ) : (
            <div className="space-y-5">
              <Timeline get={effective} />
              <Section
                title="Asking instructors"
                description="When we start asking, how quickly we move on to the next instructor, and the welcome message for new instructors."
              >
                <div className="mb-5 grid gap-3 sm:grid-cols-3">
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
                  <p className="mb-4 text-xs text-muted-foreground">
                    The current numbers are your own mix (see More options).
                  </p>
                )}
                <div className="grid gap-x-6 gap-y-5 md:grid-cols-2">{fields(ASKING)}</div>
              </Section>

              <Section
                title="Reminders"
                description="Switch any reminder off, or set its number to 0."
              >
                <Notice tone="info">
                  Turning reminders off never stops the main automation. Instructors are still asked
                  in order, the next instructor is still asked when there is no answer, and urgent
                  alerts (for example a cancellation, or nobody left to ask) are always sent.
                </Notice>
                <div className="mt-5 space-y-6">
                  {REMINDER_PARTS.map((part) => (
                    <fieldset key={part.title} className="space-y-4">
                      <legend className="mb-2 text-sm font-semibold">{part.title}</legend>
                      <div className="grid gap-x-6 gap-y-5 md:grid-cols-2">{fields(part.keys)}</div>
                    </fieldset>
                  ))}
                </div>
              </Section>

              <Section title="More options" description="Most teams never need to change these.">
                <details>
                  <summary className="cursor-pointer text-sm font-medium text-link">
                    Show more options
                  </summary>
                  <div className="mt-5 space-y-8">
                    {MORE_GROUPS.map((g) => {
                      const keys = rows
                        .filter((r) => r.group === g && !ASKING.includes(r.key))
                        .map((r) => r.key);
                      if (!keys.length) return null;
                      return (
                        <div key={g}>
                          <h3 className="mb-3 text-sm font-semibold">{GROUP_LABEL[g] ?? g}</h3>
                          <div className="grid gap-x-6 gap-y-5 md:grid-cols-2">{fields(keys)}</div>
                        </div>
                      );
                    })}
                  </div>
                </details>
              </Section>
              <PauseAllSection />
            </div>
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
  off,
  onChange,
  onReset,
  saveStatus,
}: {
  s: SettingRow;
  scope: Scope;
  value: unknown;
  changed: boolean;
  /** Its switch is off, so this number is not used. */
  off?: boolean;
  onChange: (v: unknown) => void;
  onReset: () => void;
  /** A switch that saved by itself: Saving, Saved or why not. */
  saveStatus?: SaveStatus;
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
      {ZERO_OFF.has(s.key) && '0 means no reminder. '}
      {off && 'Not used while the switch above is off. '}
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

  if (s.type === 'bool') {
    const on = resetting ? s.value === true : value === true;
    return (
      <div className="md:col-span-2">
        <Switch label={s.label} checked={on} onChange={(v) => onChange(v)} hint={hint} />
        {saveStatus && <SaveState className="mt-1 ml-12" status={saveStatus} />}
      </div>
    );
  }

  return (
    <Field label={s.label} hint={hint} error={err} className={cn(off && 'opacity-60')}>
      {s.type === 'enum' ? (
        <Select
          value={resetting ? toText(s, s.value) : String(value)}
          onChange={(e) => onChange(fromText(s, e.target.value))}
        >
          {(s.allowed ?? []).map((o) => (
            <option key={o} value={o}>
              {ENUM_LABEL[o] ?? o}
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
          placeholder={s.key === 'checkin_days' ? 'No reminders' : undefined}
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
