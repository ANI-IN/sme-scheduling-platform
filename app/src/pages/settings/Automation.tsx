import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { CalendarOff, RotateCcw } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useSettings, type SettingRow } from '@/lib/data';
import { useFormErrors } from '@/lib/useFormErrors';
import {
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
} from '@/components/ui';

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
    label: 'Planning and holidays',
    groups: ['Planning', 'Modules'],
    description:
      'Warnings about the class plan and instructor numbers, and the holiday list used when planning.',
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

export default function Automation() {
  const { domain } = useDomain();
  const { data, isLoading, error } = useSettings(domain?.id);
  const [tab, setTab] = useState('requests');
  return (
    <div>
      <PageHeader
        title="Automation"
        description={
          domain
            ? `How the automatic checks work for ${domain.name}. Changes apply to everything not yet sent; nothing already sent is repeated or recalled.`
            : 'Choose a domain first.'
        }
      />
      <ErrorText error={error} />
      {!domain ? (
        <Empty title="No domain yet">Create a domain on the Domains page first.</Empty>
      ) : isLoading ? (
        <SkeletonRows rows={8} />
      ) : (
        <Tabs
          value={tab}
          onValueChange={setTab}
          tabs={TABS.map((t) => ({ value: t.value, label: t.label }))}
        >
          {TABS.map((t) => (
            <TabPanel key={t.value} value={t.value} className="space-y-4">
              <p className="text-sm text-muted-foreground">{t.description}</p>
              {t.groups.map((g) => {
                const rows = (data ?? []).filter((s) => s.group === g);
                if (!rows.length) return null;
                return (
                  <Section key={g} title={GROUP_LABEL[g] ?? g}>
                    <div className="grid gap-x-6 gap-y-5 md:grid-cols-2">
                      {rows.map((s) => (
                        <SettingEditor
                          key={`${s.key}:${JSON.stringify(s.value)}`}
                          s={s}
                          domainId={domain.id}
                        />
                      ))}
                    </div>
                  </Section>
                );
              })}
              {t.value === 'planning' && <Holidays />}
            </TabPanel>
          ))}
        </Tabs>
      )}
    </div>
  );
}

function toText(s: SettingRow, v: unknown): string {
  if (s.type === 'int_list') return (v as number[]).join(', ');
  if (s.type === 'text_list') return (v as string[]).join('\n');
  if (s.type === 'json') return JSON.stringify(v);
  return String(v);
}

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
  Alert: 'Tell the operations team and keep the booking',
  Release: 'Release the booking and find someone else',
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

function display(s: SettingRow, v: unknown): string {
  if (s.type === 'bool') return v ? 'On' : 'Off';
  if (s.type === 'enum') return ENUM_LABEL[String(v)] ?? String(v);
  if (s.type === 'time') return DateTime.fromFormat(String(v), 'HH:mm').toFormat('h:mm a');
  return toText(s, v).replace(/\n/g, ', ');
}

