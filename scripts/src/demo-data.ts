// Test data for the end to end tests and the help pictures, loaded into the separate test stack only
// (decision 250). The app database and the hosted projects are never touched: the app itself starts empty.
//
//   npm run demo -w scripts -- load    # empty the test stack, then load the test data and a few answers
//
// The test data comes from supabase/tests/fixtures/starting_data.sql (two domains, cohorts, modules, test
// instructors and eight weeks of classes). Then the app's own functions (engine_tick, submit_response_page,
// create_help_request) ask, answer and confirm, so what the tests see is what the team would see.
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import pg from 'pg';
import { TEST_DB_URL } from './test-stack.ts';

const ROOT = resolve(import.meta.dirname, '../..');
const DB = TEST_DB_URL;

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

  // Refuse anything but a local development database (the test stack is one).
  const env = await one<{ e: string }>(`select environment e from public.app_config where id = 1`);
  if (env.e !== 'Development')
    throw new Error(`Test data only goes into a local test stack, not ${env.e}.`);
  // Empty it, then load the test data (Backend and Fullstack, weekend and weekday cohorts).
  await c.query(`select public.reset_sandbox_data('RESET')`);
  await c.query(readFileSync(join(ROOT, 'supabase/tests/fixtures/starting_data.sql'), 'utf8'));
  await c.query(`select tests.load_starting_data()`);
  // A bot in 16 Discord servers (decision 261): most ready, some with a problem or not checked yet, and the
  // first with channels in a "Test instructors" category. No domain uses them, so messages are not affected.
  await c.query(`
    insert into public.discord_server (id, name, status, problem, checked_at)
    select (900000000000000100 + n)::text, 'Program server ' || n,
           case when n % 5 = 0 then 'Problem' when n % 7 = 0 then 'NotChecked' else 'Ready' end,
           case when n % 5 = 0 then 'The bot cannot see any text channels in Program server ' || n
             || '. Give the bot''s role access to the instructors'' category.' end,
           case when n % 7 = 0 then null else now() - n * interval '1 hour' end
      from generate_series(1, 16) n
    on conflict (id) do nothing;
    insert into public.discord_channel (id, server_id, name, category, position)
    select (900000000000000200 + n)::text, '900000000000000101', 'test-instructor-' || chr(96 + n), 'Test instructors', n
      from generate_series(1, 3) n
    union all select '900000000000000210', '900000000000000101', 'alerts', null, 0
    on conflict (id) do nothing;`);
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
  // Every table was just replaced: give the planner fresh numbers now, so the first page loads of a
  // test run do not wait on stale plans or on the automatic analyze (decision 249).
  await c.query('analyze');
  await c.end();
}

const cmd = process.argv[2];
if (cmd === 'load') await load();
else {
  console.log('Use: load');
  process.exitCode = 1;
}
