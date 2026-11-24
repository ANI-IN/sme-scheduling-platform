// Live updates (found by the full run of 24 November 2026): a change made after a page read its data but before the
// app was listening was lost for good. When listening starts, whatever was read before is read once more.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { renderHook } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import type { ReactNode } from 'react';

let onStatus: (s: string) => void = () => undefined;
const channel = {
  on: () => channel,
  subscribe: (cb: (s: string) => void) => {
    onStatus = cb;
    return channel;
  },
};
vi.mock('./supabase', () => ({
  supabase: { channel: () => channel, removeChannel: () => Promise.resolve() },
}));
vi.mock('./rpc', () => ({ poke: () => Promise.resolve() }));

const { useLiveUpdates } = await import('./live');

function mount(qc: QueryClient) {
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  );
  return renderHook(() => useLiveUpdates(), { wrapper });
}
const stale = (qc: QueryClient) =>
  qc
    .getQueryCache()
    .getAll()
    .filter((q) => q.state.isInvalidated)
    .map((q) => q.queryKey[0]);

afterEach(() => vi.useRealTimers());

describe('useLiveUpdates', () => {
  it('reads again, within a minute, what was loaded before listening started, then stops checking', () => {
    vi.useFakeTimers();
    const qc = new QueryClient();
    qc.setQueryData(['module', 'd1'], [{ name: 'Old name' }]);
    const h = mount(qc);
    onStatus('SUBSCRIBED');
    vi.advanceTimersByTime(500);
    expect(stale(qc)).toEqual([]);
    vi.advanceTimersByTime(60_000);
    expect(stale(qc)).toContain('module');
    // Then no more checks while connected.
    qc.setQueryData(['module', 'd1'], [{ name: 'Newer' }]);
    vi.advanceTimersByTime(120_000);
    expect(stale(qc)).toEqual([]);
    h.unmount();
  });

  it('reads nothing again when nothing was loaded yet', () => {
    vi.useFakeTimers();
    const qc = new QueryClient();
    const h = mount(qc);
    onStatus('SUBSCRIBED');
    qc.setQueryData(['module', 'd1'], [{ name: 'Name' }]);
    vi.advanceTimersByTime(120_000);
    expect(stale(qc)).toEqual([]);
    h.unmount();
  });

  it('reads again only the first time, not on every later connection without a break', () => {
    vi.useFakeTimers();
    const qc = new QueryClient();
    const h = mount(qc);
    onStatus('SUBSCRIBED');
    qc.setQueryData(['module', 'd1'], [{ name: 'Name' }]);
    onStatus('SUBSCRIBED');
    vi.advanceTimersByTime(120_000);
    expect(stale(qc)).toEqual([]);
    h.unmount();
  });
});
