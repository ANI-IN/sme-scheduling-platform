// Full journey against the hosted Sandbox, with the real Sandbox Discord bot, the real n8n workflows
// and the Sandbox test mailbox. It checks that every message really arrived, then cleans up.
//
//   npm run integration:sandbox -w scripts      (reads ../.env.sandbox)
//
// Needs in .env.sandbox (see .env.example):
//   DATABASE_URL                       Sandbox database connection string
//   SANDBOX_DISCORD_BOT_TOKEN          the Sandbox bot token (reads and deletes its own test messages)
//   SANDBOX_GMAIL_CLIENT_ID, SANDBOX_GMAIL_CLIENT_SECRET, SANDBOX_GMAIL_REFRESH_TOKEN
//                                      OAuth for the test mailbox (scope gmail.modify), to find and
//                                      remove the test emails
//   SANDBOX_N8N_POKE_URL, SANDBOX_N8N_POKE_KEY   optional: makes n8n deliver at once instead of
//                                      within 5 minutes
//
// The journey: a one off class week in the Backend weekday cohort → start asking now → n8n delivers
// the request to the testing channel and testing email → the "Yes" button is pressed through the
// real confirm page (n8n WF2) → n8n delivers the confirmation → the class week is cancelled →
// n8n delivers the cancellation. Every message must be Sent by n8n and found in Discord and Gmail.
// Cleanup: the bot deletes its test posts and the test emails are moved to the bin. Activity
// history is kept, as always.
//
//   npm run integration:rehearse -w scripts      (the separate test stack only)
//
// Rehearsal: the same journey in the test stack, with the test data loaded, with this script standing in for n8n
// (it marks messages as delivered and presses the confirm button the way WF2 does). It needs no
// credentials and checks the database side of the journey; CI runs it on every push.
import pg from 'pg';
import { TEST_DB_URL } from './test-stack.ts';

const REHEARSE = process.argv.includes('--rehearse');
// Decision 252: automated tests never write to the hosted Sandbox, and there is no direct Gmail access
// (n8n signs in to Gmail itself). The real journey is off; docs/READY_FOR_TESTING.md has the same journey as
// manual steps, and docs/DEFERRED.md says what turning it back on needs.
if (!REHEARSE) {
  console.error(
    'The journey on the hosted Sandbox is switched off (decision 252). Use the manual checks in docs/READY_FOR_TESTING.md.',
  );
  process.exit(2);
}

const env = (k: string, required = true) => {
  const v = process.env[k];
  if (!v && required && !REHEARSE) {
    console.error(
      `Missing ${k}. Add it to .env.sandbox (see .env.example and docs/TEST_REPORT.md).`,
    );
    process.exit(2);
  }
  return v ?? '';
};
// The rehearsal runs in the separate test stack (npm run integration:rehearse starts and removes it).
const DB = REHEARSE ? TEST_DB_URL : env('DATABASE_URL');
const BOT = env('SANDBOX_DISCORD_BOT_TOKEN');
const G_ID = env('SANDBOX_GMAIL_CLIENT_ID');
const G_SECRET = env('SANDBOX_GMAIL_CLIENT_SECRET');
const G_REFRESH = env('SANDBOX_GMAIL_REFRESH_TOKEN');
const POKE_URL = env('SANDBOX_N8N_POKE_URL', false);
const POKE_KEY = env('SANDBOX_N8N_POKE_KEY', false);

const c = new pg.Client({ connectionString: DB });
await c.connect();
const one = async <T>(q: string, p: unknown[] = []) => (await c.query(q, p)).rows[0] as T;
const all = async <T>(q: string, p: unknown[] = []) => (await c.query(q, p)).rows as T[];
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok: boolean, what: string) => {
  console.log(`${ok ? '  ✓' : '  ✗'} ${what}`);
  if (!ok) failures++;
};