function SettingEditor({ s, domainId }: { s: SettingRow; domainId: string }) {
  const qc = useQueryClient();
  const [text, setText] = useState(toText(s, s.value));
  const [err, setErr] = useState<string | null>(null);

  const parse = (): unknown => {
    switch (s.type) {
      case 'int':
        return Number(text);
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
      toast.success('Setting saved');
      await qc.invalidateQueries({ queryKey: ['setting'] });
    } catch (e) {
      setErr((e as Error).message);
    }
  };
  const reset = async () => {
    await rpc('reset_setting', { p_domain_id: domainId, p_key: s.key });
    toast.success('Back to the default');
    await qc.invalidateQueries({ queryKey: ['setting'] });
  };

  const range = s.min !== null && s.max !== null ? `Between ${s.min} and ${s.max}.` : '';
  const hint = (
    <>
      {[s.help, range].filter(Boolean).join(' ')} Default: {display(s, s.default)}.
      {s.overridden && (
        <button
          type="button"
          onClick={() => void reset()}
          className="ml-2 inline-flex items-center gap-1 text-link hover:underline"
        >
          <RotateCcw className="h-3 w-3" aria-hidden /> Use the default
        </button>
      )}
    </>
  );

  if (s.key === 'help_routing') {
    const v = (s.value ?? {}) as Record<string, string>;
    return (
      <Field
        label={s.label}
        hint="Who is told about each kind of help request."
        className="md:col-span-2"
      >
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
                aria-label={CATEGORY_LABEL[cat] ?? cat}
                onChange={(e) => void save({ ...v, [cat]: e.target.value })}
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
                {o === 'true' ? 'On' : o === 'false' ? 'Off' : (ENUM_LABEL[o] ?? o)}
              </option>
            ))}
          </Select>
        ) : s.type === 'text_list' ? (
          <Textarea value={text} onChange={(e) => setText(e.target.value)} className="min-h-24" />
        ) : (
          <Input
            type={s.type === 'int' ? 'number' : s.type === 'time' ? 'time' : 'text'}
            value={text}
            onChange={(e) => setText(e.target.value)}
            className={s.type === 'int' ? 'w-28' : undefined}
          />
        )}
        {s.type !== 'enum' && s.type !== 'bool' && (
          <Button
            variant="secondary"
            onClick={() => void save()}
            disabled={text === toText(s, s.value)}
          >
            Save
          </Button>
        )}
      </div>
    </Field>
  );
}

function Holidays() {
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ['holiday'],
    queryFn: async () => check(await supabase.from('holiday').select('*').order('date')),
  });
  const [h, setH] = useState({ date: '', name: '' });
  const [err, setErr] = useState<unknown>(null);
  const v = useFormErrors({
    date: !h.date ? 'Choose a date.' : undefined,
    name: !h.name.trim() ? 'Give the holiday a name.' : undefined,
  });
  const add = async () => {
    setErr(null);
    if (!v.submit()) return;
    try {
      check(await supabase.from('holiday').insert({ date: h.date, name: h.name.trim() }));
      setH({ date: '', name: '' });
      v.reset();
      toast.success('Holiday added');
      await qc.invalidateQueries({ queryKey: ['holiday'] });
    } catch (e) {
      setErr(e);
    }
  };
  return (
    <Section
      title="Holidays"
      description="Shown when planning classes, so holiday weeks are easy to spot. Used by every domain."
    >
      {isLoading ? (
        <SkeletonRows rows={3} />
      ) : (data ?? []).length === 0 ? (
        <Empty title="No holidays yet" icon={<CalendarOff className="h-5 w-5" />} />
      ) : (
        <ul className="mb-4 grid gap-1.5 text-sm sm:grid-cols-2">
          {(data ?? []).map((x) => (
            <li
              key={x.id}
              className="flex items-center justify-between rounded-md border border-border px-3 py-1.5"
            >
              <span>
                <span className="font-medium">{x.name}</span>
                <span className="text-muted-foreground">
                  , {DateTime.fromISO(x.date).toFormat('ccc LLL d, yyyy')}
                </span>
              </span>
              <Button
                size="sm"
                variant="ghost"
                onClick={async () => {
                  check(await supabase.from('holiday').delete().eq('id', x.id));
                  toast.success('Holiday removed');
                  await qc.invalidateQueries({ queryKey: ['holiday'] });
                }}
              >
                Remove
              </Button>
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap items-start gap-2">
        <Field label="Date" error={v.show('date')}>
          <Input
            type="date"
            value={h.date}
            onBlur={v.touch('date')}
            onChange={(e) => setH({ ...h, date: e.target.value })}
            className="w-44"
          />
        </Field>
        <Field label="Name" error={v.show('name')}>
          <Input
            value={h.name}
            onBlur={v.touch('name')}
            onChange={(e) => setH({ ...h, name: e.target.value })}
            className="w-60"
          />
        </Field>
        <Button variant="secondary" className="mt-6" onClick={() => void add()}>
          Add holiday
        </Button>
      </div>
      <ErrorText error={err} />
    </Section>
  );
}
