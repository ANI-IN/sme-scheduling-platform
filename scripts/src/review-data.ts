// Real exceptions on the Backend domain of the test data, for the owner's review pictures (review batch 3).
// Run it on the separate test stack only, after the test data is loaded:
//
//   npm run test-stack -w scripts -- up
//   npm run demo -w scripts -- load
//   npm run review-data -w scripts
//   (an app server on 5174, as help-screenshots.ts starts one)
//   npm run screenshots -w scripts -- --out review-batch3
//
// Every change goes through the app's own database functions, made as the screenshot team member (Operations on
// Backend and an admin) the way the database tests sign in: request.jwt.claims with their email, then
// "set local role authenticated". What an instructor or the automation does (answers, engine_tick, claiming and
// reporting messages) runs as the automation, as demo-data.ts does. One class week per exception:
//
//   clash             someone being asked for a class week is confirmed elsewhere at the same time (assign_manually)
//   shared class      a weekend and a weekday class week of one module become one class (share_class_weeks)
//   cohort merge      two small extra cohorts merge into "Combined cohort" (merge_cohorts, preview then save)
//   break             a one week break in the weekday cohort moves its later class weeks (add_break)
//   proposed time     the person being asked proposes an hour later (submit_response_page, Propose another time)
//   cohort holiday    a holiday on the day of a class (add_cohort_holiday)
//   moved             a class an hour later (change_class_time)
//   needs instructor  everyone in the instructor order says No (submit_response_page and engine_tick)
//   message failed    a confirmation message is not delivered (claim_outbound_messages, report_message_result)
//
// It writes the chosen class weeks to .test-stack/review-data.json, where screenshots.ts finds the cells to open.
// The pictures and what each one shows are listed in docs/screenshots/review-batch3/README.md.
import { randomUUID } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import pg from 'pg';
import { TEST_DB_URL, TEST_WORKDIR } from './test-stack.ts';

const MEMBER = (process.env.SHOT_EMAIL ?? 'ops.placeholder@example.com').toLowerCase();
const REASON = 'Made on purpose for the review pictures';
const WEEKEND = 'Weekend cohort';
const WEEKDAY = 'Weekday cohort';
/** The weekday cohort's class weeks from this one on are kept for the break, which moves them. */
const BREAK_AT = 5;
const SMALL = ['Small cohort A', 'Small cohort B'] as const;
const COMBINED = 'Combined cohort';
const FILE = join(TEST_WORKDIR, 'review-data.json');

type Week = {
  id: string;
  cohort_id: string;
  cohort: string;
  module_id: string;
  module: string;
  start: string;
  first_class_at: Date | null;
  status: string;
  n: number;
  booked: boolean;
  req: string | null;
  asked: string | null;
  shared: boolean;
};
type Json = Record<string, unknown>;
type ClassTime = { id: string; date: string; s: string; e: string; region: string };

const c = new pg.Client({ connectionString: TEST_DB_URL });
await c.connect();
const q = async <T>(sql: string, p: unknown[] = []) => (await c.query(sql, p)).rows as T[];
const one = async <T>(sql: string, p: unknown[] = []) => (await q<T>(sql, p))[0];

// Refuse anything but a local development database with the test data in it (as demo-data.ts does).
const env = await one<{ e: string }>(`select environment e from public.app_config where id = 1`);
if (env?.e !== 'Development')
  throw new Error(`Review data only goes into a local test stack, not ${env?.e}.`);
const dom = (
  await one<{ id: string }>(`select id from public.domain where name = 'Backend' limit 1`)
)?.id;
if (!dom)
  throw new Error('No Backend domain. Load the test data first: npm run demo -w scripts -- load');
if (await one(`select 1 from public.cohort where name = any($1::text[])`, [[...SMALL, COMBINED]]))
  throw new Error(
    'The review data is already there. Load the test data again first: npm run demo -w scripts -- load',
  );

