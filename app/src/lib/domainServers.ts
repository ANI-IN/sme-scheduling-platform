/** A domain and its Discord server (decision 350). Archived domains never count as using a server. */

export type ServerDomain = {
  id: string;
  name: string;
  status: string;
  archived_at: string | null;
  discord_server_id: string | null;
};

/** The domains a list shows: archived ones only when asked for. */
export const shownDomains = <D extends ServerDomain>(domains: D[], showArchived: boolean): D[] =>
  domains.filter((d) => showArchived || !d.archived_at);

/** The domains that use this server today. */
export const domainsUsing = <D extends ServerDomain>(domains: D[], serverId: string): D[] =>
  domains.filter((d) => !d.archived_at && d.discord_server_id === serverId);

/**
 * Archived domains that still have a server chosen or approved, with the server names, for "Remove the server from
 * all archived domains". One still set to Live is left out, as the database leaves it alone.
 */
export function archivedToClear(
  domains: ServerDomain[],
  approvals: Map<string, Set<string>>,
  servers: { id: string; name: string }[],
): { id: string; name: string; servers: string }[] {
  return domains.flatMap((d) => {
    if (!d.archived_at || d.status === 'Live') return [];
    const ids = new Set(d.discord_server_id ? [d.discord_server_id] : []);
    for (const [serverId, allowed] of approvals) if (allowed.has(d.id)) ids.add(serverId);
    if (ids.size === 0) return [];
    const names = [...ids].map(
      (id) => servers.find((s) => s.id === id)?.name ?? 'a server not listed yet',
    );
    return [{ id: d.id, name: d.name, servers: names.sort().join(', ') }];
  });
}
