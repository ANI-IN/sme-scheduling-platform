// Mock mode (M6): run the real engine and print every message that n8n would send; no Discord,
// Gmail or n8n needed. Clicks are simulated through the same confirm-page functions n8n WF2 calls
// (GET shows the page, POST records the answer).
//
//   npm run mock                 # full timeline
//   npm run mock -- --race       # also run a real two-connection "double Yes" race
//
// Everything runs in a throwaway scratch database built from the migrations and dropped at the
// end, so the app's database is never touched. Requires the local Supabase stack
// (npm run db:start). DATABASE_URL overrides the server connection.
import pg from 'pg';
import { createScratchDb } from './scratch-db.ts';

const serverUrl =
  process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:55422/postgres';
let url = serverUrl;
const RACE = process.argv.includes('--race');

type Msg = {
  id: string;
  template_id: string;
  channel: string;
  recipient_label: string | null;
  to_address: string | null;
  discord_channel_id: string | null;
  discord_dm_user_id: string | null;
  subject: string | null;
  body_text: string | null;
  buttons: { label: string; answer: string; url: string }[];
};

let c: pg.Client;
const line = (s = '') => console.log(s);
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, '')
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&');
const pt = (iso: string) =>
  new Date(iso).toLocaleString('en-US', {
    timeZone: 'America/Los_Angeles',
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZoneName: 'short',
  });

async function one<T = Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T> {
  const r = await c.query(sql, params);
  return r.rows[0] as T;
}

/** What n8n WF4 does: claim the outbox, "send", report success. */
async function deliver(label: string) {
  const { rows } = await c.query<Msg>('select * from public.claim_outbound_messages(100)');
  line(`\n── ${label} — ${rows.length} message(s) sent`);
  for (const m of rows) {
    const to =
      m.channel === 'Email'
        ? m.to_address
        : m.discord_dm_user_id
          ? `DM ${m.discord_dm_user_id}`
          : `#${m.discord_channel_id}`;
    line(
      `  ✉ ${m.template_id.padEnd(4)} ${m.channel.padEnd(7)} → ${m.recipient_label ?? '?'} (${to})`,
    );
    if (m.channel === 'Discord' || m.template_id.startsWith('T') || m.template_id === 'R1') {
      const body = (m.body_text ?? '').split('\n').filter(Boolean).slice(0, 4).join(' ⏎ ');
      line(`      ${body.slice(0, 220)}`);
    }
    if (m.buttons?.length) line(`      buttons: ${m.buttons.map((b) => `[${b.label}]`).join(' ')}`);
    await c.query('select public.report_message_result($1, true, $2)', [
      m.id,
      `mock-${m.id.slice(0, 8)}`,
    ]);
  }
}

async function tick(domain: string, at: string, label: string) {
  await c.query(`select set_config('app.test_now', $1, true)`, [at]);
  const r = await one<{ v: Record<string, unknown> }>('select public.engine_tick($1, $2) as v', [
    domain,
    at,
  ]);
  line(
    `\n▶ ${label}  (${pt(at)})  engine: ${JSON.stringify(Object.fromEntries(Object.entries(r.v).filter(([k, v]) => typeof v === 'number' && v > 0)))}`,
  );
  await deliver(label);
}

async function token(mw: string, instructor: string, answer: string): Promise<string> {
  const r = await one<{ token: string }>(
    `select l.token from public.response_link l join public.request r on r.id = l.request_id
      where r.module_week_id = $1 and r.instructor_id = $2 and l.answer = $3 order by r.created_at desc limit 1`,
    [mw, instructor, answer],
  );
  return r.token;
}

/** What n8n WF2 does: GET renders the page (records nothing), POST records the answer. */
async function click(
  mw: string,
  instructor: string,
  name: string,
  answer: string,
  form: Record<string, string> = {},
) {
  const t = await token(mw, instructor, answer);
  const page = (await one<{ html: string }>('select public.response_page($1)::text as html', [t]))
    .html;
  const h1 = text(page.match(/<h1>(.*?)<\/h1>/)?.[1] ?? '');
  line(`\n👆 ${name} opens the "${answer}" link → page: “${h1}” (nothing recorded yet)`);
  const res = (
    await one<{ html: string }>('select public.submit_response_page($1, $2)::text as html', [
      t,
      JSON.stringify({ t, ...form }),
    ])
  ).html;
  const msg = text(res.match(/<p>(.*?)<\/p>/)?.[1] ?? '');
  line(`   …presses the button → “${text(res.match(/<h1>(.*?)<\/h1>/)?.[1] ?? '')}” ${msg}`);
}

