import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useRef, useState } from 'react';
import { toast } from 'sonner';
import { parseChannelInput, suggestChannel } from '@/lib/channels';
import { refresh } from '@/lib/live';
import { check, rpc } from '@/lib/rpc';
import { supabase } from '@/lib/supabase';
import { ChannelPicker, useDiscordChannels } from './Discord';
import { Badge, Button, ErrorText, Input, Notice } from './ui';

type Person = {
  id: string;
  full_name: string;
  discord_username: string | null;
  discord_user_id: string | null;
  discord_status: string | null;
  instructor_channel: {
    domain_id: string;
    channel_id: string;
    channel_name: string | null;
    ready_at?: string | null;
  }[];
};
type DomainLite = { id: string; name: string; discord_server_id: string | null };
type Check = {
  id: string;
  channel_id: string;
  channel_name: string | null;
  status: 'Checking' | 'Ready' | 'Problem';
  problems: string[];
  created_at: string;
};

/**
 * An instructor's own Discord channel in one domain (decision 330): choose it from the list, paste its link or ID,
 * or take the suggested match. The automation checks it in Discord first (the server is approved, the bot can post,
 * the instructor can see it), and only a channel that passes is saved, with one welcome that tags them.
 */
export function InstructorChannel({
  person,
  domain,
  takenIds,
  approvedServerIds,
}: {
  person: Person;
  domain: DomainLite;
  /** Servers an admin approved for this domain: only their channels are listed (decision 331). Undefined while loading. */
  approvedServerIds?: string[];
  /** Channels already used by other instructors in this domain: never suggested. */
  takenIds?: ReadonlySet<string>;
}) {
  const qc = useQueryClient();
  const saved = person.instructor_channel.find((c) => c.domain_id === domain.id);
  const [paste, setPaste] = useState('');
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const channels = useDiscordChannels(domain.discord_server_id);
  const latest = useQuery({
    queryKey: ['channel_check', person.id, domain.id],
    queryFn: async (): Promise<Check | null> =>
      (check(
        await supabase
          .from('channel_check')
          .select('id, channel_id, channel_name, status, problems, created_at')
          .eq('instructor_id', person.id)
          .eq('domain_id', domain.id)
          .order('created_at', { ascending: false })
          .limit(1),
      )[0] as Check | undefined) ?? null,
    // While Discord is being checked, look again every 2 seconds; the result shows by itself.
    refetchInterval: (q) => (q.state.data?.status === 'Checking' ? 2000 : false),
  });
  const status = latest.data?.status;
  const was = useRef(status);
  useEffect(() => {
    if (was.current === 'Checking' && status === 'Ready') {
      toast.success(`#${latest.data?.channel_name ?? 'channel'} is ready for ${person.full_name}`);
      refresh(qc, 'instructor');
    }
    was.current = status;
  }, [status, latest.data?.channel_name, person.full_name, qc]);

  const found = person.discord_status === 'Found' && !!person.discord_user_id;
  const suggestion = useMemo(
    () =>
      found && !(saved?.ready_at)
        ? suggestChannel(
            channels.data ?? [],
            { fullName: person.full_name, username: person.discord_username },
            domain.discord_server_id,
            takenIds,
          )
        : undefined,
    [found, saved?.ready_at, channels.data, person.full_name, person.discord_username, domain.discord_server_id, takenIds],
  );

  async function start(channel: string) {
    setErr(null);
    setBusy(true);
    try {
      await rpc('check_instructor_channel', {
        p_instructor_id: person.id,
        p_domain_id: domain.id,
        p_channel: channel,
      });
      setPaste('');
      await qc.invalidateQueries({ queryKey: ['channel_check', person.id, domain.id] });
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }
  async function remove() {
    setErr(null);
    try {
      await rpc('set_instructor_channel', {
        p_instructor_id: person.id,
        p_domain_id: domain.id,
        p_channel_id: null as unknown as string,
      });
      toast.success('Channel removed: they get direct messages instead');
      refresh(qc, 'instructor');
    } catch (e) {
      setErr(e);
    }
  }
  const pasted = paste.trim() ? parseChannelInput(paste) : null;
  const problemIsCurrent =
    status === 'Problem' &&
    !(saved?.ready_at && latest.data && saved.ready_at > latest.data.created_at) &&
    !(latest.data?.problems.length === 1 && latest.data.problems[0] === 'Replaced by a newer check.');

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
        <span>{domain.name}</span>
        {saved &&
          (saved.ready_at ? (
            <Badge tone="success">Channel ready</Badge>
          ) : (
            <>
              <Badge>Not checked yet</Badge>
              <Button size="sm" variant="ghost" disabled={busy || !found} onClick={() => void start(saved.channel_id)}>
                Check #{saved.channel_name ?? 'channel'}
              </Button>
            </>
          ))}
      </div>
      {approvedServerIds && approvedServerIds.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No Discord server is approved for {domain.name} yet. An admin chooses and approves it on{' '}
          <a className="underline" href="/setup/domains">
            Setup, Domains
          </a>
          .
        </p>
      ) : (
        <>
      {/* Only servers approved for this domain, its own server first (decisions 263 and 331). */}
      <ChannelPicker
        serverId="all"
        onlyServerIds={approvedServerIds}
        preferServerId={domain.discord_server_id}
        label={`Channel of ${person.full_name} in ${domain.name}`}
        value={saved?.channel_id ?? null}
        storedName={saved?.channel_name}
        onChange={(id) => void (id ? start(id) : remove())}
      />
      <div className="flex flex-wrap items-end gap-2">
        <label className="min-w-0 flex-1 text-xs">
          <span className="mb-1 block text-muted-foreground">Or paste a channel link or ID</span>
          <Input
            value={paste}
            onChange={(e) => setPaste(e.target.value)}
            placeholder="https://discord.com/channels/..."
            aria-invalid={!!paste.trim() && !pasted}
          />
        </label>
        <Button size="sm" variant="outline" disabled={!pasted || busy} onClick={() => void start(pasted!)}>
          Check and use
        </Button>
      </div>
      {!!paste.trim() && !pasted && (
        <p className="text-xs text-danger-strong">
          That is not a channel link or ID. In Discord, right click the channel and choose Copy Link.
        </p>
      )}
      {suggestion && status !== 'Checking' && (
        <div className="flex flex-wrap items-center gap-2 text-sm">
          <span>
            Suggested: <strong>#{suggestion.name}</strong>
          </span>
          <Button size="sm" variant="outline" disabled={busy} onClick={() => void start(suggestion.id)}>
            Use #{suggestion.name}
          </Button>
        </div>
      )}
      {status === 'Checking' && (
        <Notice tone="info">
          Checking #{latest.data?.channel_name ?? 'the channel'} in Discord, usually a few seconds. The result shows
          here by itself.
        </Notice>
      )}
      {problemIsCurrent && (
        <Notice tone="warning">
          <p className="font-medium">#{latest.data?.channel_name ?? 'The channel'} was not saved as their channel</p>
          <ul className="mt-1 list-disc space-y-1 pl-5">
            {latest.data!.problems.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
        </Notice>
      )}
        </>
      )}
      <ErrorText error={err} />
    </div>
  );
}