async function poke() {
  if (REHEARSE) {
    // Stand in for n8n WF4: claim every queued message and report it delivered.
    const { rows } = await c.query<{ id: string }>(
      'select id from public.claim_outbound_messages(100)',
    );
    for (const m of rows)
      await c.query('select public.report_message_result($1, true, $2)', [
        m.id,
        `rehearsal-${m.id}`,
      ]);
    return;
  }
  if (!POKE_URL) return;
  await fetch(POKE_URL, { method: 'POST', headers: { 'x-poke-key': POKE_KEY } }).catch(() => {});
}

/** Wait until every message of the class week is Sent (or one fails). */
async function delivered(week: string, label: string) {
  const until = Date.now() + 7 * 60_000;
  while (Date.now() < until) {
    await poke();
    const rows = await all<{ status: string; last_error: string | null }>(
      `select status, last_error from public.message where module_week_id = $1 and direction = 'Outbound'`,
      [week],
    );
    const waiting = rows.filter((r) => !['Sent', 'Failed', 'Cancelled'].includes(r.status));
    if (rows.length > 0 && waiting.length === 0) {
      const bad = rows.filter((r) => r.status !== 'Sent' && r.status !== 'Cancelled');
      check(bad.length === 0, `${label}: n8n sent all ${rows.length} messages`);
      for (const b of bad) console.log(`      ${b.status}: ${b.last_error}`);
      return;
    }
    await sleep(REHEARSE ? 200 : 15_000);
  }
  check(false, `${label}: messages still waiting after 7 minutes (is n8n running?)`);
}

async function discord(path: string, init: RequestInit = {}) {
  const r = await fetch(`https://discord.com/api/v10${path}`, {
    ...init,
    headers: { Authorization: `Bot ${BOT}`, ...(init.headers ?? {}) },
  });
  if (r.status === 429) {
    await sleep(2_000);
    return discord(path, init);
  }
  return r;
}

let gToken = '';
async function gmail(path: string, init: RequestInit = {}) {
  if (!gToken) {
    const r = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      body: new URLSearchParams({
        client_id: G_ID,
        client_secret: G_SECRET,
        refresh_token: G_REFRESH,
        grant_type: 'refresh_token',
      }),
    });
    gToken = ((await r.json()) as { access_token: string }).access_token;
  }
  return fetch(`https://gmail.googleapis.com/gmail/v1/users/me${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${gToken}`, ...(init.headers ?? {}) },
  });
}

// ------------------------------------------------------------------ safety first
const cfg = await one<{
  environment: string;
  response_base_url: string | null;
  sandbox_allowed_email_domains: string[];
  sandbox_allowed_discord_servers: string[];
}>(
  `select environment, response_base_url, sandbox_allowed_email_domains, sandbox_allowed_discord_servers
     from public.app_config where id = 1`,
);
if (REHEARSE && cfg.environment !== 'Development') {
  console.error('The rehearsal only runs on a local Development database.');
  process.exit(2);
}
if (!REHEARSE && cfg.environment !== 'Sandbox') {
  console.error(
    `This database says it is "${cfg.environment}". The integration test only runs on Sandbox.`,
  );
  process.exit(2);
}
console.log(REHEARSE ? 'Integration journey rehearsal (local)' : 'Sandbox integration journey');
if (!REHEARSE) {
  check(cfg.sandbox_allowed_email_domains.length > 0, 'Sandbox email allow list is set');
  check(cfg.sandbox_allowed_discord_servers.length > 0, 'Sandbox Discord allow list is set');
  check(!!cfg.response_base_url, 'Response page link is set');
}

const dom = await one<{ id: string; test_discord_channel_id: string; test_email: string }>(
  `select id, test_discord_channel_id, test_email from public.domain where name = 'Backend' and status = 'Test'`,
);
if (!dom) {
  console.error('No Backend domain in Test. Press "Reset Sandbox data" on the Testing page first.');
  process.exit(2);
}
const started = new Date();
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

