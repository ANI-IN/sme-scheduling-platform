// Release 3, C15: a change marks only the lists that read the changed table, never the previews.
import { describe, expect, it, vi } from 'vitest';
import { QueryClient, QueryObserver } from '@tanstack/react-query';

vi.mock('./supabase', () => ({ supabase: {} }));
vi.mock('./rpc', () => ({ poke: () => Promise.resolve() }));

const { LIVE_TABLES, READERS, refresh, refreshAll, refreshNow } = await import('./live');

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

describe('refreshNow', () => {
  it('finishes only after the marked lists have loaded again', async () => {
    const qc = new QueryClient();
    let release: (v: string[]) => void = () => undefined;
    let calls = 0;
    const queryFn = () => {
      calls++;
      return calls === 1 ? Promise.resolve(['a']) : new Promise<string[]>((r) => (release = r));
    };
    // A list on screen (it has an observer), so marking it loads it again.
    const stop = new QueryObserver(qc, {
      queryKey: ['module_operations', 'm1'],
      queryFn,
    }).subscribe(() => undefined);
    await vi.waitFor(() => expect(qc.getQueryData(['module_operations', 'm1'])).toEqual(['a']));
    let done = false;
    const p = refreshNow(qc, 'module_operations').then(() => (done = true));
    await new Promise((r) => setTimeout(r, 10));
    expect(done).toBe(false);
    release(['a', 'b']);
    await p;
    expect(qc.getQueryData(['module_operations', 'm1'])).toEqual(['a', 'b']);
    stop();
  });
});
