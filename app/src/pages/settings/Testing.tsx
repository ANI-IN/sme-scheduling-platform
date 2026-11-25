import { statusConfirm, type StatusEffects } from '@/lib/domainStatus';
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import {
  CheckCircle2,
  Clock,
  FastForward,
  Play,
  PlayCircle,
  RotateCcw,
  XCircle,
} from 'lucide-react';
import { rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useSettingsMap, useWeeks, type Domain } from '@/lib/data';
import { fmtLocal, fmtPT, PT } from '@/lib/time';
import { fmtAt, weekRegion } from '@/lib/region';
import { isEmail } from '@/lib/validation';
import { useFormErrors } from '@/lib/useFormErrors';
import { useConfirm } from '@/components/Confirm';
import { isTesting, statusLabel, statusTone } from '@/components/AppShell';
import { ChannelPicker } from '@/components/Discord';
import {
  Badge,
  Button,
  DateInput,
  Empty,
  ErrorText,
  Field,
  Input,
  Notice,
  PageHeader,
  Section,
  Select,
} from '@/components/ui';
import { refreshAll } from '@/lib/live';

/** What the automatic check reports, in plain words. */
const RESULT_LABEL: Record<string, string> = {
  completed: 'Class weeks finished',
  readiness_passed: 'Setup checks passed',
  request_updates: 'Requests reminded or moved on',
  time_changes: 'Class time changes sent',
  outreach_started: 'Instructor requests started',
  checkins: 'Reminders before class',
  owner_checkins: 'Owner summaries',
  checklist: 'Checklist reminders',
  health: 'Health warnings',
  help: 'Help request follow ups',
  reminders: 'Team reminders',
  released: 'Messages released after quiet hours',
  messages_queued: 'Messages ready to send',
};

export default function Testing() {
  const { domain } = useDomain();
  return (
    <div className="space-y-5">
      <PageHeader
        title="Testing"
        description="Try the automation safely before going live. While a domain is in testing, every message goes to your testing channel and testing email instead of real instructors."
      />
      {!domain ? (
        <Empty title="No domain yet">Create a domain on the Domains page first.</Empty>
      ) : (
        <TestingBody key={`${domain.id}:${domain.version}`} domain={domain} />
      )}
    </div>
  );
}

