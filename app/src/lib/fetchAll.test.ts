import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
vi.mock('./env', () => ({ env: {} }));
const { fetchAll, PAGE_ROWS } = await import('./rpc');

describe('fetchAll', () => {
  it('reads every page until one comes back short, so nothing past 1,000 rows is lost', async () => {
    const total = PAGE_ROWS * 2 + 5;
    const asked: [number, number][] = [];
    const rows = await fetchAll(async (from, to) => {
      asked.push([from, to]);
      const data = Array.from(
        { length: Math.max(0, Math.min(to, total - 1) - from + 1) },
        (_, i) => from + i,
      );
      return { data, error: null };
    });
    expect(rows).toHaveLength(total);
    expect(rows.at(-1)).toBe(total - 1);
    expect(asked).toEqual([
      [0, 999],
      [1000, 1999],
      [2000, 2999],
    ]);
  });

  it('asks once when everything fits on one page, and passes on an error', async () => {
    let calls = 0;
    expect(
      await fetchAll(async () => {
        calls += 1;
        return { data: [1, 2, 3], error: null };
      }),
    ).toEqual([1, 2, 3]);
    expect(calls).toBe(1);
    await expect(
      fetchAll(async () => ({ data: null, error: { message: 'permission denied' } })),
    ).rejects.toThrow();
  });
});
