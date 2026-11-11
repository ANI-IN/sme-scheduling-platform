// A small demo data set for the hosted Sandbox (docs/DEMO_SCRIPT.md). Sandbox only: it refuses any other database.
//
//   npm run demo:load -w scripts -- --as you@yourcompany.com --discord-username yourname
//
// --as is your company Google account. Sign in to the app once with it first: the command acts as you (the same
// check as the app) and makes you module owner and operations team member. It first runs "Reset Sandbox data",
// so running it again starts the demo over, and Reset Sandbox data in the app removes everything it added.
//
// What it adds: the domain "Backend" (Live, on the Sandbox Discord server), modules "Concurrency" and "API Design"
// (a live class and an assignment review each, one materials link, instructor order Test instructor A, B, C),
// three test instructors on the B2C plus addresses with their own channels, a US cohort (Pacific) and an India
// cohort (IST), each with 4 class weeks starting about 5 weeks from now.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const SANDBOX_REF = 'abcdefghijklmnopqrst';
const SERVER_ID = '1200000000000000010';
const CHANNELS = {
  alerts: '1200000000000000012',
  adminAlerts: '1200000000000000013',
  a: '1200000000000000014',
  b: '1200000000000000015',
  c: '1200000000000000016',
};
const MY_DISCORD_ID = '1200000000000000008';
const MAILBOX = 'scheduling-mailbox';
const MAIL_DOMAIN = 'yourcompany.com';

const arg = (name: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1]?.trim() : undefined;
};
const me = arg('as')?.toLowerCase();
const discordUsername = arg('discord-username') ?? null;
const fail = (msg: string): never => {
  console.error(msg);
  process.exit(1);
};

const url = process.env.DATABASE_URL ?? '';
if (!url) fail('Set DATABASE_URL in .env.sandbox (the Sandbox Session pooler address).');
// The Sandbox project only, never Production or a computer's own database.
const parsed = new URL(url.replace(/^postgres(ql)?:/, 'http:'));
if (!`${parsed.username} ${parsed.hostname}`.includes(SANDBOX_REF))
  fail(
    `This command only loads demo data into the Sandbox project ${SANDBOX_REF}. DATABASE_URL points elsewhere.`,
  );
if (!me || !me.endsWith(`@${MAIL_DOMAIN}`))
  fail(`Say who you are: --as you@${MAIL_DOMAIN} (the company Google account you signed in with).`);

const c = new pg.Client({ connectionString: url });
await c.connect();
const one = async <T>(sql: string, params: unknown[] = []) =>
  (await c.query(sql, params)).rows[0] as T;