let viaService = false;
let sub: string | undefined;
/** One statement as the team member, signed in the way the database tests do. */
async function member<T = { r: Json }>(sql: string, p: unknown[] = []): Promise<T[]> {
  sub ??=
    (
      await one<{ id: string | null }>(
        `select auth_user_id::text id from public.team_member where lower(email) = $1`,
        [MEMBER],
      )
    )?.id ?? randomUUID();
  await c.query('begin');
  try {
    await c.query(
      `select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.role', 'authenticated', true),
              set_config('app.actor_kind', '', true), set_config('app.actor_instructor_id', '', true),
              set_config('app.actor_label', '', true)`,
      [JSON.stringify({ sub, role: 'authenticated', aud: 'authenticated', email: MEMBER })],
    );
    await c.query('set local role authenticated');
    const rows = (await c.query(sql, p)).rows as T[];
    await c.query('commit');
    return rows;
  } catch (e) {
    await c.query('rollback');
    // Not allowed as the team member (sign in not set up in this copy): make the same call as the automation.
    if ((e as { code?: string }).code !== '42501') throw e;
    if (!viaService)
      console.warn(
        `  ! ${MEMBER} may not do this here (${(e as Error).message}), so it runs as the automation instead.`,
      );
    viaService = true;
    return q<T>(sql, p);
  }
}
/** The result of one function call made as the team member. */
const call = async (sql: string, p: unknown[] = []) => (await member(sql, p))[0]?.r ?? {};

// The automation and the instructors, as in demo-data.ts.
const deliver = async () => {
  const rows = await q<{ id: string }>('select id from public.claim_outbound_messages(500)');
  for (const m of rows) await q('select public.report_message_result($1, true)', [m.id]);
};
const tick = async () => {
  await q('select public.engine_tick($1, now())', [dom]);
  await deliver();
};
const openRequest = async (mw: string) =>
  (
    await one<{ id: string }>(
      `select id from public.request where module_week_id = $1 and kind = 'Outreach' and status in ('Sent', 'Reminded')
        order by created_at desc limit 1`,
      [mw],
    )
  )?.id;
/** The instructor's answer on the answer page, with the form fields the page sends. Null when nobody is asked. */
async function answer(mw: string, ans: string, form: Json = {}) {
  const req = await openRequest(mw);
  if (!req) return null;
  await q('select private.link_for($1, $2)', [req, ans]);
  const l = await one<{ token: string }>(
    `select token from public.response_link where request_id = $1 and answer = $2`,
    [req, ans],
  );
  const r = await one<{ page: string }>(`select public.submit_response_page($1, $2)::text page`, [
    l!.token,
    JSON.stringify({ t: l!.token, ...form }),
  ]);
  return (r?.page ?? '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

const weeks = () =>
  q<Week>(
    `select w.id, w.cohort_id, c.name cohort, w.module_id, m.name module, w.week_start_date::text start, w.first_class_at,
            w.status, (row_number() over (partition by w.cohort_id order by w.week_start_date, w.id) - 1)::int n,
            exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Active') booked,
            r.id req, r.instructor_id asked,
            (w.shared_with is not null or exists (select 1 from public.module_week g where g.shared_with = w.id)) shared
       from public.module_week w join public.cohort c on c.id = w.cohort_id join public.module m on m.id = w.module_id
       left join lateral (select x.id, x.instructor_id from public.request x where x.module_week_id = w.id
                            and x.kind = 'Outreach' and x.status in ('Sent', 'Reminded')
                          order by x.created_at desc limit 1) r on true
      where w.domain_id = $1 and c.name in ($2, $3)
      order by w.first_class_at, c.name`,
    [dom, WEEKEND, WEEKDAY],
  );
const used = new Set<string>();
/** Still to come (two days or more), untouched by this script and by the test data's own stories. */
const free = (w: Week) =>
  !used.has(w.id) &&
  !!w.first_class_at &&
  w.first_class_at.getTime() > Date.now() + 2 * 864e5 &&
  !['Cancelled', 'Completed', 'NeedsInstructor'].includes(w.status) &&
  !w.shared &&
  !(w.cohort === WEEKDAY && w.n >= BREAK_AT);
/** The first free class week that fits, from the preferred cohort first. */
const pick = (ws: Week[], ok: (w: Week) => boolean, prefer: string) =>
  ws
    .filter((w) => free(w) && ok(w))
    .sort((a, b) => Number(b.cohort === prefer) - Number(a.cohort === prefer))[0];
const monthDay = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC',
  });