function TestingBody({ domain }: { domain: Domain }) {
  const qc = useQueryClient();
  const confirm = useConfirm();
  const weeks = useWeeks(domain.id);
  const settings = useSettingsMap(domain.id);
  const [targets, setTargets] = useState({
    chan: domain.test_discord_channel_id ?? '',
    mail: domain.test_email ?? '',
  });
  const [clock, setClock] = useState('');
  const [week, setWeek] = useState('');
  const [err, setErr] = useState<unknown>(null);
  const [result, setResult] = useState<Record<string, unknown> | null>(null);
  const testing = isTesting(domain);
  const v = useFormErrors({
    mail: targets.mail && !isEmail(targets.mail) ? 'Enter a valid email address.' : undefined,
  });
  const days = (k: string) => Number(settings.data?.[k] ?? 0);
  const points = [
    { label: 'Setup check', days: days('readiness_days') },
    { label: 'Start of requests', days: days('outreach_days') },
    { label: '14 days before', days: days('owner_checkin_days') },
    { label: '10 days before', days: 10 },
    { label: '2 days before', days: 2 },
  ];

  async function run(fn: () => Promise<unknown>, ok?: string) {
    setErr(null);
    try {
      const r = await fn();
      if (r && typeof r === 'object' && !Array.isArray(r)) setResult(r as Record<string, unknown>);
      if (ok) toast.success(ok);
      refreshAll(qc);
    } catch (e) {
      setErr(e);
    }
  }

  return (
    <>
      <Section
        title="Testing channel and email"
        description="Where messages go while this domain is in testing. Both are needed before testing can be turned on."
        actions={<Badge tone={statusTone[domain.status]}>{statusLabel[domain.status]}</Badge>}
      >
        <div className="flex flex-wrap items-start gap-3">
          <Field
            label="Testing Discord channel"
            hint="Every Discord message of this domain goes here while it is in testing."
          >
            <ChannelPicker
              serverId="all"
              label="Testing Discord channel"
              value={targets.chan || null}
              noneLabel="No testing channel"
              onChange={(id) => setTargets({ ...targets, chan: id ?? '' })}
            />
          </Field>
          <Field label="Testing email" error={v.show('mail')}>
            <Input
              value={targets.mail}
              onBlur={v.touch('mail')}
              onChange={(e) => setTargets({ ...targets, mail: e.target.value })}
              className="w-64"
            />
          </Field>
          <Button
            variant="secondary"
            className="mt-6"
            onClick={() =>
              v.submit() &&
              run(
                () =>
                  rpc('set_test_targets', {
                    p_domain_id: domain.id,
                    p_test_discord_channel_id: targets.chan,
                    p_test_email: targets.mail,
                  }),
                'Saved',
              )
            }
          >
            Save
          </Button>
        </div>
        {!testing && (
          <div className="mt-4 flex flex-wrap items-center gap-3 border-t border-border pt-4">
            <p className="text-sm text-muted-foreground">
              {domain.name} is {statusLabel[domain.status]?.toLowerCase()}. Turn on testing to use
              the practice clock.
            </p>
            <Button
              onClick={async () => {
                if (domain.status === 'Live') {
                  const fx = (await rpc('domain_status_effects', {
                    p_domain_id: domain.id,
                    p_status: 'Test',
                  })) as unknown as StatusEffects;
                  const ask = statusConfirm(domain.name, 'Live', 'Test', fx);
                  if (ask && !(await confirm(ask))) return;
                }
                await run(
                  () => rpc('set_domain_status', { p_domain_id: domain.id, p_status: 'Test' }),
                  'Testing is on',
                );
              }}
            >
              Turn on testing
            </Button>
          </div>
        )}
      </Section>

      {testing && (
        <Section
          title="Practice clock"
          description="Pretend it is a different date and time, so you can see what the automation would do. Only this domain uses the practice clock."
        >
          <div className="mb-4 flex flex-wrap items-center gap-2 rounded-md bg-muted px-3 py-2 text-sm">
            <Clock className="h-4 w-4 text-muted-foreground" aria-hidden />
            Practice clock:{' '}
            <strong>
              {domain.test_clock_at
                ? `${fmtPT(domain.test_clock_at)} (${fmtLocal(domain.test_clock_at)} your time)`
                : 'real time'}
            </strong>
          </div>
          <div className="flex flex-wrap items-end gap-2">
            <Field label="Date">
              <DateInput
                value={clock.slice(0, 10)}
                onChange={(d) => setClock(`${d}T${clock.slice(11, 16) || '09:00'}`)}
                className="w-56"
              />
            </Field>
            <Field label="Time in US Pacific (PST or PDT)">
              <Input
                type="time"
                value={clock.slice(11, 16)}
                onChange={(e) =>
                  setClock(`${clock.slice(0, 10) || DateTime.now().toISODate()}T${e.target.value}`)
                }
                className="w-32"
              />
            </Field>
            <Button
              variant="secondary"
              disabled={!clock}
              onClick={() =>
                run(
                  () =>
                    rpc('set_test_clock', {
                      p_domain_id: domain.id,
                      p_at: DateTime.fromISO(clock, { zone: PT }).toUTC().toISO()!,
                    }),
                  'Practice clock set',
                )
              }
            >
              Set
            </Button>
            <Button
              variant="secondary"
              onClick={() =>
                run(
                  () => rpc('advance_test_clock', { p_domain_id: domain.id, p_hours: 1 }),
                  'Moved forward 1 hour',
                )
              }
            >
              <FastForward className="h-4 w-4" aria-hidden /> 1 hour
            </Button>
            <Button
              variant="secondary"
              onClick={() =>
                run(
                  () => rpc('advance_test_clock', { p_domain_id: domain.id, p_hours: 24 }),
                  'Moved forward 1 day',
                )
              }
            >
              <FastForward className="h-4 w-4" aria-hidden /> 1 day
            </Button>
            <Button
              variant="ghost"
              onClick={() =>
                run(
                  () => rpc('set_test_clock', { p_domain_id: domain.id, p_at: null as never }),
                  'Back to real time',
                )
              }
            >
              <RotateCcw className="h-4 w-4" aria-hidden /> Real time
            </Button>
          </div>

          <div className="mt-5 border-t border-border pt-4">
            <h3 className="mb-2 text-sm font-semibold">Jump to a moment before a class week</h3>
            <div className="flex flex-wrap items-end gap-2">
              <Field label="Class week">
                <Select value={week} onChange={(e) => setWeek(e.target.value)} className="w-80">
                  <option value="">Choose a class week</option>
                  {(weeks.data ?? [])
                    .filter((w) => w.first_class_at && w.status !== 'Cancelled')
                    .map((w) => (
                      <option key={w.id} value={w.id}>
                        {w.module?.name}, {fmtAt(w.first_class_at, weekRegion(w.class_session))}
                        {w.cohort && ` (${w.cohort})`}
                      </option>
                    ))}
                </Select>
              </Field>
              {points.map((p) => (
                <Button
                  key={p.label}
                  variant="secondary"
                  size="sm"
                  disabled={!week}
                  onClick={() =>
                    run(
                      () =>
                        rpc('jump_test_clock', {
                          p_domain_id: domain.id,
                          p_module_week_id: week,
                          p_days_before: p.days,
                        }),
                      `Jumped to ${p.label.toLowerCase()}`,
                    )
                  }
                >
                  {p.label}
                </Button>
              ))}
            </div>
          </div>

          <div className="mt-5 flex flex-wrap items-center gap-3 border-t border-border pt-4">
            <Button
              onClick={() =>
                run(
                  () => rpc('run_check_now', { p_domain_id: domain.id }),
                  'Automatic check finished',
                )
              }
            >
              <Play className="h-4 w-4" aria-hidden /> Run the automatic check now
            </Button>
            <span className="text-sm text-muted-foreground">
              Normally it runs every hour. Moving the clock also runs it.
            </span>
          </div>
          {result && (
            <div className="mt-4 rounded-md border border-border p-3 text-sm">
              <div className="mb-1 font-medium">Last check</div>
              <ul className="grid gap-1 sm:grid-cols-2">
                {Object.entries(result)
                  .filter(([k, val]) => RESULT_LABEL[k] && typeof val === 'number')
                  .map(([k, val]) => (
                    <li key={k} className="flex justify-between gap-2">
                      <span className="text-muted-foreground">{RESULT_LABEL[k]}</span>
                      <span className="tabular-nums">{String(val)}</span>
                    </li>
                  ))}
              </ul>
            </div>
          )}
        </Section>
      )}
      <ErrorText error={err} />

      {testing && <PracticeClass domain={domain} />}

      {testing && (
        <Section
          tone="danger"
          title="Go live"
          description={`Turn off testing for ${domain.name}. From the next automatic check, real instructors receive messages.`}
        >
          <Notice tone="warning">
            Before going live: each owner has reviewed the instructor order, and at least 8 weeks of
            classes are planned. A contact check for each instructor is optional.
          </Notice>
          <Button
            variant="destructive"
            className="mt-3"
            onClick={async () => {
              if (
                await confirm({
                  title: `Go live with ${domain.name}?`,
                  body: 'Real instructors will be contacted from the next automatic check. You can switch back to testing at any time on the Domains page.',
                  danger: true,
                  confirmLabel: 'Go live',
                })
              )
                await run(
                  () => rpc('set_domain_status', { p_domain_id: domain.id, p_status: 'Live' }),
                  `${domain.name} is live`,
                );
            }}
          >
            Go live
          </Button>
        </Section>
      )}
    </>
  );
}

