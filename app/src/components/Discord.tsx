import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { check } from '@/lib/rpc';
import {
  personStatus,
  serverStatus,
  type PersonDiscordStatus,
  type ServerDiscordStatus,
} from '@/lib/discord';
import { Badge, Input, Select } from './ui';

/** "Discord found", "Checking Discord", or a problem, with what to do about it underneath. */
export function DiscordStatus({
  status,
  problem,
  compact,
}: {
  status: string | null | undefined;
  problem?: string | null;
  compact?: boolean;
}) {
  const s = personStatus[(status ?? 'NotSet') as PersonDiscordStatus] ?? personStatus.NotSet;
  return (
    <span className="inline-flex flex-col items-start gap-1">
      <Badge tone={s.tone} title={problem ?? undefined}>
        {s.label}
      </Badge>
      {!compact && problem && <span className="text-xs text-danger-strong">{problem}</span>}
    </span>
  );
}

export function ServerStatus({
  status,
  problem,
}: {
  status: string | null | undefined;
  problem?: string | null;
}) {
  const s = serverStatus[(status ?? 'NotSet') as ServerDiscordStatus] ?? serverStatus.NotSet;
  return (
    <span className="inline-flex flex-col items-start gap-1">
      <Badge tone={s.tone}>{s.label}</Badge>
      {problem && <span className="text-xs text-danger-strong">{problem}</span>}
    </span>
  );
}

type Channel = {
  id: string;
  name: string;
  category: string | null;
  position: number;
  server?: string;
};

/**
 * Channels the bot can see in one server ('all' for every server, labelled with the server name),
 * refreshed by the Discord check on Connections.
 */
export function useDiscordChannels(serverId: string | null | undefined) {
  return useQuery({
    queryKey: ['discord_channel', serverId],
    enabled: !!serverId,
    queryFn: async (): Promise<Channel[]> => {
      let q = supabase
        .from('discord_channel')
        .select('id, name, category, position, server_id')
        .order('category', { nullsFirst: true })
        .order('position');
      if (serverId !== 'all') q = q.eq('server_id', serverId!);
      const rows = check(await q);
      if (serverId !== 'all') return rows;
      const servers = check(await supabase.from('discord_server').select('id, name'));
      const name = new Map(servers.map((s) => [s.id, s.name]));
      return rows.map((r) => ({ ...r, server: name.get(r.server_id) ?? 'Unknown server' }));
    },
  });
}

export const channelLabel = (c: Channel) =>
  `${c.server ? `${c.server}: ` : ''}${c.category ? `${c.category} / ` : ''}#${c.name}`;

/**
 * Choose a channel from the server's list. Type to narrow the list: people never paste channel IDs.
 * Channels in a category named like "1-1" are listed first, since instructors' channels live there.
 */
export function ChannelPicker({
  serverId,
  value,
  onChange,
  label,
  allowNone = true,
  noneLabel = 'No channel (direct message instead)',
}: {
  serverId: string | null | undefined;
  value: string | null;
  onChange: (id: string | null) => void;
  label: string;
  allowNone?: boolean;
  noneLabel?: string;
}) {
  const channels = useDiscordChannels(serverId);
  const [q, setQ] = useState('');
  const list = useMemo(() => {
    const all = [...(channels.data ?? [])].sort(
      (a, b) =>
        Number(!/1.?1/.test(a.category ?? '')) - Number(!/1.?1/.test(b.category ?? '')) ||
        (a.category ?? '').localeCompare(b.category ?? '') ||
        a.position - b.position,
    );
    const t = q.trim().toLowerCase().replace(/^#/, '');
    const hit = t ? all.filter((c) => channelLabel(c).toLowerCase().includes(t)) : all;
    // Keep the chosen channel visible even when it does not match the search.
    const chosen = all.find((c) => c.id === value);
    return chosen && !hit.includes(chosen) ? [chosen, ...hit] : hit;
  }, [channels.data, q, value]);

  if (!serverId)
    return (
      <p className="text-sm text-muted-foreground">
        Choose the Discord server of this domain on Settings, Connections first.
      </p>
    );
  return (
    <div className="flex flex-wrap items-center gap-2">
      <Input
        aria-label={`Search channels for ${label}`}
        placeholder="Search channels"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        className="h-9 w-44"
      />
      <Select
        aria-label={label}
        value={value ?? ''}
        onChange={(e) => onChange(e.target.value || null)}
        className="w-64"
      >
        {allowNone && <option value="">{noneLabel}</option>}
        {!allowNone && !value && <option value="">Choose a channel</option>}
        {list.map((c) => (
          <option key={c.id} value={c.id}>
            {channelLabel(c)}
          </option>
        ))}
      </Select>
      {channels.data && channels.data.length === 0 && (
        <span className="text-xs text-muted-foreground">
          No channels yet. Press Check on Settings, Connections.
        </span>
      )}
    </div>
  );
}
