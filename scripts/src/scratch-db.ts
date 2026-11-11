// A throwaway database for scripts that must commit data (for example the two-connection race).
// It is created next to the app database on the same local Postgres server, built from the
// migrations, and dropped afterwards, so nothing is ever written to the app's database.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import pg from 'pg';

const MIGRATIONS = join(import.meta.dirname, '..', '..', 'supabase', 'migrations');

// Supabase normally provides these in its own `auth` schema; the scratch database needs the same
// signatures so the migrations and RLS policies compile.
const AUTH_STUB = `
create schema if not exists auth;
create schema if not exists extensions;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), auth.jwt() ->> 'role') $$;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
create table if not exists auth.users (id uuid primary key, instance_id uuid, aud text, role text, email text unique);
create table if not exists auth.identities (id uuid primary key default gen_random_uuid(), provider_id text not null,
  user_id uuid not null references auth.users (id) on delete cascade, identity_data jsonb not null, provider text not null,
  last_sign_in_at timestamptz);
create table if not exists auth.sessions (id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade);
grant usage on schema auth, extensions to anon, authenticated, service_role;
`;

export type Scratch = { url: string; drop: () => Promise<void> };

export async function createScratchDb(serverUrl: string): Promise<Scratch> {
  const name = `sme_scratch_${process.pid}_${Date.now() % 100000}`;
  const admin = new pg.Client({ connectionString: serverUrl });
  await admin.connect();
  await admin.query(`create database ${name}`);
  const url = serverUrl.replace(/\/[^/?]+(\?|$)/, `/${name}$1`);
  const db = new pg.Client({ connectionString: url });
  try {
    await db.connect();
    await db.query(AUTH_STUB);
    for (const f of readdirSync(MIGRATIONS)
      .filter((x) => x.endsWith('.sql'))
      .sort()) {
      try {
        await db.query(readFileSync(join(MIGRATIONS, f), 'utf8'));
      } catch (e) {
        const err = e as Error & { position?: string };
        throw new Error(
          `${f}: ${err.message}${err.position ? ` (at character ${err.position})` : ''}`,
        );
      }
    }
  } catch (e) {
    await db.end().catch(() => {});
    await admin.query(`drop database if exists ${name} with (force)`);
    await admin.end();
    throw e;
  } finally {
    await db.end();
  }
  return {
    url,
    drop: async () => {
      await admin.query(`drop database if exists ${name} with (force)`);
      await admin.end();
    },
  };
}
