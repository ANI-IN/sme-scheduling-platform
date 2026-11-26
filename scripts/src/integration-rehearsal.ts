// The whole journey of one class week in the separate test stack, with this script standing in for n8n: it takes
// each queued message and reports it delivered, and answers through the same database functions as the answer page.
// It needs no accounts or credentials, and checks the database side of the journey. CI runs it.
//
//   npm run integration:rehearse -w scripts      (starts the test stack, loads the test data, removes it after)
//
// The journey: a one off class week in the Backend weekday cohort, start asking now, the request is delivered,
// "Yes" is pressed, the confirmation is delivered, the class week is cancelled, the cancellation is delivered.
import pg from 'pg';
import { TEST_DB_URL } from './test-stack.ts';

const c = new pg.Client({ connectionString: TEST_DB_URL });
await c.connect();
const one = async <T>(q: string, p: unknown[] = []) => (await c.query(q, p)).rows[0] as T;
const all = async <T>(q: string, p: unknown[] = []) => (await c.query(q, p)).rows as T[];
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok: boolean, what: string) => {
  console.log(`${ok ? '  ✓' : '  ✗'} ${what}`);
  if (!ok) failures++;
};

/** Stand in for n8n WF4: claim every queued message and report it delivered. */
async function deliver() {
  const { rows } = await c.query<{ id: string }>(
    'select id from public.claim_outbound_messages(100)',
  );
  for (const m of rows)
    await c.query('select public.report_message_result($1, true, $2)', [m.id, `rehearsal-${m.id}`]);
}

/** Wait until every message of the class week is Sent (or one fails). */
async function delivered(week: string, label: string) {
  const until = Date.now() + 60_000;
  while (Date.now() < until) {
    await deliver();
    const rows = await all<{ status: string; last_error: string | null }>(
      `select status, last_error from public.message where module_week_id = $1 and direction = 'Outbound'`,
      [week],
    );
    const waiting = rows.filter((r) => !['Sent', 'Failed', 'Cancelled'].includes(r.status));
    if (rows.length > 0 && waiting.length === 0) {
      const bad = rows.filter((r) => r.status !== 'Sent' && r.status !== 'Cancelled');
      check(bad.length === 0, `${label}: all ${rows.length} messages delivered`);
      for (const b of bad) console.log(`      ${b.status}: ${b.last_error}`);
      return;
    }
    await sleep(200);
  }
  check(false, `${label}: messages still waiting after a minute`);
}

// ------------------------------------------------------------------ safety first
const cfg = await one<{ environment: string }>(
  'select environment from public.app_config where id = 1',
);
if (cfg.environment !== 'Development') {
  console.error('The rehearsal only runs on a local Development database.');
  process.exit(2);
}
console.log('Integration journey rehearsal (local)');
const dom = await one<{ id: string }>(
  `select id from public.domain where name = 'Backend' and status = 'Test'`,
);
if (!dom) {
  console.error(
    'No Backend domain in Testing. Load the test data first (npm run demo -w scripts -- load).',
  );
  process.exit(2);
}
await c.query(
  `select set_config('app.actor_kind', 'System', false), set_config('app.actor_label', 'Integration test', false)`,
);

// ------------------------------------------------------------------ the journey
const mod = await one<{ id: string }>(
  `select id from public.module where domain_id = $1 and name = 'Database Design'`,
  [dom.id],
);
const cohort = await one<{ id: string }>(
  `select id from public.cohort where domain_id = $1 and name = 'Weekday cohort'`,
  [dom.id],
);
const day = new Date(Date.now() + 40 * 864e5).toISOString().slice(0, 10);
const added = await one<{ r: { module_week_id: string } }>(
  `select public.add_one_class(null, $1, $2, $3, '10:00', '11:00', 'Live class', 'Integration test class', true, 'Integration test') r`,
  [mod.id, cohort.id, day],
);
const week = added.r.module_week_id;
check(!!week, `one off class week created on ${day}`);

await c.query(`select public.start_asking_now($1)`, [week]);
await delivered(week, 'request');

// Press "Yes".
const link = await one<{ token: string }>(
  `select l.token from public.response_link l join public.request r on r.id = l.request_id
    where r.module_week_id = $1 and l.answer = 'Yes' order by r.created_at desc limit 1`,
  [week],
);
// What the answer page (n8n WF2) does: showing it records nothing, sending it records the answer.
const html = await one<{ h: string }>('select public.response_page($1)::text h', [link.token]);
check(html.h.includes('<form'), 'confirm page renders');
await c.query('select public.submit_response_page($1, $2)', [
  link.token,
  JSON.stringify({ t: link.token }),
]);
const booked = await one<{ n: number }>(
  `select count(*)::int n from public.booking where module_week_id = $1 and status = 'Active'`,
  [week],
);
check(booked.n === 1, 'the first Yes confirms the instructor');
await delivered(week, 'confirmation');

await c.query(`select public.cancel_module_week($1, 'Integration test finished')`, [week]);
await delivered(week, 'cancellation');

const n = await one<{ n: number }>(
  `select count(*)::int n from public.message where module_week_id = $1 and direction = 'Outbound' and status = 'Sent'`,
  [week],
);
check(n.n >= 3, `${n.n} messages would have gone to Discord and email`);

await c.end();
console.log(failures ? `\n${failures} check(s) failed.` : '\nEverything arrived.');
process.exit(failures ? 1 : 0);