const label = (w: Week) => `${w.module} for ${w.cohort}, week of ${monthDay(w.start)}`;
/** A class week's first planned class, in its own clock time, optionally moved by some minutes. */
const firstClass = async (mw: string, mins = 0) =>
  (await one<ClassTime>(
    `select id, to_char(starts_at at time zone private.region_tz(region), 'YYYY-MM-DD') date,
            to_char((starts_at at time zone private.region_tz(region)) + make_interval(mins => $2), 'HH24:MI') s,
            to_char((ends_at at time zone private.region_tz(region)) + make_interval(mins => $2), 'HH24:MI') e, region
       from public.class_session where module_week_id = $1 and status = 'Planned' order by starts_at limit 1`,
    [mw, mins],
  ))!;
const problems = async (mw: string) =>
  (
    await one<{ p: { code: string; level: string; text: string }[] }>(
      `select private.week_problems($1) p`,
      [mw],
    )
  )?.p ?? [];
const fail = (what: string, r: Json) => {
  throw new Error(`${what}: ${JSON.stringify(r).slice(0, 600)}`);
};

const manifest: Record<string, string> = {};
const summary: string[] = [];
async function step(name: string, fn: () => Promise<string>) {
  try {
    summary.push(`  ✓ ${name}: ${await fn()}`);
  } catch (e) {
    summary.push(`  ! ${name}: not made. ${(e as Error).message.split('\n')[0]}`);
  }
}

// Two small extra cohorts for the clash and the merge: three class weeks each, a week apart, at the time given.
let small: { ids: string[]; first: string; date: string; region: string } | undefined;
async function smallCohorts(at?: ClassTime) {
  if (small) return small;
  const t =
    at ??
    (await one<ClassTime>(
      `select null id, to_char((now() at time zone 'America/Los_Angeles')::date + 10, 'YYYY-MM-DD') date,
              '18:00' s, '20:00' e, 'US' region`,
    ))!;
  const mods = await q<{ id: string }>(
    `select id from public.module where domain_id = $1 and status = 'Active' order by rotation_order, name limit 3`,
    [dom],
  );
  const ids: string[] = [];
  for (const name of SMALL) {
    const co = (
      await member<{ id: string }>(
        `insert into public.cohort (domain_id, name, region, start_date, status)
         values ($1, $2, $3, $4::date, 'Running') returning id`,
        [dom, name, t.region, t.date],
      )
    )[0]!;
    ids.push(co.id);
    for (const [i, m] of mods.entries()) {
      const r = await call(
        `select public.add_one_class(p_module_week_id => null, p_module_id => $1, p_cohort_id => $2,
                  p_date => $3::date + $4::int, p_start => $5::time, p_end => $6::time, p_class_type => 'Live class',
                  p_accept_warnings => true, p_reason => $7) r`,
        [m.id, co.id, t.date, 7 * i, t.s, t.e, REASON],
      );
      if (r.ok !== true) fail(`Adding a class to ${name}`, r);
    }
  }
  const first = (await one<{ id: string }>(
    `select id from public.module_week where cohort_id = $1 order by week_start_date limit 1`,
    [ids[0]],
  ))!.id;
  small = { ids, first, date: t.date, region: t.region };
  return small;
}

