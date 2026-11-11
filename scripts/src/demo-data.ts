// Demo data for screenshots (UI Milestone 7), with a safe way back.
//
//   npm run demo -w scripts -- snapshot   # save the app's data (public and private schemas)
//   npm run demo -w scripts -- load       # plan classes and simulate answers in a testing domain
//   npm run demo -w scripts -- restore    # put the saved data back exactly as it was
//
// The demo starts from the Sandbox starting data (reset_sandbox_data) and then uses the app's own
// functions (engine_tick,
// submit_response_page, create_help_request), so what the screenshots show is what the team
// would see. Needs Docker (the local Supabase database container).
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import pg from 'pg';

const ROOT = resolve(import.meta.dirname, '../..');
const SNAPSHOT = join(ROOT, '.ui-demo-snapshot.sql');
const DB = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';
const projectId =
  /^project_id\s*=\s*"([^"]+)"/m.exec(
    readFileSync(join(ROOT, 'supabase/config.toml'), 'utf8'),
  )?.[1] ?? 'sme-scheduling';
const CONTAINER = `supabase_db_${projectId}`;
const SCHEMAS = ['public', 'private'];

function docker(args: string[], input?: string): string {
  return execFileSync('docker', ['exec', '-i', CONTAINER, ...args], {
    input,
    encoding: 'utf8',
    maxBuffer: 512 * 1024 * 1024,
  });
}

function snapshot() {
  const dump = docker([
    'pg_dump',
    '-U',
    'supabase_admin',
    '-d',
    'postgres',
    '--data-only',
    '--disable-triggers',
    ...SCHEMAS.flatMap((s) => ['--schema', s]),
  ]);
  // Keep the previous copy too, so one mistake can never lose the only saved copy.
  if (existsSync(SNAPSHOT)) renameSync(SNAPSHOT, SNAPSHOT.replace(/\.sql$/, '.previous.sql'));
  writeFileSync(SNAPSHOT, dump);
  console.log(`Saved the app data to ${SNAPSHOT} (${Math.round(dump.length / 1024)} KB).`);
}

function restore() {
  if (!existsSync(SNAPSHOT)) throw new Error(`No snapshot at ${SNAPSHOT}. Run "snapshot" first.`);
  const tables = docker([
    'psql',
    '-U',
    'supabase_admin',
    '-d',
    'postgres',
    '-tAc',
    `select string_agg(format('%I.%I', schemaname, tablename), ', ') from pg_tables where schemaname in (${SCHEMAS.map((s) => `'${s}'`).join(',')})`,
  ]).trim();
  const sql = [
    '\\set ON_ERROR_STOP on',
    'begin;',
    'set session_replication_role = replica;',
    `truncate ${tables};`,
    readFileSync(SNAPSHOT, 'utf8'),
    'commit;',
  ].join('\n');
  docker(['psql', '-q', '-U', 'supabase_admin', '-d', 'postgres'], sql);
  console.log('Restored the app data from the snapshot.');
}

async function load() {
  const c = new pg.Client({ connectionString: DB });
  await c.connect();
  const one = async <T>(sql: string, p: unknown[] = []) => (await c.query(sql, p)).rows[0] as T;
  const deliver = async () => {
    const { rows } = await c.query<{ id: string }>(
      'select id from public.claim_outbound_messages(500)',
    );
    for (const m of rows) await c.query('select public.report_message_result($1, true)', [m.id]);
  };
  const tick = async (dom: string) => {
    await c.query('select public.engine_tick($1, now())', [dom]);
    await deliver();
  };
  const answer = async (mw: string, ans: string, form: Record<string, string> = {}) => {
    const r = await one<{ token: string } | undefined>(
      `select l.token from public.response_link l join public.request q on q.id = l.request_id
        where q.module_week_id = $1 and q.kind = 'Outreach' and q.status in ('Sent', 'Reminded')
          and l.answer = $2 order by q.created_at desc limit 1`,
      [mw, ans],
    );
    if (!r) return false;
    await c.query('select public.submit_response_page($1, $2)', [
      r.token,
      JSON.stringify({ t: r.token, ...form }),
    ]);
    await deliver();
    return true;
  };

  // Start from the Sandbox starting data (Backend and Fullstack, weekend and weekday cohorts).
  await c.query(`select public.reset_sandbox_data('RESET')`);
  // The screenshot account plays the Sandbox operations person and skips the Discord question.
  // A reset keeps real people, so first remove an earlier copy of the screenshot account.
  await c.query(`delete from public.team_member where email = $1`, [
    process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com',
  ]);
  await c.query(
    `update public.team_member set email = $1, discord_prompt_dismissed_at = now(), version = version
      where email = 'sandbox.operations@example.com'`,
    [process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com'],
  );
  await c.query(
    `update public.team_member set discord_prompt_dismissed_at = now(), version = version
      where discord_user_id is null and discord_username is null and discord_prompt_dismissed_at is null`,
  );
  const dom = await one<{ id: string; name: string }>(
    `select id, name from public.domain where name = 'Backend'`,
  );
  const weeks = (
    await c.query<{ id: string }>(
      `select w.id from public.module_week w join public.cohort c on c.id = w.cohort_id
        where w.domain_id = $1 and c.name = 'Weekend cohort' order by w.first_class_at`,
      [dom.id],
    )
  ).rows.map((r) => r.id);
  console.log(`Sandbox data loaded; using ${weeks.length} weekend class weeks in ${dom.name}.`);

  await tick(dom.id); // setup check and the first requests

  // Week 1: the first instructor asked says yes, then asks for help.
  if (weeks[0] && (await answer(weeks[0], 'Yes'))) {
    await c.query(`select public.create_help_request($1, $2, $3, 'Within24h')`, [
      weeks[0],
      ['zoom', 'materials'],
      'The Zoom link is missing from the calendar invite, and I need the latest slides.',
    ]);
  }
  // Week 2: the first instructor says no, so the next one is asked.
  if (weeks[1]) await answer(weeks[1], 'No');
  // Week 3: confirmed.
  if (weeks[2]) await answer(weeks[2], 'Yes');
  // Week 4: everyone says no, so nobody is left to ask.
  if (weeks[3]) for (let n = 0; n < 6 && (await answer(weeks[3], 'No')); n++) await tick(dom.id);
  await tick(dom.id);

  const s = await one<Record<string, number>>(
    `select
       (select count(*)::int from public.module_week where id = any($1::uuid[])) as weeks,
       (select count(*)::int from public.booking where module_week_id = any($1::uuid[]) and status = 'Active') as confirmed,
       (select count(*)::int from public.request where module_week_id = any($1::uuid[]) and status in ('Sent','Reminded')) as asking,
       (select count(*)::int from public.attention_item where domain_id = $2 and status <> 'Done') as tasks`,
    [weeks, dom.id],
  );
  console.log(
    `Demo ready: ${s.weeks} class weeks, ${s.confirmed} confirmed, ${s.asking} being asked, ${s.tasks} open tasks.`,
  );
  await c.end();
}

const cmd = process.argv[2];
if (cmd === 'snapshot') snapshot();
else if (cmd === 'restore') restore();
else if (cmd === 'load') await load();
else {
  console.log('Use: snapshot | load | restore');
  process.exitCode = 1;
}