try {
  const cfg = await one<{ environment: string }>(
    'select environment from public.app_config where id = 1',
  );
  if (cfg?.environment !== 'Sandbox')
    fail(`This database says it is "${cfg?.environment}". Demo data is only for the Sandbox.`);
  const user = await one<{ id: string }>(
    `select u.id from auth.users u where lower(u.email) = $1
        and exists (select 1 from auth.identities i where i.user_id = u.id and i.provider = 'google')`,
    [me],
  );
  if (!user)
    fail(`${me} has not signed in to the app yet. Sign in once on the site, then run this again.`);

  await c.query('begin');
  // Act as you, the same way the app's sign in does, so the reset and the history show your name.
  await c.query(
    `select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.role', 'authenticated', true)`,
    [
      JSON.stringify({
        sub: user.id,
        role: 'authenticated',
        email: me,
        amr: [{ method: 'oauth', timestamp: Math.floor(Date.now() / 1000) }],
        app_metadata: { provider: 'google' },
      }),
    ],
  );
  await c.query(`select public.reset_sandbox_data('RESET')`);
  await c.query(
    `select set_config('app.actor_kind', 'System', true), set_config('app.actor_label', 'Demo data', true)`,
  );

  // Your Discord username first, then your ID (saving a username clears the ID until n8n looks it up).
  await c.query(
    `update public.team_member set discord_username = coalesce($2, discord_username),
            discord_prompt_dismissed_at = coalesce(discord_prompt_dismissed_at, now()), version = version
      where lower(email) = $1`,
    [me, discordUsername],
  );
  const mine = await one<{ id: string }>(
    `update public.team_member set discord_user_id = $2, version = version where lower(email) = $1 returning id`,
    [me, MY_DISCORD_ID],
  );
  if (!mine) fail(`No team member with ${me}. Sign in once on the site first.`);
  await c.query(
    `insert into public.discord_server (id, name) values ($1, 'Sandbox server') on conflict (id) do update set archived_at = null`,
    [SERVER_ID],
  );
  await c.query(
    `update public.app_config set admin_discord_channel_id = $1, discord_guild_id = $2 where id = 1`,
    [CHANNELS.adminAlerts, SERVER_ID],
  );
  // The channels the app shows in its pickers until the server check (WF6) refreshes them.
  await c.query(
    `insert into public.discord_channel (id, server_id, name, category, position, refreshed_at, bot_can_post)
     values ($1, $6, 'alerts', null, 1, now(), true), ($2, $6, 'admin-alerts', null, 2, now(), true),
            ($3, $6, 'test-instructor-a', 'Test instructors', 3, now(), true),
            ($4, $6, 'test-instructor-b', 'Test instructors', 4, now(), true),
            ($5, $6, 'test-instructor-c', 'Test instructors', 5, now(), true)
     on conflict (id) do nothing`,
    [CHANNELS.alerts, CHANNELS.adminAlerts, CHANNELS.a, CHANNELS.b, CHANNELS.c, SERVER_ID],
  );
  await c.query(
    readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), '..', 'sql', 'demo-load.sql'),
      'utf8',
    ),
  );
  const r = await one<{ result: Record<string, unknown> }>(
    `select pg_temp.demo_load($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9) as result`,
    [
      mine.id,
      SERVER_ID,
      CHANNELS.alerts,
      CHANNELS.a,
      CHANNELS.b,
      CHANNELS.c,
      MY_DISCORD_ID,
      discordUsername,
      `${MAILBOX}@${MAIL_DOMAIN}`,
    ],
  );
  await c.query('commit');
  console.log('Demo data loaded:', JSON.stringify(r.result));

  // The testing channel's ID comes from Discord: ask WF6 to check the server and wait for it (up to 3 minutes).
  await c.query(`select private.queue_server_check($1)`, [SERVER_ID]);
  console.log('Asked n8n (WF4) to check the Sandbox server, to find #testing...');
  let testing: { id: string } | undefined;
  for (let i = 0; i < 36 && !testing; i++) {
    await new Promise((res) => setTimeout(res, 5000));
    testing = await one<{ id: string }>(
      `select id from public.discord_channel where server_id = $1 and name = 'testing' order by position limit 1`,
      [SERVER_ID],
    );
  }
  if (testing) {
    await c.query(
      `update public.domain set test_discord_channel_id = $1, version = version where name = 'Backend' and archived_at is null`,
      [testing.id],
    );
    console.log('Testing channel: #testing');
  } else {
    console.warn(
      'Warning: #testing was not found yet. Choose it on Setup, Domains, Backend, Testing channel.',
    );
  }
  const p = await one<{ problems: string | null }>(
    `select string_agg(distinct x ->> 'text', '; ') problems
       from public.module_week w join public.domain d on d.id = w.domain_id and d.name = 'Backend',
            jsonb_array_elements(private.readiness_problems(w.id)) x
      where (x ->> 'blocking')::boolean`,
  );
  console.log(
    p?.problems ? `Setup check problems: ${p.problems}` : 'Setup check: nothing blocks asking.',
  );
} catch (e) {
  await c.query('rollback').catch(() => undefined);
  console.error('Demo data was not loaded:', (e as Error).message);
  process.exitCode = 1;
} finally {
  await c.end();
}
