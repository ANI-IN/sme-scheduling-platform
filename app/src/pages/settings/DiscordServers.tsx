import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { ExternalLink, RefreshCw } from 'lucide-react';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomains, useSystem } from '@/lib/data';
import { ago } from '@/lib/time';
import { botInviteUrl } from '@/lib/discord';
import { ChannelPicker, ServerStatus } from '@/components/Discord';
import { useRun } from '@/pages/ClassDrawer';
import { ArchiveButton, DeleteButton } from '@/components/Lifecycle';
import {
  Badge,
  Button,
  Checkbox,
  ErrorText,
  Field,
  Input,
  Notice,
  Section,
  Select,
  tableWrap,
  td,
  th,
  thead,
  trow,
} from '@/components/ui';

/**
 * Discord servers: each domain uses an existing server. The bot is invited with an invite link,
 * then the app lists the servers the bot is in and the channels it can see. Nothing is created in
 * Discord.
 */
export function DiscordServers() {
  const qc = useQueryClient();
  const domains = useDomains();
  const system = useSystem();
  const config = system.data?.config;
  const { run, err } = useRun();
  const invite = botInviteUrl();
  const servers = useQuery({
    queryKey: ['discord_server'],
    queryFn: async () => check(await supabase.from('discord_server').select('*').order('name')),
  });
  const counts = useQuery({
    queryKey: ['discord_channel', 'counts'],
    queryFn: async () => {
      const rows = check(await supabase.from('discord_channel').select('server_id'));
      const m = new Map<string, number>();
      for (const r of rows) m.set(r.server_id, (m.get(r.server_id) ?? 0) + 1);
      return m;
    },
  });
  const checking = (domains.data ?? []).some((d) => d.discord_status === 'Checking');
  // While a check is running, look again every few seconds.
  useQuery({
    queryKey: ['discord_poll'],
    enabled: checking,
    refetchInterval: 5000,
    queryFn: async () => {
      await qc.invalidateQueries({ queryKey: ['domain'] });
      await qc.invalidateQueries({ queryKey: ['discord_server'] });
      await qc.invalidateQueries({ queryKey: ['discord_channel'] });
      return Date.now();
    },
  });
  const lastRefresh = (servers.data ?? [])
    .map((s) => s.refreshed_at)
    .sort()
    .pop();

  return (
    <Section
      title="Discord servers"
      description="Each domain uses one Discord server you already have. The app never creates servers or channels."
    >
      <ol className="mb-4 list-decimal space-y-1.5 pl-5 text-sm">
        <li>
          Add the bot to the server of each domain with the invite link. It asks only for View
          Channels, Send Messages, Embed Links and Read Message History.{' '}
          {invite ? (
            <a
              href={invite}
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1 font-medium text-link hover:underline"
            >
              Open the invite link <ExternalLink className="h-3.5 w-3.5" aria-hidden />
            </a>
          ) : (
            <span className="text-muted-foreground">
              The invite link appears once whoever looks after the app sets VITE_DISCORD_CLIENT_ID
              (the bot&apos;s application ID).
            </span>
          )}
        </li>
        <li>
          In Discord, open the category where instructors have their own channels (usually
          &quot;1-1&quot;), choose Edit Category, Permissions, and allow the bot&apos;s role to View
          Channels, Send Messages, Embed Links and Read Message History.
        </li>
        <li>
          In the Discord Developer Portal, open the bot and turn on Server Members Intent (to find
          people by username) and Message Content Intent (to read replies).
        </li>
        <li>
          Press <strong>Refresh servers</strong>, choose the server of each domain below, and wait
          for Ready.
        </li>
      </ol>

      <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
        <Button
          variant="secondary"
          size="sm"
          onClick={() =>
            run(
              () => rpc('check_discord', { p_kind: 'servers' }),
              'Asked the bot for its servers. This takes up to a minute.',
            )
          }
        >
          <RefreshCw className="h-4 w-4" aria-hidden /> Refresh servers
        </Button>
        <span className="text-muted-foreground">
          {servers.data?.length
            ? `The bot is in ${servers.data.length} server${servers.data.length === 1 ? '' : 's'}${
                lastRefresh ? `, checked ${ago(lastRefresh)} ago` : ''
              }.`
            : 'No servers yet: add the bot, then press Refresh servers.'}
        </span>
      </div>

      <ServerList />

      <h3 className="mb-2 text-sm font-semibold">Server of each domain</h3>
      <div className={tableWrap}>
        <table className="w-full">
          <thead className={thead}>
            <tr>
              <th className={th}>Domain</th>
              <th className={th}>Discord server</th>
              <th className={th}>Status</th>
              <th className={th}>
                <span className="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {(domains.data ?? []).map((d) => (
              <tr key={d.id} className={trow}>
                <td className={`${td} font-medium`}>{d.name}</td>
                <td className={td}>
                  <Select
                    aria-label={`Discord server for ${d.name}`}
                    value={d.discord_server_id ?? ''}
                    className="w-56"
                    onChange={(e) =>
                      run(
                        () =>
                          rpc('set_domain_discord_server', {
                            p_domain_id: d.id,
                            p_server_id: (e.target.value || null) as string,
                          }),
                        'Server saved. Checking it now.',
                      )
                    }
                  >
                    <option value="">Choose a server</option>
                    {d.discord_server_id &&
                      !(servers.data ?? []).some((s) => s.id === d.discord_server_id) && (
                        <option value={d.discord_server_id}>Server not listed yet</option>
                      )}
                    {(servers.data ?? [])
                      .filter((s) => !s.archived_at || s.id === d.discord_server_id)
                      .map((s) => (
                        <option key={s.id} value={s.id}>
                          {s.name}
                        </option>
                      ))}
                  </Select>
                  {d.discord_server_id && counts.data && (
                    <div className="mt-1 text-xs text-muted-foreground">
                      {counts.data.get(d.discord_server_id) ?? 0} channels the bot can see
                    </div>
                  )}
                </td>
                <td className={td}>
                  <ServerStatus status={d.discord_status} problem={d.discord_problem} />
                </td>
                <td className={`${td} text-right`}>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={!d.discord_server_id || d.discord_status === 'Checking'}
                    onClick={() =>
                      run(async () => {
                        await rpc('check_discord', { p_kind: 'server', p_id: d.id });
                        toast.info(
                          'Checking the server and its channels. This takes up to a minute.',
                        );
                      })
                    }
                  >
                    Check
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {config && (
        <div className="mt-4 space-y-1">
          <div className="text-sm font-medium">Admin alert channel</div>
          <p className="text-xs text-muted-foreground">
            Problems with the app and the daily system summary are posted here.
          </p>
          <ChannelPicker
            serverId="all"
            label="Admin alert channel"
            value={config.admin_discord_channel_id ?? null}
            noneLabel="No admin channel"
            onChange={(id) =>
              run(
                () =>
                  rpc('set_app_config', {
                    p_config: { admin_discord_channel_id: id ?? '', version: config.version },
                  }),
                'Admin alert channel saved',
              )
            }
          />
        </div>
      )}
      {checking && (
        <Notice tone="info">
          The automation checks Discord as soon as you ask, and again every few minutes. This page
          updates by itself.
        </Notice>
      )}
      <ErrorText error={err} />
    </Section>
  );
}

