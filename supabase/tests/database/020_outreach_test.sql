-- M2 scenarios (PRD 20.3): readiness, sequential outreach, reminder, move-on, decline, yes,
-- double clicks, scanner protection, write-before-send idempotency, outage catch-up.
-- Module week: Concurrency, live class Sun Jan 31 2027 9:00 AM PST (17:00 UTC), review Thu Feb 4.
begin;
\ir ../helpers/helpers.psql
select plan(46);

select tests.scenario('BE1') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset

-- ---------------------------------------------------------------- before the readiness point
select tests.tick(:'dom', '2026-12-10 18:00+00');
select is(tests.mw_status(:'mw'), 'Planned', 'before 45 days nothing happens');

-- ---------------------------------------------------------------- readiness (45 days)
select tests.tick(:'dom', '2026-12-17 18:00+00');
select is(tests.mw_status(:'mw'), 'Ready', 'readiness check passes at 45 days → Ready');
select is((select count(*)::int from public.request where module_week_id = :'mw'), 0, 'no outreach before 30 days');

-- ---------------------------------------------------------------- outreach starts (30 days)
select tests.tick(:'dom', '2027-01-01 18:00+00');   -- 10:00 AM PST
select is(tests.mw_status(:'mw'), 'Asking', 'outreach starts at 30 days');
select is(tests.asking(:'mw'), 'BE1 Instr1', 'the primary (rank 1) is asked first');
select is(tests.msgs(:'mw', 'M1'), 2, 'M1 queued on Discord and email together');
select is((select count(*)::int from public.message where module_week_id = :'mw' and template_id = 'M1' and status = 'Pending'), 2,
  'M1 is ready to send (inside allowed hours)');
select is(tests.msgs(:'mw', 'T1'), 1, 'owner tagged: outreach started (T1)');
select is((select reminder_at from public.request where module_week_id = :'mw' and status = 'Sent'), '2027-01-02 18:00+00'::timestamptz,
  'more than 10 days out: reminder after 24h');
select is((select deadline_at from public.request where module_week_id = :'mw' and status = 'Sent'), '2027-01-03 18:00+00'::timestamptz,
  'more than 10 days out: move on after 48h');