// 1. Needs instructor: everyone in the order says No, and the next one is asked each time.
await step('needs instructor', async () => {
  const w = pick(await weeks(), (x) => !!x.req && !x.booked, WEEKDAY);
  if (!w) throw new Error('no class week is being asked.');
  used.add(w.id);
  manifest['needs-instructor'] = w.id;
  let n = 0;
  while (n < 8 && (await answer(w.id, 'No')) !== null) {
    n++;
    await deliver();
    await tick();
  }
  const s = (await one<{ status: string; at_risk: boolean }>(
    `select status, at_risk from public.module_week where id = $1`,
    [w.id],
  ))!;
  if (s.status !== 'NeedsInstructor' && !s.at_risk)
    throw new Error(`${label(w)} is ${s.status} after ${n} answers of No.`);
  return `${label(w)}: ${n} instructors said No, so nobody is left to ask.`;
});

// 2. Proposed time: the person being asked proposes the first class an hour later.
await step('proposed time', async () => {
  const w = pick(await weeks(), (x) => !!x.req && !x.booked, WEEKEND);
  if (!w) throw new Error('no class week is being asked.');
  used.add(w.id);
  manifest['proposed-time'] = w.id;
  const f = (await one<{ form: Json }>(
    `with k as (select c.*, row_number() over (order by c.starts_at, c.id) n,
                       (c.starts_at at time zone private.region_tz(c.region)) ls,
                       (c.ends_at at time zone private.region_tz(c.region)) le
                  from public.class_session c where c.module_week_id = $1 and c.status = 'Planned')
     select jsonb_object_agg(x.key, x.value) form from k, lateral (values
              ('c_' || n, to_jsonb(id::text)), ('d_' || n, to_jsonb(to_char(ls, 'YYYY-MM-DD'))),
              ('s_' || n, to_jsonb(to_char(ls + case when n = 1 then interval '1 hour' else interval '0' end, 'HH24:MI'))),
              ('e_' || n, to_jsonb(to_char(le + case when n = 1 then interval '1 hour' else interval '0' end, 'HH24:MI')))) x(key, value)`,
    [w.id],
  ))!;
  const page = await answer(w.id, 'ProposeTime', {
    ...f.form,
    note: 'An hour later suits me better that week.',
  });
  const p = await one(
    `select 1 from public.time_proposal where module_week_id = $1 and status = 'Pending'`,
    [w.id],
  );
  if (!p) throw new Error(`${label(w)}: the answer page said "${page}".`);
  return `${label(w)}: the person being asked proposes the first class an hour later.`;
});

// 3. Shared class: a weekend class week hosts the weekday class week of the same module in the same week.
await step('shared class', async () => {
  const ws = await weeks();
  const day = (iso: string) => Date.parse(`${iso}T12:00:00Z`) / 864e5;
  let host: Week | undefined;
  let guest: Week | undefined;
  for (const h of ws) {
    if (!free(h) || h.cohort !== WEEKEND || h.booked) continue;
    guest = ws.find(
      (g) =>
        free(g) &&
        g.cohort === WEEKDAY &&
        !g.booked &&
        g.module_id === h.module_id &&
        day(h.start) - day(g.start) >= 0 &&
        day(h.start) - day(g.start) < 7,
    );
    if (guest) {
      host = h;
      break;
    }
  }
  if (!host || !guest)
    throw new Error('no weekend and weekday class weeks of one module to share.');
  used.add(host.id).add(guest.id);
  manifest['shared-class'] = guest.id;
  manifest['shared-class-host'] = host.id;
  const args = `p_host_id => $1, p_guest_ids => $2::uuid[], p_times_from => $1, p_release_instructors => false`;
  const pre = await call(`select public.share_class_weeks(${args}, p_save => false) r`, [
    host.id,
    [guest.id],
  ]);
  if (((pre.blocks as unknown[]) ?? []).length) fail('The share preview blocks it', pre);
  const r = await call(
    `select public.share_class_weeks(${args}, p_save => true, p_accept_warnings => true, p_reason => $3) r`,
    [host.id, [guest.id], REASON],
  );
  if (r.ok !== true) fail('Sharing', r);
  return `${label(guest)} is taught in the class of ${label(host)}.`;
});