/**
 * Every server the bot is in, with its own status (decisions 261, 262). The automation checks servers a few
 * at a time and keeps the result for a day, so a bot in 15 or more servers never hits Discord's limits.
 */
function ServerList() {
  const domains = useDomains();
  const { run, err } = useRun();
  const [q, setQ] = useState('');
  const [showArchived, setShowArchived] = useState(false);
  const servers = useQuery({
    queryKey: ['discord_server'],
    refetchInterval: (query) =>
      (query.state.data ?? []).some((s) => s.status === 'Checking') ? 5000 : false,
    queryFn: async () => check(await supabase.from('discord_server').select('*').order('name')),
  });
  const counts = useQuery({
    queryKey: ['discord_channel', 'counts'],
    queryFn: async () => {
      const rows = check(await supabase.from('discord_channel').select('server_id'));
      const m = new Map<string, number>();
      for (const r of rows) m.set(r.server_id, (m.get(r.server_id) ?? 0) + 1);
      return m;
    },
  });
  // Natural order: "Program server 2" before "Program server 10".
  const all = [...(servers.data ?? [])].sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' }),
  );
  const archivedCount = all.filter((s) => s.archived_at).length;
  const t = q.trim().toLowerCase();
  const shown = all.filter(
    (s) =>
      (showArchived || !s.archived_at) &&
      (!t || s.name.toLowerCase().includes(t) || s.id.includes(t)),
  );
  const usedBy = (id: string) =>
    (domains.data ?? [])
      .filter((d) => d.discord_server_id === id)
      .map((d) => d.name)
      .join(', ');
  const checking = all.filter((s) => s.status === 'Checking').length;
  return (
    <div className="mb-6 space-y-3">
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Search servers">
          <Input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Name or server ID"
            className="w-64"
          />
        </Field>
        {archivedCount > 0 && (
          <Checkbox
            label={`Show archived servers (${archivedCount})`}
            checked={showArchived}
            onChange={setShowArchived}
          />
        )}
      </div>
      {checking > 0 && (
        <p className="text-sm text-muted-foreground">
          Checking {checking} server{checking === 1 ? '' : 's'}. The automation checks three a
          minute, so Discord never slows the bot down. This list updates by itself.
        </p>
      )}
      {all.length > 0 && shown.length === 0 ? (
        <p className="text-sm text-muted-foreground">No server matches your search.</p>
      ) : shown.length > 0 ? (
        <div className={tableWrap}>
          <table className="w-full">
            <thead className={thead}>
              <tr>
                <th className={th}>Server</th>
                <th className={th}>Status</th>
                <th className={th}>Channels</th>
                <th className={th}>Used by</th>
                <th className={th}>
                  <span className="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {shown.map((s) => (
                <tr key={s.id} className={trow}>
                  <td className={td}>
                    <div className="font-medium">{s.name}</div>
                    <div className="text-xs text-muted-foreground">
                      {s.checked_at ? `Checked ${ago(s.checked_at)} ago` : 'Not checked yet'}
                    </div>
                    {s.archived_at && <Badge tone="neutral">Archived</Badge>}
                  </td>
                  <td className={td}>
                    <ServerStatus status={s.status} problem={s.problem} />
                  </td>
                  <td className={td}>{counts.data?.get(s.id) ?? 0}</td>
                  <td className={td}>
                    {usedBy(s.id) || <span className="text-muted-foreground">No domain</span>}
                  </td>
                  <td className={td}>
                    <div className="flex flex-wrap justify-end gap-1.5">
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={s.status === 'Checking'}
                        onClick={() =>
                          run(
                            () => rpc('check_discord_server', { p_server_id: s.id }),
                            `Checking ${s.name}. This takes up to a minute.`,
                          )
                        }
                      >
                        Check again
                      </Button>
                      <ArchiveButton
                        kind="discord_server"
                        id={s.id}
                        name={s.name}
                        archived={!!s.archived_at}
                      />
                      <DeleteButton kind="discord_server" id={s.id} />
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
      <ErrorText error={err} />
    </div>
  );
}