// Press "Yes" through the real confirm page (n8n WF2): GET shows the page, POST records the answer.
const link = await one<{ token: string }>(
  `select l.token from public.response_link l join public.request r on r.id = l.request_id
    where r.module_week_id = $1 and l.answer = 'Yes' order by r.created_at desc limit 1`,
  [week],
);
if (REHEARSE) {
  // What WF2 does: GET shows the page (records nothing), POST records the answer.
  const html = await one<{ h: string }>('select public.response_page($1)::text h', [link.token]);
  check(html.h.includes('<form'), 'confirm page renders');
  await c.query('select public.submit_response_page($1, $2)', [
    link.token,
    JSON.stringify({ t: link.token }),
  ]);
} else {
  const pageRes = await fetch(`${cfg.response_base_url}?t=${encodeURIComponent(link.token)}`);
  check(pageRes.ok && (await pageRes.text()).includes('<form'), 'confirm page opens through n8n');
  const post = await fetch(cfg.response_base_url!, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ t: link.token }),
  });
  check(post.ok, 'pressing Yes on the confirm page works');
}
const booked = await one<{ n: number }>(
  `select count(*)::int n from public.booking where module_week_id = $1 and status = 'Active'`,
  [week],
);
check(booked.n === 1, 'the first Yes confirms the instructor');
await delivered(week, 'confirmation');

await c.query(`select public.cancel_module_week($1, 'Integration test finished')`, [week]);
await delivered(week, 'cancellation');

if (REHEARSE) {
  const n = await one<{ n: number }>(
    `select count(*)::int n from public.message where module_week_id = $1 and direction = 'Outbound' and status = 'Sent'`,
    [week],
  );
  check(n.n >= 3, `${n.n} messages would have gone to Discord and email`);
  console.log('Rehearsal: Discord, Gmail and cleanup are only checked against the real Sandbox.');
} else {
  // ------------------------------------------------------------------ did it really arrive?
  const sent = await all<{
    channel: string;
    external_id: string | null;
    subject: string | null;
    discord_channel_id: string | null;
    to_address: string | null;
  }>(
    `select channel, external_id, subject, discord_channel_id, to_address from public.message
      where module_week_id = $1 and direction = 'Outbound' and status = 'Sent'`,
    [week],
  );
  const posts: { chan: string; id: string }[] = [];
  for (const m of sent.filter((m) => m.channel === 'Discord')) {
    const chan = m.discord_channel_id ?? dom.test_discord_channel_id;
    const r = m.external_id ? await discord(`/channels/${chan}/messages/${m.external_id}`) : null;
    check(!!r?.ok, `Discord message ${m.external_id ?? '(no id)'} is in the channel`);
    if (r?.ok) posts.push({ chan, id: m.external_id! });
  }
  const mails: string[] = [];
  for (const m of sent.filter((m) => m.channel === 'Email')) {
    const q = `to:${m.to_address} after:${Math.floor(started.getTime() / 1000) - 60} subject:"${(m.subject ?? '').replace(/"/g, '')}"`;
    const r = (await (await gmail(`/messages?q=${encodeURIComponent(q)}`)).json()) as {
      messages?: { id: string }[];
    };
    check((r.messages?.length ?? 0) > 0, `email "${m.subject}" arrived at ${m.to_address}`);
    for (const x of r.messages ?? []) mails.push(x.id);
  }

  // ------------------------------------------------------------------ clean up
  for (const p of posts)
    await discord(`/channels/${p.chan}/messages/${p.id}`, { method: 'DELETE' });
  for (const id of new Set(mails)) await gmail(`/messages/${id}/trash`, { method: 'POST' });
  console.log(
    `Cleaned up ${posts.length} Discord posts and ${new Set(mails).size} emails. Activity history is kept.`,
  );
}

await c.end();
console.log(failures ? `\n${failures} check(s) failed.` : '\nEverything arrived.');
process.exit(failures ? 1 : 0);
