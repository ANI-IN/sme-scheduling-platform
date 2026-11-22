// M5 (docs/PLAN_RELEASE_3.md section 2, decision 279): clear the demo records once, before the switch to Production.
//
//   npm run clear-demo -w scripts -- --preview            what would be deleted and kept, per table (nothing changes)
//   npm run clear-demo -w scripts -- --run --confirm CLEAR-DEMO-DATA
//
// Only after a verified backup and the owner's OK. It deletes only demo records: every domain listed in DEMO_DOMAINS
// with its modules, cohorts, class weeks, classes, bookings, requests, reminders, checklists, help requests and
// settings; the test instructors; every message and task; made up team members. It keeps signed in team members and
// their access, settings for every domain, message templates of domains that stay, the Discord server list and
// channels, app_config, Activity history, global holidays, the n8n counter and the clock. The preview runs the same
// deletes inside a transaction and rolls back, so its counts are exact. DATABASE_URL may also point at a local copy
// restored from the backup, which is how the run is rehearsed.
import pg from 'pg';

const DEMO_DOMAINS = ['Backend', 'Fullstack Test'];
const url = process.env.DATABASE_URL ?? '';
const run = process.argv.includes('--run');
const confirmed = process.argv[process.argv.indexOf('--confirm') + 1] === 'CLEAR-DEMO-DATA';
if (run && !confirmed) {
  console.error('Add --confirm CLEAR-DEMO-DATA to delete. Use --preview first.');
  process.exit(1);
}

const c = new pg.Client({ connectionString: url });
await c.connect();
const tables = async () =>
  (
    await c.query<{ t: string }>(
      `select format('%I.%I', n.nspname, c.relname) t from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'r' and n.nspname = 'public' order by 1`,
    )
  ).rows.map((r) => r.t);
const counts = async () => {
  const m = new Map<string, number>();
  for (const t of await tables())
    m.set(t, Number((await c.query(`select count(*) n from ${t}`)).rows[0].n));
  return m;
};

try {
  const env = (await c.query(`select environment e from public.app_config where id = 1`)).rows[0].e;
  if (env === 'Production')
    throw new Error('This database is already Production: demo data can never be cleared there.');
  const before = await counts();
  await c.query('begin');
  // The same switches Reset Sandbox data uses: no "deleted" entry per row in Activity history, and the checks that
  // protect real data from a single delete are skipped for this one clear.
  await c.query(`select set_config('app.suppress_setup_log', 'on', true), set_config('app.reset_sandbox', 'on', true),
                 set_config('app.actor_kind', 'System', true), set_config('app.actor_label', 'Clear demo data', true)`);
  await c.query(`set constraints all deferred`);
  const dom = `(select id from public.domain where name = any ($1))`;
  const steps: [string, string, unknown[]][] = [
    ['every message', `delete from public.message`, []],
    ['every task', `delete from public.attention_item`, []],
    ['help requests', `delete from public.help_request`, []],
    ['answer links', `delete from public.response_link`, []],
    ['reminders', `delete from public.reminder`, []],
    ['checklists', `delete from public.checklist_item`, []],
    ['chosen lists', `delete from public.manual_queue_item`, []],
    ['booking slots', `delete from public.booking_slot`, []],
    ['bookings', `delete from public.booking`, []],
    ['requests', `delete from public.request`, []],
    [
      'classes',
      `delete from public.class_session where module_week_id in (select id from public.module_week where domain_id in ${dom})`,
      [DEMO_DOMAINS],
    ],
    ['class weeks', `delete from public.module_week where domain_id in ${dom}`, [DEMO_DOMAINS]],
    [
      'module people and orders',
      `delete from public.module_operations where module_id in (select id from public.module where domain_id in ${dom})`,
      [DEMO_DOMAINS],
    ],
    [
      '',
      `delete from public.module_ranking where module_id in (select id from public.module where domain_id in ${dom})`,
      [DEMO_DOMAINS],
    ],
    [
      '',
      `delete from public.module_owner where module_id in (select id from public.module where domain_id in ${dom})`,
      [DEMO_DOMAINS],
    ],
    [
      '',
      `delete from public.module_resource where module_id in (select id from public.module where domain_id in ${dom})`,
      [DEMO_DOMAINS],
    ],
    [
      'class times',
      `delete from public.class_pattern_item where module_id in (select id from public.module where domain_id in ${dom})`,
      [DEMO_DOMAINS],
    ],
    ['modules', `delete from public.module where domain_id in ${dom}`, [DEMO_DOMAINS]],
    ['cohorts', `delete from public.cohort where domain_id in ${dom}`, [DEMO_DOMAINS]],
    ['class types', `delete from public.class_type where domain_id in ${dom}`, [DEMO_DOMAINS]],
    ['domain teams', `delete from public.domain_team where domain_id in ${dom}`, [DEMO_DOMAINS]],
    [
      'instructor channels',
      `delete from public.instructor_channel where instructor_id in (select id from public.instructor where is_test)`,
      [],
    ],
    [
      '',
      `delete from public.instructor_unavailability where instructor_id in (select id from public.instructor where is_test)`,
      [],
    ],
    [
      '',
      `delete from public.instructor_email where instructor_id in (select id from public.instructor where is_test)`,
      [],
    ],
    ['test instructors', `delete from public.instructor where is_test`, []],
    [
      'domain settings and holidays',
      `delete from public.setting where domain_id in ${dom}`,
      [DEMO_DOMAINS],
    ],
    ['', `delete from public.holiday where domain_id in ${dom}`, [DEMO_DOMAINS]],
    ['', `delete from public.message_template where domain_id in ${dom}`, [DEMO_DOMAINS]],
    ['demo domains', `delete from public.domain where name = any ($1)`, [DEMO_DOMAINS]],
    [
      'made up team members',
      `delete from public.team_member where is_placeholder and auth_user_id is null`,
      [],
    ],
  ];
  for (const [, sql, params] of steps) await c.query(sql, params);
  await c.query(`set constraints all immediate`);
  await c.query(
    `select private.log_event('System', 'Demo data cleared', null, null, null, $1::jsonb)`,
    [JSON.stringify({ domains: DEMO_DOMAINS })],
  );
  const after = await counts();
  const rows = [...before.keys()].map((t) => {
    const a = before.get(t)!;
    const b = after.get(t) ?? 0;
    const word = a === b ? 'kept   ' : b > a ? 'added  ' : 'deleted';
    return `${word} ${t.padEnd(36)} ${String(a).padStart(6)} -> ${String(b).padStart(6)}${a > b ? `  (${a - b} removed)` : b > a ? `  (${b - a} added)` : ''}`;
  });
  console.log(rows.join('\n'));
  if (run) {
    await c.query('commit');
    console.log('\nDemo data cleared. One entry "Demo data cleared" is in Activity history.');
  } else {
    await c.query('rollback');
    console.log('\nPreview only: nothing was changed.');
  }
} catch (e) {
  await c.query('rollback').catch(() => {});
  console.error((e as Error).message);
  process.exitCode = 1;
} finally {
  await c.end();
}
