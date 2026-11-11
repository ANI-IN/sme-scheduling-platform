import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { CheckCircle2, CircleAlert, PlugZap } from 'lucide-react';
import { Link } from 'react-router-dom';
import { check, rpc } from '@/lib/rpc';
import { supabase } from '@/lib/supabase';
import { useSystem, useTeam } from '@/lib/data';
import { fmtLocal } from '@/lib/time';
import { PauseAllSection } from '@/components/PauseAll';
import { DiscordServers } from './DiscordServers';
import {
  Badge,
  Button,
  cn,
  ErrorText,
  Field,
  Input,
  Notice,
  PageHeader,
  Section,
  SkeletonRows,
} from '@/components/ui';

type Config = NonNullable<ReturnType<typeof useSystem>['data']>['config'];

export default function Connections() {
  const { data, isLoading } = useSystem();
  return (
    <div className="space-y-5">
      <PageHeader
        title="Connections"
        description="Technical setup that links the app to Discord, email and the automation service (n8n)."
      />
      <Notice>
        Usually set up once by the admin.{' '}
        <Link to="/help/common-questions" className="font-medium underline">
          Read the help guide
        </Link>
        .
      </Notice>
      {isLoading || !data ? (
        <SkeletonRows rows={6} />
      ) : (
        <>
          <Health />
          <DiscordServers />
          <ConfigForm key={data.config.version} config={data.config} />
          <PauseAllSection />
          <AppErrors />
        </>
      )}
    </div>
  );
}

type Status = 'working' | 'off' | 'problem';
const STATUS: Record<Status, { label: string; tone: 'success' | 'neutral' | 'danger' }> = {
  working: { label: 'Working', tone: 'success' },
  off: { label: 'Not connected', tone: 'neutral' },
  problem: { label: 'Problem', tone: 'danger' },
};

function Row({
  status,
  label,
  children,
}: {
  status: Status;
  label: string;
  children: React.ReactNode;
}) {
  const Icon = status === 'working' ? CheckCircle2 : status === 'problem' ? CircleAlert : PlugZap;
  return (
    <div className="flex items-start gap-3 border-b border-border py-3 last:border-0">
      <Icon
        className={cn(
          'mt-0.5 h-5 w-5 shrink-0',
          status === 'working'
            ? 'text-success-strong'
            : status === 'problem'
              ? 'text-danger-strong'
              : 'text-muted-foreground',
        )}
        aria-hidden
      />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2 text-sm font-medium">
          {label}
          <Badge tone={STATUS[status].tone}>{STATUS[status].label}</Badge>
        </div>
        <div className="text-sm text-muted-foreground">{children}</div>
      </div>
    </div>
  );
}

const when = (iso: string | null | undefined, never = 'not yet') => (iso ? fmtLocal(iso) : never);

function Health() {
  const { data } = useSystem();
  const conn = useQuery({
    queryKey: ['message', 'connection'],
    queryFn: async () =>
      (await rpc('connection_status', {})) as Record<string, string | number | null>,
  });
  const [loadedAt] = useState(() => Date.now());
  const c = conn.data ?? {};
  const s = data!.state;
  const lastRunOld =
    !s.last_hourly_run_at || loadedAt - new Date(s.last_hourly_run_at).getTime() > 2 * 3600 * 1000;
  const failedDiscord = Number(c.discord_failed_24h ?? 0);
  const failedEmail = Number(c.email_failed_24h ?? 0);
  return (
    <Section title="Connection health" description="Times are in your time zone.">
      <Row
        status={
          !s.last_hourly_run_at
            ? 'off'
            : lastRunOld || s.last_hourly_status !== 'ok'
              ? 'problem'
              : 'working'
        }
        label="Automatic check"
      >
        {s.last_hourly_run_at
          ? `Last run ${fmtLocal(s.last_hourly_run_at)}${s.last_hourly_status && s.last_hourly_status !== 'ok' ? `, ${s.last_hourly_status}` : ''}. It should run every hour.`
          : 'Not run yet. It starts once the automation service is connected.'}
      </Row>
      <Row
        status={!c.discord_last_sent ? 'off' : failedDiscord > 0 ? 'problem' : 'working'}
        label="Discord"
      >
        Last message sent: {when(c.discord_last_sent as string)}. Failed in the last 24 hours:{' '}
        {failedDiscord}.
      </Row>
      <Row
        status={!c.email_last_sent ? 'off' : failedEmail > 0 ? 'problem' : 'working'}
        label="Email"
      >
        Last email sent: {when(c.email_last_sent as string)}. Failed in the last 24 hours:{' '}
        {failedEmail}.
      </Row>
      <Row status={c.last_action_processed ? 'working' : 'off'} label="Automation service">
        Last request handled: {when(c.last_action_processed as string)}. Messages waiting to send:{' '}
        {c.pending ?? 0}.
      </Row>
      <Row status={s.last_heartbeat_at ? 'working' : 'off'} label="Daily system summary">
        Last sent: {when(s.last_heartbeat_at)}. It goes to the admin alert channel.
      </Row>
    </Section>
  );
}

