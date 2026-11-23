// Proves that every rollback file really undoes its migration (Release 3, docs/PLAN_RELEASE_3.md section 4).
//
//   npm run check-rollbacks -w scripts
//
// For each `supabase/rollback/<migration>.sql`, in a throwaway database built from the migrations before it:
//   1. fingerprint the schema (functions with their code, settings and grants, tables, columns, constraints,
//      indexes, policies, triggers, views, tables in a publication and scheduled jobs);
//   2. apply the migration, fingerprint again;
//   3. apply the rollback: the fingerprint must equal step 1;
//   4. apply the migration again: the fingerprint must equal step 2.
// Every Release 3 migration (from 20261122) must have a rollback file. Nothing touches the app database.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import pg from 'pg';
import { createScratchDb } from './scratch-db.ts';

const ROOT = join(import.meta.dirname, '..', '..', 'supabase');
const MIGRATIONS = join(ROOT, 'migrations');
const ROLLBACK = join(ROOT, 'rollback');
const FIRST_WITH_ROLLBACK = '20261122';
const serverUrl =
  process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';

/** One line per schema object: "kind name: md5 of its definition". */
const FINGERPRINT = `
with objs as (
  select 'function' k, n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' nm,
         md5(pg_get_functiondef(p.oid) || coalesce(p.proacl::text, '')) d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prokind in ('f', 'p')
  union all
  -- Not the column's position: Postgres always puts a column that is dropped and added again at the end, and the
  -- order does not change what the table holds or how it behaves.
  select 'column', table_schema || '.' || table_name || '.' || column_name,
         md5(concat_ws('|', data_type, udt_name, is_nullable, column_default))
    from information_schema.columns where table_schema in ('public', 'private')
  union all
  select 'constraint', n.nspname || '.' || c.relname || '.' || k.conname, md5(pg_get_constraintdef(k.oid))
    from pg_constraint k join pg_class c on c.oid = k.conrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'private')
  union all
  select 'index', schemaname || '.' || indexname, md5(indexdef) from pg_indexes where schemaname in ('public', 'private')
  union all
  select 'policy', schemaname || '.' || tablename || '.' || policyname,
         md5(concat_ws('|', cmd, roles::text, qual, with_check))
    from pg_policies where schemaname in ('public', 'private')
  union all
  select 'trigger', n.nspname || '.' || c.relname || '.' || t.tgname, md5(pg_get_triggerdef(t.oid))
    from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
   where not t.tgisinternal and n.nspname in ('public', 'private')
  union all
  -- Which tables Realtime sends changes for.
  select 'publication table', pubname || '.' || schemaname || '.' || tablename, md5(pubname)
    from pg_publication_tables where schemaname in ('public', 'private')
  union all
  select 'view', schemaname || '.' || viewname, md5(definition) from pg_views where schemaname in ('public', 'private')
  union all
  select 'table grant', n.nspname || '.' || c.relname, md5(coalesce(c.relacl::text, '') || c.relrowsecurity::text)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'private') and c.relkind in ('r', 'v', 'p')
)
select k || ' ' || nm || ': ' || d as line from objs order by k, nm`;

const JOBS = `select 'job ' || jobname || ': ' || md5(schedule || command) as line from cron.job order by jobname`;

async function fingerprint(db: pg.Client): Promise<string[]> {
  const lines = (await db.query<{ line: string }>(FINGERPRINT)).rows.map((r) => r.line);
  const cron = await db.query<{ ok: boolean }>(
    `select exists (select 1 from pg_namespace where nspname = 'cron') ok`,
  );
  if (cron.rows[0]!.ok)
    lines.push(...(await db.query<{ line: string }>(JOBS)).rows.map((r) => r.line));
  return lines;
}

function compare(label: string, want: string[], got: string[]): string[] {
  const w = new Set(want);
  const g = new Set(got);
  const missing = want.filter((x) => !g.has(x));
  const extra = got.filter((x) => !w.has(x));
  if (missing.length === 0 && extra.length === 0) return [];
  return [
    `${label}: ${missing.length} object(s) differ or are missing, ${extra.length} unexpected`,
    ...missing.slice(0, 10).map((x) => `  expected  ${x}`),
    ...extra.slice(0, 10).map((x) => `  found     ${x}`),
  ];
}

const migrations = readdirSync(MIGRATIONS)
  .filter((f) => f.endsWith('.sql'))
  .sort();
const problems: string[] = [];
for (const m of migrations.filter((f) => f >= FIRST_WITH_ROLLBACK)) {
  if (!existsSync(join(ROLLBACK, m))) problems.push(`${m}: no rollback file in supabase/rollback/`);
}
for (const r of existsSync(ROLLBACK)
  ? readdirSync(ROLLBACK).filter((f) => f.endsWith('.sql'))
  : []) {
  if (!migrations.includes(r))
    problems.push(`supabase/rollback/${r}: there is no migration with this name`);
}

let checked = 0;
for (const m of migrations.filter((f) => existsSync(join(ROLLBACK, f)))) {
  const scratch = await createScratchDb(serverUrl, m);
  const db = new pg.Client({ connectionString: scratch.url });
  try {
    await db.connect();
    const run = async (file: string) => db.query(readFileSync(file, 'utf8'));
    const before = await fingerprint(db);
    await run(join(MIGRATIONS, m));
    const after = await fingerprint(db);
    if (compare('', before, after).length === 0) {
      problems.push(`${m}: the migration changes nothing the check can see`);
    }
    await run(join(ROLLBACK, m));
    problems.push(...compare(`${m}: after the rollback`, before, await fingerprint(db)));
    await run(join(MIGRATIONS, m));
    problems.push(...compare(`${m}: after applying it again`, after, await fingerprint(db)));
    checked += 1;
  } catch (e) {
    problems.push(`${m}: ${(e as Error).message}`);
  } finally {
    await db.end().catch(() => {});
    await scratch.drop();
  }
}

if (problems.length > 0) {
  console.error(problems.join('\n'));
  process.exitCode = 1;
} else {
  console.log(`Every rollback undoes its migration exactly (${checked} checked).`);
}
