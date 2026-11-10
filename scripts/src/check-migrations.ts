// Builds a throwaway database from every migration plus the seed, reports the first error with its
// file, and drops it. Nothing touches the app database.
//
//   npm run check-migrations -w scripts
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import pg from 'pg';
import { createScratchDb } from './scratch-db.ts';

const serverUrl =
  process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';

const scratch = await createScratchDb(serverUrl);
const db = new pg.Client({ connectionString: scratch.url });
try {
  await db.connect();
  await db.query(
    readFileSync(join(import.meta.dirname, '..', '..', 'supabase', 'seed.sql'), 'utf8'),
  );
  const r = await db.query<{ n: number }>('select count(*)::int as n from public.module_week');
  console.log(`Migrations and seed apply cleanly (class weeks in seed: ${r.rows[0]!.n}).`);
} catch (e) {
  const err = e as Error & { position?: string };
  console.error(`seed.sql: ${err.message}${err.position ? ` (at character ${err.position})` : ''}`);
  process.exitCode = 1;
} finally {
  await db.end().catch(() => {});
  await scratch.drop();
}