async function status(mw: string) {
  const r = await one<{
    status: string;
    at_risk: boolean;
    asking: string | null;
    booked: string | null;
  }>(
    `select w.status, w.at_risk,
            (select i.full_name from public.request q join public.instructor i on i.id = q.instructor_id
              where q.module_week_id = w.id and q.kind = 'Outreach' and q.status in ('Sent','Reminded')) as asking,
            (select i.full_name from public.booking b join public.instructor i on i.id = b.instructor_id
              where b.module_week_id = w.id and b.status = 'Active') as booked
       from public.module_week w where w.id = $1`,
    [mw],
  );
  line(
    `   ⇒ module week: ${r.status}${r.at_risk ? ' (AT RISK)' : ''}${r.asking ? ` · asking ${r.asking}` : ''}${r.booked ? ` · booked ${r.booked}` : ''}`,
  );
}

async function setup(prefix: string, status: 'Test' | 'Live') {
  const dom = await one<{ id: string }>(
    `insert into public.domain (name, status, alert_discord_channel_id, test_discord_channel_id, test_email)
     values ($1, $2, '100000000000000001', '100000000000000002', 'test-inbox@example.com') returning id`,
    [`${prefix} domain`, status],
  );
  const owner = await one<{ id: string }>(
    `insert into public.team_member (name, email, discord_user_id, job_title) values ($1, $2, '200000000000000001', 'Product manager') returning id`,
    [`${prefix} Owner`, `${prefix.toLowerCase()}.owner@example.com`],
  );
  const ops = await one<{ id: string }>(
    `insert into public.team_member (name, email, discord_user_id, job_title) values ($1, $2, '200000000000000002', 'Operations') returning id`,
    [`${prefix} Ops`, `${prefix.toLowerCase()}.ops@example.com`],
  );
  await c.query(
    `insert into public.domain_team (domain_id, team_member_id, role) values ($1, $2, 'Operations'), ($1, $3, 'Escalation')`,
    [dom.id, ops.id, owner.id],
  );
  const mod = await one<{ id: string }>(
    `insert into public.module (domain_id, name) values ($1, 'Concurrency') returning id`,
    [dom.id],
  );
  await c.query(`insert into public.module_owner (module_id, team_member_id) values ($1, $2)`, [
    mod.id,
    owner.id,
  ]);
  await c.query(
    `insert into public.module_resource (module_id, title, url) values ($1, 'Concurrency module', 'https://example.com/concurrency')`,
    [mod.id],
  );
  await c.query(
    `insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
     values ($1, 'Live class', '{module}: Live class', 0, '09:00', 240, 1), ($1, 'Assignment review', '{module}: Assignment review', 4, '18:00', 120, 2)`,
    [mod.id],
  );
  const ids: string[] = [];
  for (const [n, name] of ['Felix Sandoval', 'Robin Kessler', 'Shelly Carver'].entries()) {
    const i = await one<{ id: string }>(
      `insert into public.instructor (full_name, primary_email, discord_user_id, discord_channel_id, verified_at, is_test)
       values ($1, $2, $3, $4, now(), $5) returning id`,
      [
        `${prefix} ${name}`,
        `${prefix.toLowerCase()}.${n}@example.org`,
        `30000000000000000${n}`,
        `40000000000000000${n}`,
        false,
      ],
    );
    ids.push(i.id);
    await c.query(
      `insert into public.module_ranking (module_id, instructor_id, rank) values ($1, $2, $3)`,
      [mod.id, i.id, n + 1],
    );
  }
  const weeks = await one<{ v: { module_week_ids: string[] } }>(
    `select public.create_module_weeks($1, (select jsonb_agg(jsonb_build_object('module_id', $2::uuid, 'week_start_date', w ->> 'week_start_date', 'classes', w -> 'classes'))
                                              from jsonb_array_elements(public.generate_classes($1, $2, array['2027-01-31']::date[])) w)) as v`,
    [dom.id, mod.id],
  );
  return {
    dom: dom.id,
    mw: weeks.v.module_week_ids[0]!,
    i: ids,
    names: ['Felix', 'Robin', 'Shelly'],
  };
}

