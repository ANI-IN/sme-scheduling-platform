import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { CheckCircle2, CircleAlert, PlugZap } from 'lucide-react';
import { Link } from 'react-router-dom';
import { check, poke, rpc } from '@/lib/rpc';
import { supabase } from '@/lib/supabase';
import { useMe, useSystem, useTeam } from '@/lib/data';
import { fmtLocal } from '@/lib/time';
import { channelStatus, fixFor, type Status } from '@/lib/connection';
import { PauseAllSection } from '@/components/PauseAll';
import { UsageSection } from '@/components/UsageSection';
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
  const isAdmin = !!useMe()?.is_admin;
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
          {isAdmin && <UsageSection />}
          <AppErrors />
        </>
      )}
    </div>
  );
}

const STATUS: Record<Status, { label: string; tone: 'success' | 'neutral' | 'danger' | 'accent' }> =
  {
    working: { label: 'Working', tone: 'success' },
    ready: { label: 'Ready, no messages yet', tone: 'accent' },
    off: { label: 'Not set up', tone: 'neutral' },
    problem: { label: 'Problem', tone: 'danger' },
  };

function SendTest({ channel }: { channel: 'Discord' | 'Email' }) {
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  return (
    <Button
      variant="secondary"
      size="sm"
      loading={busy}
      onClick={async () => {
        setBusy(true);
        try {
          check(await supabase.rpc('send_connection_test', { p_channel: channel }));
          toast.success(
            channel === 'Discord'
              ? 'Test sent to the admin alert channel. It arrives within a minute.'
              : 'Test email sent to your own address. It arrives within a minute.',
          );
          await poke();
          await qc.invalidateQueries({ queryKey: ['message', 'connection'] });
        } catch (e) {
          toast.error(e instanceof Error ? e.message : String(e));
        } finally {
          setBusy(false);
        }
      }}
    >
      Send a test
    </Button>
  );
}

function Row({
  status,
  label,
  action,
  children,
}: {
  status: Status;
  label: string;
  action?: React.ReactNode;
  children: React.ReactNode;
}) {
  const Icon =
    status === 'working' || status === 'ready'
      ? CheckCircle2
      : status === 'problem'
        ? CircleAlert
        : PlugZap;
  return (
    <div className="flex items-start gap-3 border-b border-border py-3 last:border-0">
      <Icon
        className={cn(
          'mt-0.5 h-5 w-5 shrink-0',
          status === 'working' || status === 'ready'
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
      {action && <div className="shrink-0">{action}</div>}
    </div>
  );
}

const when = (iso: string | null | undefined, never = 'not yet') => (iso ? fmtLocal(iso) : never);

function Health() {
  const { data } = useSystem();
  const isAdmin = !!useMe()?.is_admin;
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
  const discord = channelStatus(
    !!c.discord_ready,
    c.discord_last_sent as string | null,
    c.discord_last_failed as string | null,
  );
  const email = channelStatus(
    !!c.email_ready,
    c.email_last_sent as string | null,
    c.email_last_failed as string | null,
  );
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
      <Row status={discord} label="Discord" action={isAdmin && <SendTest channel="Discord" />}>
        {discord === 'off'
          ? c.discord_has_server
            ? 'Choose the admin alert channel under Discord servers below.'
            : 'Add the bot to your Discord server with the invite link below, then approve the server.'
          : discord === 'ready'
            ? 'Set up. Nothing has been sent yet, so there is nothing to check.'
            : `Last message sent: ${when(c.discord_last_sent as string)}. Failed in the last 24 hours: ${failedDiscord}.`}
        {discord === 'problem' && (
          <span className="mt-1 block text-foreground">
            The last attempt failed {when(c.discord_last_failed as string)}
            {c.discord_last_error ? `: ${String(c.discord_last_error)}` : ''}.{' '}
            {fixFor('Discord', c.discord_last_error as string | null)}
          </span>
        )}
      </Row>
      <Row status={email} label="Email" action={isAdmin && <SendTest channel="Email" />}>
        {email === 'off'
          ? 'Fill in the sender email under Advanced: links below.'
          : email === 'ready'
            ? 'Set up. Nothing has been sent yet, so there is nothing to check.'
            : `Last email sent: ${when(c.email_last_sent as string)}. Failed in the last 24 hours: ${failedEmail}.`}
        {email === 'problem' && (
          <span className="mt-1 block text-foreground">
            The last attempt failed {when(c.email_last_failed as string)}
            {c.email_last_error ? `: ${String(c.email_last_error)}` : ''}.{' '}
            {fixFor('Email', c.email_last_error as string | null)}
          </span>
        )}
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
  const isAdmin = !!useMe()?.is_admin;
  const [err, setErr] = useState<unknown>(null);
  const [cfg, setCfg] = useState<Record<string, string>>(
    Object.fromEntries(FIELDS.map((f) => [f.key, String(config[f.key] ?? '')])),
  );
  const dirty = FIELDS.some((f) => (cfg[f.key] ?? '') !== String(config[f.key] ?? ''));
  return (
    <Section
      title="Advanced: links"
      description="The sender email and the links the automation needs. Who can sign in is set when the app is installed: company Google accounts only."
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
          {!isAdmin && (
            <p className="mt-4 text-sm text-muted-foreground">Only an admin can change these.</p>
          )}
          <Button
            className="mt-4"
            disabled={!dirty || !isAdmin}
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