// 4. Clash: the person being asked for a class week is confirmed for Small cohort A at the same time.
await step('clash', async () => {
  const w = pick(await weeks(), (x) => !!x.req && !!x.asked && !x.booked, WEEKDAY);
  if (!w) throw new Error('no class week is being asked.');
  used.add(w.id);
  manifest['clash'] = w.id;
  const s = await smallCohorts(await firstClass(w.id));
  const r = await call(
    `select public.assign_manually(p_module_week_id => $1, p_instructor_id => $2, p_note => 'Confirmed on a call',
              p_accept_warnings => true, p_reason => $3) r`,
    [s.first, w.asked, REASON],
  );
  if (r.ok !== true) fail('Confirming the instructor for Small cohort A', r);
  const who = (await one<{ name: string }>(
    `select full_name name from public.instructor where id = $1`,
    [w.asked],
  ))!.name;
  if (!(await problems(w.id)).some((x) => x.code === 'clash'))
    throw new Error(`${label(w)} shows no clash after confirming ${who} for Small cohort A.`);
  return `${who} is being asked for ${label(w)} and is confirmed for Small cohort A at the same time.`;
});

// 5. Cohort merge: Small cohort A and Small cohort B continue as Combined cohort from their second class week.
await step('cohort merge', async () => {
  const s = await smallCohorts();
  const from = (await one<{ d: string }>(`select ($1::date + 7)::text d`, [s.date]))!.d;
  const args = `p_cohort_ids => $1::uuid[], p_date => $2::date, p_sequence_from => $3, p_order_from => $3,
                p_name => $4, p_region => $5`;
  const pre = await call(`select public.merge_cohorts(${args}, p_save => false) r`, [
    s.ids,
    from,
    s.ids[0],
    COMBINED,
    s.region,
  ]);
  if (((pre.blocks as unknown[]) ?? []).length) fail('The merge preview blocks it', pre);
  const r = await call(
    `select public.merge_cohorts(${args}, p_save => true, p_accept_warnings => true, p_reason => $6) r`,
    [s.ids, from, s.ids[0], COMBINED, s.region, REASON],
  );
  if (r.ok !== true) fail('Merging', r);
  const first = await one<{ id: string }>(
    `select id from public.module_week where cohort_id = $1 order by week_start_date limit 1`,
    [r.cohort_id],
  );
  if (first) manifest['merge'] = first.id;
  return `${SMALL.join(' and ')} merged into ${COMBINED} from ${monthDay(from)}: ${String(r.moved)} class weeks moved, ${String(r.cancelled)} cancelled.`;
});

// 6. Moved: a class an hour later than planned.
await step('moved', async () => {
  const w = pick(await weeks(), (x) => !x.booked, WEEKEND);
  if (!w) throw new Error('no class week without a confirmed instructor.');
  used.add(w.id);
  manifest['moved'] = w.id;
  const k = await firstClass(w.id, 60);
  const r = await call(
    `select public.change_class_time(p_class_id => $1, p_date => $2::date, p_start => $3::time, p_end => $4::time,
              p_accept_warnings => true, p_reason => $5) r`,
    [k.id, k.date, k.s, k.e, REASON],
  );
  if (r.needs_confirmation || r.unchanged) fail('Moving the class', r);
  return `${label(w)}: the first class moved to ${k.s} on ${monthDay(k.date)}.`;
});

// 7. Cohort holiday on the day of a class.
await step('cohort holiday', async () => {
  const w = pick(await weeks(), () => true, WEEKDAY);
  if (!w) throw new Error('no class week left.');
  used.add(w.id);
  manifest['cohort-holiday'] = w.id;
  const k = await firstClass(w.id);
  const r = await call(
    `select public.add_cohort_holiday(p_cohort_id => $1, p_date => $2::date, p_name => 'Founders day') r`,
    [w.cohort_id, k.date],
  );
  if (!((r.classes as unknown[]) ?? []).length) fail('The holiday has no class on it', r);
  return `${w.cohort} has Founders day on ${monthDay(k.date)}, the day of a class of ${label(w)}.`;
});