async function timeline() {
  line(
    '═════ Mock run: Concurrency module week, live class Sun Jan 31 2027 9:00 AM PST (PRD Appendix B) ═════',
  );
  await c.query('begin');
  // Hold anything already waiting in the local outbox so only this run's messages are shown.
  await c.query(
    `update public.message set status = 'Cancelled' where status in ('Pending', 'Scheduled', 'Sending')`,
  );
  const s = await setup('Mock', 'Live');
  const [, robin, shelly] = s.i as [string, string, string];

  await tick(s.dom, '2026-12-17T18:00:00Z', 'Readiness check (45 days)');
  await status(s.mw);
  await tick(s.dom, '2027-01-01T17:00:00Z', 'Outreach starts (30 days) — Felix asked');
  await status(s.mw);
  await tick(s.dom, '2027-01-02T17:00:00Z', 'No answer → reminder (24h)');
  await tick(s.dom, '2027-01-03T17:00:00Z', 'No answer → close politely, ask Robin (48h)');
  await status(s.mw);
  await click(s.mw, robin, 'Robin', 'No');
  await deliver('After Robin says no');
  await status(s.mw);
  await click(s.mw, shelly, 'Shelly', 'Yes');
  await click(s.mw, shelly, 'Shelly', 'Yes');
  await deliver('After the Yes (second tap shows "Already recorded")');
  await status(s.mw);
  await tick(
    s.dom,
    '2027-01-06T18:00:00Z',
    'Checklist nudge (3 days after confirmation; goes in the ops digest)',
  );
  await tick(s.dom, '2027-01-17T18:00:00Z', 'Owner check-in (14 days)');
  await tick(s.dom, '2027-01-21T18:00:00Z', 'Instructor check-in (10 days)');
  await click(s.mw, shelly, 'Shelly', 'NeedHelp', {
    cat_zoom: '1',
    details: 'No Zoom link yet',
    urgency: 'Within24h',
    reply_channel: 'Either',
  });
  await deliver('After the help request');
  await tick(s.dom, '2027-01-21T22:30:00Z', 'Half-time help reminder (target 8h)');
  await tick(s.dom, '2027-01-22T02:30:00Z', 'Help target passed with no reply → escalation');
  await tick(s.dom, '2027-01-29T18:00:00Z', 'Final check-in (2 days)');
  await click(s.mw, shelly, 'Shelly', 'CantMakeIt');
  await deliver('After "Can\'t make it" 2 days before');
  await status(s.mw);
  const items = await c.query(
    `select severity, type, title from public.attention_item where domain_id = $1 and status <> 'Done' order by severity desc, created_at`,
    [s.dom],
  );
  line('\n── Needs Attention now:');
  for (const a of items.rows)
    line(`  ${a.severity === 'Urgent' ? '🚨' : '•'} [${a.type}] ${a.title}`);
  const hist = await one<{ n: string }>(
    `select count(*) as n from public.history_event where domain_id = $1 or module_week_id = $2`,
    [s.dom, s.mw],
  );
  line(`\nHistory entries recorded for this run: ${hist.n}`);
  await c.query('rollback');
  line('\n(Rolled back.)');
}

