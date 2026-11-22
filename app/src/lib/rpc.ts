import { supabase } from './supabase';
import { env } from './env';
import type { Database } from './database.types';

type Fns = Database['public']['Functions'];

/** Turn database errors into the plain message ops should see. */
export function friendlyError(e: unknown): string {
  const err = e as { message?: string; code?: string };
  const msg = err?.message ?? String(e);
  if (err?.code === '40001' || msg.includes('This changed'))
    return 'Someone else saved this after you opened it. Reload the page to see their changes, then try again.';
  if (msg.includes('module_name_per_domain'))
    return 'A module with this name already exists in this domain.';
  if (msg.includes('team_member_email')) return 'A team member with this email already exists.';
  if (msg.includes('holiday_date_key')) return 'That date is already in the holiday list.';
  if (msg.includes('domain_name_uq')) return 'A domain with this name already exists.';
  if (msg.includes('violates foreign key'))
    return 'It is still in use, so it can’t be deleted. Archive it or stop using it instead.';
  if (msg.includes('booking_slot_no_overlap'))
    return 'That instructor is already teaching at that time.';
  if (msg.includes('domain_test_mode_needs_targets'))
    return 'Set a test Discord channel and a test email before turning on test mode.';
  return msg;
}

/** Call a database function; throws an Error with a friendly message. */
export async function rpc<K extends keyof Fns>(
  fn: K,
  args: Fns[K]['Args'],
): Promise<Fns[K]['Returns']> {
  const { data, error } = await supabase.rpc(fn, args as never);
  if (error) throw new Error(friendlyError(error));
  return data as Fns[K]['Returns'];
}

/** Throw a friendly error from a supabase-js response. */
export function check<R extends { data: unknown; error: unknown }>(res: R): NonNullable<R['data']> {
  if (res.error) throw new Error(friendlyError(res.error));
  return res.data as NonNullable<R['data']>;
}

/** The database returns at most this many rows per request (supabase/config.toml, max_rows). */
export const PAGE_ROWS = 1000;

/**
 * Read every row of a list that can grow past one page (Release 3, M6): asks for rows 0 to 999, 1000 to 1999 and
 * so on until a page comes back short, so nothing is silently left out. `page` builds the same ordered query
 * for a range of rows.
 */
export async function fetchAll<T>(
  page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: unknown }>,
): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += PAGE_ROWS) {
    const rows = check(await page(from, from + PAGE_ROWS - 1));
    out.push(...rows);
    if (rows.length < PAGE_ROWS) return out;
  }
}

/** Ask n8n (WF4) to deliver queued messages now. Carries no data; safe to call often. */
export async function poke(): Promise<void> {
  if (!env.pokeUrl) return;
  try {
    await fetch(env.pokeUrl, {
      method: 'POST',
      // Normal CORS request: 'no-cors' would silently drop the x-poke-key header.
      headers: env.pokeKey ? { 'x-poke-key': env.pokeKey } : undefined,
    });
  } catch {
    // n8n's 5-minute safety run delivers anyway.
  }
}
