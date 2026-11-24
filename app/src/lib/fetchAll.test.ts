import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
vi.mock('./env', () => ({ env: {} }));
const { fetchAll, fetchAllParallel, fetchByIds, IDS_PER_REQUEST, PAGE_ROWS } =
  await import('./rpc');

describe('fetchAll', () => {
  it('reads every page until one comes back short, so nothing past 1,000 rows is lost, three pages at a time after the first', async () => {
    const total = PAGE_ROWS * 2 + 5;
    const asked: [number, number][] = [];
    let inFlight = 0;
    let most = 0;
    const rows = await fetchAll(async (from, to) => {
      asked.push([from, to]);
      inFlight += 1;
      most = Math.max(most, inFlight);
      await Promise.resolve();
      inFlight -= 1;
      const data = Array.from(
        { length: Math.max(0, Math.min(to, total - 1) - from + 1) },
        (_, i) => from + i,
      );
      return { data, error: null };
    });
    expect(rows).toHaveLength(total);
    expect(rows.at(-1)).toBe(total - 1);
    // The first page alone, then the next three together (decision 334).
    expect(asked).toEqual([
      [0, 999],
      [1000, 1999],
      [2000, 2999],
      [3000, 3999],
    ]);
    expect(most).toBe(3);
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

  it('sends a long list of IDs 100 at a time and joins the results', async () => {
    const ids = Array.from({ length: IDS_PER_REQUEST * 2 + 30 }, (_, i) => `id${i}`);
    const sizes: number[] = [];
    const rows = await fetchByIds(ids, async (group) => {
      sizes.push(group.length);
      return { data: group.map((id) => ({ id })), error: null };
    });
    expect(sizes).toEqual([100, 100, 30]);
    expect(rows.map((r) => r.id)).toEqual(ids);
  });

  it('asks nothing for no IDs, and passes on an error', async () => {
    let calls = 0;
    expect(
      await fetchByIds([], async () => {
        calls += 1;
        return { data: [], error: null };
      }),
    ).toEqual([]);
    expect(calls).toBe(0);
    await expect(
      fetchByIds(['a'], async () => ({ data: null, error: { message: 'permission denied' } })),
    ).rejects.toThrow();
  });
});

describe('fetchAllParallel', () => {
  it('asks four pages at once from the start and stops at the first short page, keeping the order', async () => {
    const total = 470;
    const asked: [number, number][] = [];
    let inFlight = 0;
    let most = 0;
    const rows = await fetchAllParallel(async (from, to) => {
      asked.push([from, to]);
      inFlight += 1;
      most = Math.max(most, inFlight);
      await Promise.resolve();
      inFlight -= 1;
      const data = Array.from(
        { length: Math.max(0, Math.min(to, total - 1) - from + 1) },
        (_, i) => from + i,
      );
      return { data, error: null };
    });
    expect(rows).toEqual(Array.from({ length: total }, (_, i) => i));
    expect(asked).toEqual([
      [0, 149],
      [150, 299],
      [300, 449],
      [450, 599],
    ]);
    expect(most).toBe(4);
  });

  it('goes on to the next four pages when all four are full', async () => {
    const total = 600;
    let calls = 0;
    const rows = await fetchAllParallel(async (from, to) => {
      calls++;
      const data = Array.from(
        { length: Math.max(0, Math.min(to, total - 1) - from + 1) },
        (_, i) => from + i,
      );
      return { data, error: null };
    });
    expect(rows).toHaveLength(600);
    expect(calls).toBe(8);
  });

  it('passes on an error', async () => {
    await expect(
      fetchAllParallel(async () => ({ data: null, error: { message: 'boom' } })),
    ).rejects.toBeTruthy();
  });
});
