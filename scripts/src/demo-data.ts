// Demo data for screenshots (UI Milestone 7), with a safe way back.
//
//   npm run demo -w scripts -- snapshot   # save the app's data (public and private schemas)
//   npm run demo -w scripts -- load       # plan classes and simulate answers in a testing domain
//   npm run demo -w scripts -- restore    # put the saved data back exactly as it was
//
// The demo uses the app's own functions (generate_classes, create_module_weeks, engine_tick,
// submit_response_page, create_help_request), so what the screenshots show is what the team
// would see. It works on the first domain in testing that has modules in use; nothing here
// names a domain, module or instructor. Needs Docker (the local Supabase database container).
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
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

  const dom = await one<{ id: string; name: string } | undefined>(
    `select d.id, d.name from public.domain d
      where d.status = 'Test' and exists (select 1 from public.module m where m.domain_id = d.id and m.status = 'Active')
      order by d.created_at limit 1`,
  );
  if (!dom) throw new Error('No domain in testing with modules in use.');
  const first = await one<{ id: string }>(
    `select id from public.module where domain_id = $1 and status = 'Active' order by rotation_order nulls last, name limit 1`,
    [dom.id],
  );
  // Ten weeks starting next Sunday (Pacific), so some weeks are being asked and some are later.
  const sundays = await one<{ d: string[] }>(
    `select array_agg(to_char(s, 'YYYY-MM-DD') order by s) as d
       from generate_series(
         ((now() at time zone 'America/Los_Angeles')::date + (7 - extract(dow from (now() at time zone 'America/Los_Angeles'))::int)),
         ((now() at time zone 'America/Los_Angeles')::date + (7 - extract(dow from (now() at time zone 'America/Los_Angeles'))::int)) + 63,
         interval '7 days') s`,
  );
  await c.query(`update public.domain set test_clock_at = null where id = $1`, [dom.id]);
  // Screenshot and test accounts skip the one time Discord question.
  await c.query(
    `update public.team_member set discord_prompt_dismissed_at = now(), version = version
      where discord_user_id is null and discord_prompt_dismissed_at is null`,
  );
  const created = await one<{ v: { module_week_ids: string[] } }>(
    `select public.create_module_weeks($1, public.generate_classes($1, $2, $3::date[])) as v`,
    [dom.id, first.id, sundays.d],
  );
  const weeks = (
    await c.query<{ id: string }>(
      `select id from public.module_week where id = any($1::uuid[]) order by first_class_at`,
      [created.v.module_week_ids],
    )
  ).rows.map((r) => r.id);
  console.log(`Planned ${weeks.length} class weeks in ${dom.name}.`);

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
