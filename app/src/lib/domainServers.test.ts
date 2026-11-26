import { describe, expect, it } from 'vitest';
import { archivedToClear, domainsUsing, shownDomains } from './domainServers';

const d = (name: string, over: Partial<Parameters<typeof shownDomains>[0][number]> = {}) => ({
  id: name,
  name,
  status: 'Draft',
  archived_at: null as string | null,
  discord_server_id: null as string | null,
  ...over,
});
const old = '2026-11-26T00:00:00Z';
const domains = [
  d('Test', { discord_server_id: 's1' }),
  d('Old chosen', { archived_at: old, discord_server_id: 's1' }),
  d('Old approved', { archived_at: old }),
  d('Old live', { archived_at: old, status: 'Live', discord_server_id: 's1' }),
  d('Old empty', { archived_at: old }),
];
const approvals = new Map([['s1', new Set(['Test', 'Old approved'])]]);
const servers = [{ id: 's1', name: 'Main server' }];

describe('a domain’s Discord server', () => {
  it('hides archived domains until they are asked for', () => {
    expect(shownDomains(domains, false).map((x) => x.name)).toEqual(['Test']);
    expect(shownDomains(domains, true)).toHaveLength(5);
  });

  it('never counts an archived domain as using a server', () => {
    expect(domainsUsing(domains, 's1').map((x) => x.name)).toEqual(['Test']);
  });

  it('lists the archived domains to clear: chosen or approved, never one still set to Live', () => {
    expect(archivedToClear(domains, approvals, servers)).toEqual([
      { id: 'Old chosen', name: 'Old chosen', servers: 'Main server' },
      { id: 'Old approved', name: 'Old approved', servers: 'Main server' },
    ]);
  });

  it('names a server it does not know yet', () => {
    const list = archivedToClear(
      [d('Gone', { archived_at: old, discord_server_id: 's9' })],
      new Map(),
      servers,
    );
    expect(list).toEqual([{ id: 'Gone', name: 'Gone', servers: 'a server not listed yet' }]);
  });
});