// 8. Break: one week for the weekday cohort, so its later class weeks move a week.
await step('break', async () => {
  const w = (await weeks()).find((x) => x.cohort === WEEKDAY && x.n === BREAK_AT);
  if (!w) throw new Error(`the weekday cohort has no class week number ${BREAK_AT + 1}.`);
  manifest['break'] = w.id;
  const args = `p_domain_id => $1, p_cohort_ids => $2::uuid[], p_starts_on => $3::date, p_weeks => 1,
                p_reason => 'Winter break', p_program => false`;
  const pre = await call(`select public.add_break(${args}, p_save => false) r`, [
    dom,
    [w.cohort_id],
    w.start,
  ]);
  if (((pre.blocks as unknown[]) ?? []).length) fail('The break preview blocks it', pre);
  const r = await call(
    `select public.add_break(${args}, p_save => true, p_accept_warnings => true, p_accept_reason => $4) r`,
    [dom, [w.cohort_id], w.start, REASON],
  );
  if (r.ok !== true) fail('Adding the break', r);
  return `${w.cohort}: Winter break from ${monthDay(w.start)} for one week, so ${String(r.saved)} class weeks moved a week later (${w.module} first).`;
});

// 9. Message failed: an instructor is confirmed, and the message about it is not delivered.
await step('message failed', async () => {
  const w = pick(await weeks(), (x) => !x.booked, WEEKEND);
  if (!w) throw new Error('no class week without a confirmed instructor.');
  used.add(w.id);
  manifest['message-failed'] = w.id;
  const people = await q<{ id: string; name: string }>(
    `select i.id, i.full_name name from public.module_ranking k join public.instructor i on i.id = k.instructor_id
      where k.module_id = $1 and (k.cohort_id is null or k.cohort_id = $2) order by k.rank`,
    [w.module_id, w.cohort_id],
  );
  let who: string | undefined;
  let why = '';
  for (const p of people) {
    try {
      const r = await call(
        `select public.assign_manually(p_module_week_id => $1, p_instructor_id => $2, p_note => 'Confirmed on a call',
                  p_accept_warnings => true, p_reason => $3) r`,
        [w.id, p.id, REASON],
      );
      if (r.ok === true) {
        who = p.name;
        break;
      }
      why = JSON.stringify(r);
    } catch (e) {
      why = (e as Error).message;
    }
  }
  if (!who) throw new Error(`nobody could be confirmed for ${label(w)}: ${why}`);
  // The automation takes every waiting message: the first about this class week fails, the others are sent.
  let failed = false;
  for (let round = 0; round < 20; round++) {
    const ms = await q<{ id: string; module_week_id: string | null; audience: string }>(
      'select id, module_week_id, audience from public.claim_outbound_messages(100)',
    );
    if (!ms.length) break;
    const target = failed
      ? undefined
      : (ms.find((m) => m.module_week_id === w.id && m.audience === 'Instructor') ??
        ms.find((m) => m.module_week_id === w.id));
    for (const m of ms) {
      if (m === target)
        await q(
          `select public.report_message_result(p_message_id => $1, p_ok => false, p_error => 'Mailbox not found',
                    p_permanent => true)`,
          [m.id],
        );
      else await q('select public.report_message_result($1, true)', [m.id]);
    }
    if (target) failed = true;
  }
  if (
    !(await one(`select 1 from public.message where module_week_id = $1 and status = 'Failed'`, [
      w.id,
    ]))
  )
    throw new Error(
      `${who} is confirmed for ${label(w)}, but no message about it was waiting to fail.`,
    );
  return `${who} is confirmed for ${label(w)}, and the message about it failed: Mailbox not found.`;
});

mkdirSync(TEST_WORKDIR, { recursive: true });
writeFileSync(FILE, JSON.stringify(manifest, null, 2));
await c.query('analyze');
await c.end();
console.log(`Review data on Backend${viaService ? ' (some steps as the automation)' : ''}:`);
for (const s of summary) console.log(s);
console.log(`Class weeks for the pictures: ${FILE}`);
if (summary.some((s) => s.startsWith('  !'))) process.exitCode = 1;
