// Release 3, C15: a change marks only the lists that read the changed table, never the previews.
import { describe, expect, it, vi } from 'vitest';
import { QueryClient } from '@tanstack/react-query';

vi.mock('./supabase', () => ({ supabase: {} }));
vi.mock('./rpc', () => ({ poke: () => Promise.resolve() }));

const { LIVE_TABLES, READERS, refresh, refreshAll } = await import('./live');

function client(keys: unknown[][]) {
  const qc = new QueryClient();
  for (const k of keys) qc.setQueryData(k, 1);
  return qc;
}
const marked = (qc: QueryClient) =>
  qc
    .getQueryCache()
    .getAll()
    .filter((q) => q.state.isInvalidated)
    .map((q) => q.queryKey.join('/'))
    .sort();

describe('refresh', () => {
  it('marks only the lists that read the table', () => {
    const qc = client([
      ['instructor'],
      ['request', 'eligibility', 'w1'],
      ['team_member'],
      ['setting', 'd1'],
      ['domain'],
      ['domain', 'setup-status', 'd1'],
    ]);
    refresh(qc, 'instructor');
    expect(marked(qc)).toEqual(['domain/setup-status/d1', 'instructor', 'request/eligibility/w1']);
  });

  it('names a list of a table that is not live by itself', () => {
    const qc = client([['setting', 'd1'], ['setting', 'Domain', 'd1'], ['holiday']]);
    refresh(qc, 'setting');
    expect(marked(qc)).toEqual(['setting/Domain/d1', 'setting/d1']);
  });

  it('marks every list except the previews when a change reaches everything', () => {
    const qc = client([['module_week', 'd1'], ['break_preview', 'x'], ['bulk_preview'], ['usage']]);
    refreshAll(qc);
    expect(marked(qc)).toEqual(['module_week/d1', 'usage']);
  });

  it('knows which lists read every live table', () => {
    for (const t of LIVE_TABLES) expect(READERS[t].length).toBeGreaterThan(0);
  });
});