select ok((select body_text from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Discord')
          like '%Live class: Sun, Jan 31 · 9:00 AM to 1:00 PM PST%', 'M1 shows the class in PT with PST label');
select ok((select body_text from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Discord')
          like 'Hi <@%', 'Discord message @mentions the instructor');
select is((select jsonb_array_length(buttons) from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Email'), 2,
  'two link buttons: Yes / No');

-- idempotent: running again at the same time sends nothing new
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.tick(:'dom', '2027-01-01 19:00+00');
select is(tests.msgs(:'mw', 'M1'), 2, 'repeat runs never duplicate messages');
select is((select count(*)::int from public.request where module_week_id = :'mw'), 1, 'still exactly one request');

-- ---------------------------------------------------------------- scanner protection
select ok(public.response_page(tests.token(:'mw', :'i1', 'Yes')) like '%Confirming as%BE1 Instr1%', 'opening the link shows a confirm page with the name');
select is((select status from public.request where module_week_id = :'mw' and instructor_id = :'i1'), 'Sent',
  'opening the link (GET) records nothing');

-- ---------------------------------------------------------------- no reply → reminder → move on
select tests.tick(:'dom', '2027-01-02 18:00+00');
select is((select status from public.request where module_week_id = :'mw' and instructor_id = :'i1'), 'Reminded', 'reminder after 24h');
select is(tests.msgs(:'mw', 'M2'), 2, 'M2 reminder queued on both channels');
select tests.tick(:'dom', '2027-01-03 18:00+00');
select is((select status from public.request where module_week_id = :'mw' and instructor_id = :'i1'), 'Expired', 'request closes after 48h');
select is(tests.msgs(:'mw', 'M3'), 2, 'polite close (M3) sent');
select is(tests.asking(:'mw'), 'BE1 Instr2', 'the next instructor is asked');
select is(tests.msgs(:'mw', 'T3'), 0, 'more than 10 days out: no immediate T3 (owner sees it in the digest)');

-- late "Yes" from the first instructor
select is(tests.click(:'mw', :'i1', 'Yes'), 'closed', 'a late Yes after the request closed changes nothing');
select is((select count(*)::int from public.attention_item where module_week_id = :'mw' and type = 'LateReply'), 1,
  'late Yes creates an attention item for ops');

-- ---------------------------------------------------------------- decline → next
select is(tests.click(:'mw', :'i2', 'No'), 'declined', 'No is recorded');
select is(tests.asking(:'mw'), 'BE1 Instr3', 'after a No the next instructor is asked immediately');
select is((select count(*)::int from public.request where module_week_id = :'mw' and status in ('Sent', 'Reminded')), 1,
  'never more than one open request');

-- ---------------------------------------------------------------- Yes → confirmed
select is(tests.click(:'mw', :'i3', 'Yes'), 'confirmed', 'Yes confirms automatically');
select is(tests.mw_status(:'mw'), 'Confirmed', 'module week Confirmed');
select is(tests.booked(:'mw'), 'BE1 Instr3', 'booking created for the instructor who said yes');
select is((select count(*)::int from public.booking_slot s join public.booking b on b.id = s.booking_id where b.module_week_id = :'mw' and s.active), 2,
  'booking covers both classes of the module week');
select is(tests.msgs(:'mw', 'M4'), 2, 'confirmation (M4) sent on both channels');
select ok((select body_text from public.message where module_week_id = :'mw' and template_id = 'M4' and channel = 'Email') like '%Materials:%',
  'confirmation includes materials');
select is(tests.msgs(:'mw', 'T2'), 1, 'owner tagged on confirmation (T2)');
select is((select count(*)::int from public.checklist_item ci join public.class_session c on c.id = ci.class_id where c.module_week_id = :'mw'), 6,
  'checklist created: 3 default items × 2 classes');

-- CNF-6: Yes in both channels (same link) and a second different click
select is(tests.click(:'mw', :'i3', 'Yes'), 'already_recorded', 'second Yes click shows "Already recorded"');
select is(tests.click(:'mw', :'i3', 'No'), 'already_recorded', 'a No after the Yes changes nothing');
select is((select count(*)::int from public.booking where module_week_id = :'mw'), 1, 'still exactly one booking');
select ok(public.response_page(tests.token(:'mw', :'i3', 'Yes')) like '%Already recorded%', 'used link shows Already recorded');

-- nobody else is asked after confirmation
select tests.tick(:'dom', '2027-01-05 18:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'Outreach'), 3, 'no further outreach after confirmation');
select is((select count(*)::int from public.message where module_week_id = :'mw' and template_id = 'M1'
            and instructor_id not in (:'i1', :'i2', :'i3')), 0, 'nobody else was messaged (no "sorry" messages)');

-- ---------------------------------------------------------------- outbox: claim + report
create temp table claimed as select * from public.claim_outbound_messages(100);
select is((select count(*)::int from public.message where status = 'Sending'), (select count(*)::int from claimed),
  'claimed messages are marked Sending');
select is((select count(*)::int from public.claim_outbound_messages(100)), 0, 'a second claim gets nothing (no double send)');
select is((public.report_message_result((select id from public.message where module_week_id = :'mw' and template_id = 'M4' and channel = 'Email'), true, 'gmail-1')) ->> 'status',
  'Sent', 'n8n reports a send');
select is((public.report_message_result((select id from public.message where module_week_id = :'mw' and template_id = 'M4' and channel = 'Discord'), false, null, 'boom')) ->> 'status',
  'Retry', 'a failure is retried');
select * from finish();
rollback;
