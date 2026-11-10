import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { CheckCircle2, CircleAlert, CircleDashed } from 'lucide-react';
import { check, poke, rpc } from '@/lib/rpc';
import { supabase } from '@/lib/supabase';
import { useSystem, useTeam } from '@/lib/data';
import { fmtLocal } from '@/lib/time';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
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
        Usually set up once by the admin. Step by step instructions are in docs/SETUP.md.
      </Notice>
      {isLoading || !data ? (
        <SkeletonRows rows={6} />
      ) : (
        <>
          <Health />
          <ConfigForm key={data.config.version} config={data.config} />
          <PauseAll />
          <AppErrors />
        </>
      )}
    </div>
  );
}

function Row({
  ok,
  label,
  children,
}: {
  ok: boolean | null;
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-start gap-3 border-b border-border py-2.5 last:border-0">
      {ok === null ? (
        <CircleDashed className="mt-0.5 h-4 w-4 text-muted-foreground" aria-label="Not used yet" />
      ) : ok ? (
        <CheckCircle2 className="mt-0.5 h-4 w-4 text-success-strong" aria-label="Working" />
      ) : (
        <CircleAlert className="mt-0.5 h-4 w-4 text-danger-strong" aria-label="Needs a look" />
      )}
      <div className="min-w-0 flex-1">
        <div className="text-sm font-medium">{label}</div>
        <div className="text-sm text-muted-foreground">{children}</div>
      </div>
    </div>
  );
}

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
  return (
    <Section title="Connection health" description="Times are in your time zone.">
      <Row
        ok={s.last_hourly_run_at ? !lastRunOld && s.last_hourly_status === 'ok' : null}
        label="Automatic check"
      >
        Last run {fmtLocal(s.last_hourly_run_at)}
        {s.last_hourly_status && s.last_hourly_status !== 'ok' && `, ${s.last_hourly_status}`}. It
        should run every hour.
      </Row>
      <Row
        ok={c.discord_last_sent ? Number(c.discord_failed_24h ?? 0) === 0 : null}
        label="Discord"
      >
        Last message sent {fmtLocal(c.discord_last_sent as string)}. Failed in the last 24 hours:{' '}
        {c.discord_failed_24h ?? 0}.
      </Row>
      <Row
        ok={c.email_last_sent ? Number(c.email_failed_24h ?? 0) === 0 : null}
        label="Email (Gmail)"
      >
        Last email sent {fmtLocal(c.email_last_sent as string)}. Failed in the last 24 hours:{' '}
        {c.email_failed_24h ?? 0}.
      </Row>
      <Row ok={c.last_action_processed ? true : null} label="Automation service (n8n)">
        Last request handled {fmtLocal(c.last_action_processed as string)}. Messages waiting to
        send: {c.pending ?? 0}.
      </Row>
      <Row ok={s.last_heartbeat_at ? true : null} label="Daily system summary">
        Last sent {fmtLocal(s.last_heartbeat_at)} to the admin alert channel.
      </Row>
    </Section>
  );
}

const FIELDS: { key: keyof Config & string; label: string; hint: string }[] = [
  {
    key: 'discord_guild_id',
    label: 'Company Discord server ID',
    hint: 'Instructor channel links must be in this server. Right click the server name, then Copy Server ID.',
  },
  {
    key: 'admin_discord_channel_id',
    label: 'Admin alert channel ID',
    hint: 'Problems and the daily system summary are posted here.',
  },
  {
    key: 'scheduling_email',
    label: 'Sender email',
    hint: 'The Gmail account the automation sends from.',
  },
  {
    key: 'response_base_url',
    label: 'Response page link',
    hint: 'The production link of the n8n "Response handler" workflow (WF2), for example https://your-n8n/webhook/respond. Every button in a message to an instructor uses it.',
  },
  {
    key: 'app_base_url',
    label: 'App link',
    hint: 'The address of this app. Team alerts link to it.',
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
      title="Links and IDs"
      description="Addresses and IDs the automation needs. Who can sign in is set when the app is installed: company Google accounts only."
    >
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
    </Section>
  );
}

function PauseAll() {
  const { data } = useSystem();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [err, setErr] = useState<unknown>(null);
  const on = data!.state.outreach_enabled;
  return (
    <Section
      tone="danger"
      title="Pause all messages"
      description="Stops every message to instructors in every domain, for example during an incident. Team alerts continue."
      actions={
        <Badge tone={on ? 'success' : 'danger'}>
          {on ? 'Messages are on' : 'Messages are paused'}
        </Badge>
      }
    >
      {!on && (
        <p className="mb-3 text-sm text-muted-foreground">
          Paused since {fmtLocal(data!.state.kill_switch_changed_at)}. Nothing is lost: waiting
          messages go out when you turn messages back on.
        </p>
      )}
      <Button
        variant={on ? 'destructive' : 'primary'}
        onClick={async () => {
          if (
            await confirm({
              title: on ? 'Pause all messages to instructors?' : 'Turn messages back on?',
              body: on
                ? 'No instructor will be messaged in any domain until you turn messages back on. Requests stop moving on. Team alerts continue.'
                : 'Messages to instructors start again at the next automatic check.',
              danger: on,
              confirmLabel: on ? 'Pause all messages' : 'Turn messages back on',
            })
          ) {
            setErr(null);
            try {
              await rpc('set_kill_switch', { p_outreach_enabled: !on });
              await poke();
              toast.success(on ? 'All messages are paused' : 'Messages are on again');
              await qc.invalidateQueries();
            } catch (e) {
              setErr(e);
            }
          }
        }}
      >
        {on ? 'Pause all messages' : 'Turn messages back on'}
      </Button>
      <ErrorText error={err} />
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
