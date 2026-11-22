// Test data for the end to end tests and the help pictures, loaded into the separate test stack only
// (decision 250). The app database and the hosted projects are never touched: the app itself starts empty.
//
//   npm run demo -w scripts -- load    # empty the test stack, then load the test data and a few answers
//   npm run demo -w scripts -- load --scale    # the same, plus 60 cohorts and 160 instructors (decision 294)
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
  // Discord servers approved by an admin (decision 288): a "Test server" holds the channels the test domains
  // post in, and it and the 16 program servers are approved for both test domains. One new server still waits
  // for approval, so the Approve and Refuse buttons can be seen.
  await c.query(`
    insert into public.discord_server (id, name, status, checked_at, access)
    values ('900000000000000099', 'Test server', 'Ready', now(), 'Approved')
    on conflict (id) do update set access = 'Approved';
    insert into public.discord_channel (id, server_id, name, category, position)
    select distinct x.id, '900000000000000099', 'testing-' || right(x.id, 4), 'Testing', 0 from (
      select alert_discord_channel_id id from public.domain union select test_discord_channel_id from public.domain
      union select discord_channel_id from public.instructor union select channel_id from public.instructor_channel) x
     where x.id ~ '^\\d{17,20}$'
    on conflict (id) do nothing;
    -- A reload keeps servers, so the new server waits again even if a test approved or refused it.
    insert into public.discord_server (id, name, status, access)
    values ('900000000000000117', 'New program server', 'NotChecked', 'Waiting')
    on conflict (id) do update set name = excluded.name, status = excluded.status, access = 'Waiting',
      access_changed_at = null, access_changed_by = null, archived_at = null;
    delete from public.discord_server_domain where server_id = '900000000000000117';
    update public.discord_server set access = 'Approved', access_changed_at = now()
     where id between '900000000000000101' and '900000000000000116' or id = '900000000000000099';
    insert into public.discord_server_domain (server_id, domain_id)
    select s.id, d.id from public.discord_server s cross join public.domain d where s.access = 'Approved'
    on conflict do nothing;
    -- App settings survive a reload too: a test (the click through) may have chosen a test channel as the admin
    -- alert channel, which may not then be an instructor's channel (DIS 15). Every load starts without one.
    update public.app_config set admin_discord_channel_id = null where id = 1;`);
  // The screenshot account plays the Sandbox operations person and skips the Discord question.
  // A reset keeps real people, so first remove an earlier copy of the screenshot account.
  await c.query(`delete from public.team_member where email = $1`, [
    process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com',
  ]);
  await c.query(
    `update public.team_member set email = $1, discord_prompt_dismissed_at = now(), is_admin = true,
            version = version
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
  // With --scale (npm run e2e:scale), a program the size of the team's tracker is added (decision 294).
  if (process.argv.includes('--scale')) {
    await c.query(readFileSync(join(ROOT, 'supabase/tests/fixtures/scale_data.sql'), 'utf8'));
    const r = await one<{ r: Record<string, number> }>(`select tests.load_scale_data() as r`);
    console.log(
      `Scale data: ${r.r.domains} domains, ${r.r.cohorts} cohorts, ${r.r.instructors} instructors, ${r.r.class_weeks} class weeks.`,
    );
  }
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