/** Two real connections press the same Yes link at the same moment → exactly one booking. */
async function race() {
  line('\n═════ Race: the same "Yes" pressed twice at the same moment (Discord + email) ═════');
  const s = await setup(`Race${Date.now() % 100000}`, 'Live');
  await c.query(`select set_config('app.test_now', '2027-01-01T17:00:00Z', false)`);
  await c.query(`select public.engine_tick($1, '2027-01-01T17:00:00Z')`, [s.dom]);
  const t = await token(s.mw, s.i[0]!, 'Yes');
  const a = new pg.Client({ connectionString: url });
  const b = new pg.Client({ connectionString: url });
  await Promise.all([a.connect(), b.connect()]);
  // When something fails, the scratch database is dropped while these are open: do not crash on that.
  a.on('error', () => {});
  b.on('error', () => {});
  const press = (cl: pg.Client) =>
    cl
      .query(`select set_config('app.test_now', '2027-01-01T18:00:00Z', false); `)
      .then(() => cl.query('select public.record_response($1) ->> $2 as r', [t, 'result']));
  const [ra, rb] = await Promise.all([press(a), press(b)]);
  const n = await one<{ n: string }>(
    `select count(*) as n from public.booking where module_week_id = $1`,
    [s.mw],
  );
  line(
    `  connection A → ${ra.rows[0].r}, connection B → ${rb.rows[0].r}; bookings created: ${n.n}`,
  );
  const one1 = Number(n.n) === 1 && [ra.rows[0].r, rb.rows[0].r].includes('confirmed');
  line(one1 ? '  ✓ exactly one booking' : '  ✗ UNEXPECTED');
  // TST-5: a race that goes wrong fails the run (and CI), not only the printout.
  if (!one1) process.exitCode = 1;

  // Release 3 M7 (decision 296): two class weeks at overlapping times start asking at the same moment on two
  // connections, and both want the same instructor. Only the sooner week may ask them: exactly one open request.
  line(
    '\n═════ Race: two overlapping class weeks ask the same instructor at the same moment ═════',
  );
  const both: string[] = [];
  for (const name of ['Overlap A', 'Overlap B']) {
    const m = await one<{ id: string }>(
      `insert into public.module (domain_id, name) values ($1, $2) returning id`,
      [s.dom, name],
    );
    await c.query(
      `insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
       values ($1, 'Live class', '{module}: Live class', 0, '09:00', 240, 1)`,
      [m.id],
    );
    await c.query(
      `insert into public.module_ranking (module_id, instructor_id, rank) values ($1, $2, 1)`,
      [m.id, s.i[1]],
    );
    // An owner, so the setup check lets the week be asked. Materials are no longer needed (decision 269); the
    // resource row below is unused and harmless.
    await c.query(
      `insert into public.module_owner (module_id, team_member_id)
       select $1, o.team_member_id from public.module_owner o join public.module m on m.id = o.module_id
        where m.domain_id = $2 limit 1`,
      [m.id, s.dom],
    );
    await c.query(
      `insert into public.module_resource (module_id, title, url) values ($1, 'Materials', 'https://example.com/materials')`,
      [m.id],
    );
    const w = await one<{ v: { module_week_ids: string[] } }>(
      `select public.create_module_weeks($1, (select jsonb_agg(jsonb_build_object('module_id', $2::uuid, 'week_start_date', w ->> 'week_start_date', 'classes', w -> 'classes'))
                                                from jsonb_array_elements(public.generate_classes($1, $2, array['2027-02-07']::date[])) w),
                                     true, 'Two modules at the same time on purpose: the race needs overlapping weeks') as v`,
      [s.dom, m.id],
    );
    both.push(w.v.module_week_ids[0]!);
  }
  // Both weeks are ready; each connection starts asking for one of them at the same moment.
  await c.query(`update public.module_week set status = 'Ready' where id = any($1::uuid[])`, [
    both,
  ]);
  const askOn = (cl: pg.Client, mw: string) =>
    cl.query(`select private.ask_next($1, '2027-01-08T17:00:00Z') as r`, [mw]);
  await Promise.all([askOn(a, both[0]!), askOn(b, both[1]!)]);
  const open = await c.query<{ module_week_id: string }>(
    `select module_week_id from public.request
      where instructor_id = $1 and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded')
        and module_week_id = any($2::uuid[])`,
    [s.i[1], both],
  );
  const sooner = await one<{ w: string }>(
    `select case when private.week_sooner($1, $2) then $1 else $2 end as w`,
    [both[0], both[1]],
  );
  line(
    `  open requests to the instructor: ${open.rows.length}, for the sooner week: ${open.rows[0]?.module_week_id === sooner.w}`,
  );
  const ok2 = open.rows.length === 1 && open.rows[0]!.module_week_id === sooner.w;
  line(ok2 ? '  ✓ one request, for the sooner class week' : '  ✗ UNEXPECTED');
  if (!ok2) process.exitCode = 1;
  await Promise.all([a.end(), b.end()]);
}

async function main() {
  const scratch = await createScratchDb(serverUrl);
  url = scratch.url;
  c = new pg.Client({ connectionString: url });
  await c.connect();
  try {
    await c.query(`update public.app_config set app_base_url = 'http://localhost:5173',
                   response_base_url = 'http://localhost:5678/webhook/respond' where id = 1`);
    await timeline();
    if (RACE) await race();
  } finally {
    await c.end();
    await scratch.drop();
    line('\n(Scratch database removed; the app database was not touched.)');
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