type PracticeResult = {
  passed: boolean;
  steps: { step: string; passed: boolean; detail: string | null }[];
};

/** Runs a whole class week on the practice clock and checks every stage, then removes it again. */
function PracticeClass({ domain }: { domain: Domain }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const [result, setResult] = useState<PracticeResult | null>(null);
  return (
    <Section
      title="Run a practice class"
      description="Creates a practice class week with your test instructors and walks through every stage on the practice clock: asked, reminded, moved on, confirmed, reminders before class, a help request, a time change and a cancellation. Nothing is sent and everything is removed afterwards."
    >
      <Button
        loading={busy}
        onClick={async () => {
          setBusy(true);
          setErr(null);
          setResult(null);
          try {
            setResult((await rpc('run_practice_class', { p_domain_id: domain.id })) as never);
          } catch (e) {
            setErr(e);
          } finally {
            setBusy(false);
          }
        }}
      >
        <PlayCircle className="h-4 w-4" aria-hidden /> Run a practice class
      </Button>
      <ErrorText error={err} />
      {result && (
        <div className="mt-4">
          <p
            className={
              result.passed ? 'font-medium text-success-strong' : 'font-medium text-danger-strong'
            }
          >
            {result.passed
              ? 'Every stage worked.'
              : 'Some stages did not work. See below, fix the setup, and run it again.'}
          </p>
          <ul className="mt-2 space-y-1 text-sm">
            {result.steps.map((s) => (
              <li key={s.step} className="flex items-start gap-2">
                {s.passed ? (
                  <CheckCircle2
                    className="mt-0.5 h-4 w-4 shrink-0 text-success-strong"
                    aria-label="Passed"
                  />
                ) : (
                  <XCircle
                    className="mt-0.5 h-4 w-4 shrink-0 text-danger-strong"
                    aria-label="Failed"
                  />
                )}
                <span>
                  {s.step}
                  {s.detail && <span className="text-muted-foreground"> ({s.detail})</span>}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </Section>
  );
}