const FIELDS: { key: keyof Config & string; label: string; hint: string }[] = [
  {
    key: 'scheduling_email',
    label: 'Sender email',
    hint: 'The Gmail account the automation sends from.',
  },
];

function ConfigForm({ config }: { config: Config }) {
  const qc = useQueryClient();
  const [err, setErr] = useState<unknown>(null);
  const [cfg, setCfg] = useState<Record<string, string>>(
    Object.fromEntries(FIELDS.map((f) => [f.key, String(config[f.key] ?? '')])),
  );
  const dirty = FIELDS.some((f) => (cfg[f.key] ?? '') !== String(config[f.key] ?? ''));
  return (
    <Section
      title="Advanced: links"
      description="Technical addresses and IDs the automation needs. Who can sign in is set when the app is installed: company Google accounts only."
    >
      <details>
        <summary className="cursor-pointer text-sm font-medium text-link">Show the links</summary>
        <div className="mt-4">
          <div className="grid gap-x-6 gap-y-4 md:grid-cols-2">
            {FIELDS.map((f) => (
              <Field key={f.key} label={f.label} hint={f.hint}>
                <Input
                  value={cfg[f.key] ?? ''}
                  onChange={(e) => setCfg({ ...cfg, [f.key]: e.target.value })}
                />
              </Field>
            ))}
          </div>
          <dl className="mt-4 space-y-2 text-sm">
            <div>
              <dt className="font-medium">Answer page link</dt>
              <dd className="break-all text-muted-foreground">
                {config.response_base_url ?? 'Not set yet'}
              </dd>
            </div>
            <div>
              <dt className="font-medium">App link</dt>
              <dd className="break-all text-muted-foreground">
                {config.app_base_url ?? 'Not set yet'}
              </dd>
            </div>
          </dl>
          <p className="mt-1 text-xs text-muted-foreground">
            Every button in a message to an instructor opens the answer page link. Both links are
            set by whoever installs the app, so nobody can send instructors to another address from
            here.
          </p>
          <ErrorText error={err} />
          <Button
            className="mt-4"
            disabled={!dirty}
            onClick={async () => {
              setErr(null);
              try {
                await rpc('set_app_config', { p_config: { ...cfg, version: config.version } });
                toast.success('Connection settings saved');
                await qc.invalidateQueries();
              } catch (e) {
                setErr(e);
              }
            }}
          >
            Save changes
          </Button>
        </div>
      </details>
    </Section>
  );
}

/** Private log of errors people ran into in the app (newest first). */
function AppErrors() {
  const team = useTeam();
  const errors = useQuery({
    queryKey: ['app_error'],
    queryFn: async () =>
      check(
        await supabase
          .from('app_error')
          .select('*')
          .order('last_at', { ascending: false })
          .limit(20),
      ),
  });
  const names = new Map((team.data ?? []).map((t) => [t.id, t.name]));
  return (
    <Section
      title="Errors in the app"
      description="Problems people ran into while using the app, newest first. Only the team can see this."
    >
      {errors.isLoading ? (
        <SkeletonRows rows={3} />
      ) : (errors.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No errors so far.</p>
      ) : (
        <ul className="divide-y divide-border text-sm">
          {(errors.data ?? []).map((e) => (
            <li key={e.id} className="py-2">
              <div className="font-medium">{e.message}</div>
              <div className="text-xs text-muted-foreground">
                {fmtLocal(e.last_at)}
                {e.count > 1 ? `, ${e.count} times` : ''}
                {e.page ? `, on ${e.page}` : ''}
                {e.team_member_id ? `, ${names.get(e.team_member_id) ?? 'a team member'}` : ''}
              </div>
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}
