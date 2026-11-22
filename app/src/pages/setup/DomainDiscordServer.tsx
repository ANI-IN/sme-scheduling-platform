// Setup, Domains, a domain's drawer: its Discord server (Release 3, B3, decision 312). Everyone sees the servers an
// admin approved for this domain; admins also see servers the bot is in that are not approved for any domain yet,
// with "Approve for this domain" right there (logged as "Discord server approved"). With none, one clear step.
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { ExternalLink } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useMe } from '@/lib/data';
import { botInviteUrl } from '@/lib/discord';
import { ServerStatus } from '@/components/Discord';
import { useRun } from '@/pages/ClassDrawer';
import { useServerDomains } from '@/pages/settings/DiscordServers';
import { Badge, Button, ErrorText, Field, Notice, Select } from '@/components/ui';

type Domain = {
  id: string;
  name: string;
  discord_server_id: string | null;
  discord_status: string | null;
  discord_problem?: string | null;
};

export function DomainDiscordServer({ domain }: { domain: Domain }) {
  const qc = useQueryClient();
  const isAdmin = !!useMe()?.is_admin;
  const { run, err } = useRun();
  const serverDomains = useServerDomains();
  const servers = useQuery({
    queryKey: ['discord_server'],
    queryFn: async () => check(await supabase.from('discord_server').select('*').order('name')),
  });
  const all = (servers.data ?? []).filter((s) => !s.archived_at);
  const domainsOf = (id: string) => [...(serverDomains.data?.get(id) ?? new Set<string>())];
  const approvedHere = all.filter(
    (s) => s.access === 'Approved' && serverDomains.data?.get(s.id)?.has(domain.id),
  );
  // Waiting for approval, or approved but for no domain yet: an admin can approve it for this domain here.
  const toApprove = isAdmin
    ? all.filter(
        (s) => s.access === 'Waiting' || (s.access === 'Approved' && domainsOf(s.id).length === 0),
      )
    : [];
  const invite = botInviteUrl();
  const refresh = async () => {
    await qc.invalidateQueries({ queryKey: ['domain'] });
    await qc.invalidateQueries({ queryKey: ['discord_server'] });
    await qc.invalidateQueries({ queryKey: ['discord_server_domain'] });
    await qc.invalidateQueries({ queryKey: ['discord_channel'] });
  };

  if (servers.isLoading || serverDomains.isLoading) return null;
  return (
    <div className="space-y-2">
      {approvedHere.length > 0 || domain.discord_server_id ? (
        <Field
          label="Discord server"
          hint="The server whose channels this domain uses. Only servers an admin approved for this domain are listed."
        >
          <Select
            value={domain.discord_server_id ?? ''}
            onChange={(e) =>
              void run(async () => {
                await rpc('set_domain_discord_server', {
                  p_domain_id: domain.id,
                  p_server_id: (e.target.value || null) as string,
                });
                await refresh();
              }, 'Server saved. Checking it now.')
            }
          >
            <option value="">Choose a server</option>
            {domain.discord_server_id &&
              !approvedHere.some((s) => s.id === domain.discord_server_id) && (
                <option value={domain.discord_server_id}>
                  {all.find((s) => s.id === domain.discord_server_id)?.name ??
                    'Server not listed yet'}
                </option>
              )}
            {approvedHere.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
        </Field>
      ) : (
        <div className="text-sm font-medium">Discord server</div>
      )}
      {domain.discord_server_id && (
        <ServerStatus status={domain.discord_status} problem={domain.discord_problem} />
      )}
      {approvedHere.length === 0 && toApprove.length === 0 && (
        <Notice tone="info">
          No Discord server is approved for {domain.name} yet. Add the bot to your Discord server
          with the invite link, then{' '}
          {isAdmin
            ? 'press Refresh servers on Settings, Connections; it then shows here to approve.'
            : 'wait for an admin to approve the server for this domain.'}
          {invite && (
            <>
              {' '}
              <a
                href={invite}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1 font-medium underline"
              >
                Open the invite link <ExternalLink className="h-3.5 w-3.5" aria-hidden />
              </a>
            </>
          )}
        </Notice>
      )}
      {toApprove.length > 0 && (
        <ul className="space-y-2" aria-label="Servers not approved for a domain yet">
          {toApprove.map((s) => (
            <li
              key={s.id}
              className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border p-2 text-sm"
            >
              <span className="flex flex-wrap items-center gap-2">
                <span className="font-medium">{s.name}</span>
                <Badge tone="warning">
                  {s.access === 'Waiting' ? 'Waiting for approval' : 'Not approved for any domain'}
                </Badge>
              </span>
              <Button
                size="sm"
                variant="secondary"
                aria-label={`Approve ${s.name} for this domain`}
                onClick={() =>
                  void run(async () => {
                    await rpc('set_discord_server_access', {
                      p_server_id: s.id,
                      p_access: 'Approved',
                      p_domain_ids: [...domainsOf(s.id), domain.id],
                    });
                    await refresh();
                  }, `${s.name} approved for ${domain.name}`)
                }
              >
                Approve for this domain
              </Button>
            </li>
          ))}
        </ul>
      )}
      <ErrorText error={err} />
    </div>
  );
}
