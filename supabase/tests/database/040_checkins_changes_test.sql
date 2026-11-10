-- M2 scenarios (PRD 20.3): check-ins (All set / Need help / Can't make it / no reply), owner
-- check-in, cancellations at 15 / 7 / 2 days (window bands), time changes before and after
-- confirmation, class cancelled, daylight saving in messages, outage catch-up.
-- Live class Sun Jan 31 2027 9:00 AM PST = 17:00 UTC.
begin;
\ir ../helpers/helpers.psql
select plan(63);

-- =============================================================== check-ins
select tests.scenario('CI', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'owner') as owner \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');

select tests.tick(:'dom', '2027-01-17 18:00+00');   -- 14 days before
select is((select count(*)::int from public.message where template_id = 'T11' and team_member_id = :'owner'), 1, 'owner check-in (T11) at 14 days');
select ok((select body_text from public.message where template_id = 'T11' and team_member_id = :'owner') like '%Confirmed: CI Instr1%All good:%Need help:%',
  'owner check-in lists the week with status and All good / Need help links');
select is(tests.msgs(:'mw', 'M8'), 0, 'optional 14-day instructor check-in is off by default');
select is((select public.record_response(l.token) ->> 'result' from public.response_link l join public.request r on r.id = l.request_id
            where r.module_week_id = :'mw' and r.kind = 'OwnerCheckIn' and l.answer = 'OwnerAllGood'), 'owner_ok', 'owner can answer All good');

select tests.tick(:'dom', '2027-01-21 18:00+00');   -- 10 days before
select is(tests.msgs(:'mw', 'M6'), 2, '10-day check-in (M6) on both channels');
select is((select jsonb_array_length(buttons) from public.message where module_week_id = :'mw' and template_id = 'M6' limit 1), 3,
  'buttons: All set / Need help / Can''t make it');
select tests.tick(:'dom', '2027-01-22 18:00+00');
select is(tests.msgs(:'mw', 'M9'), 2, 'no reply → one reminder after 24h (M9)');
select tests.tick(:'dom', '2027-01-23 18:00+00');
select is((select severity from public.attention_item where type = 'CheckInNoReply' and module_week_id = :'mw'), 'Normal',
  'still no reply → attention item (normal for the 10-day check-in)');
select is(tests.booked(:'mw'), 'CI Instr1', 'booking kept');

select tests.tick(:'dom', '2027-01-29 18:00+00');   -- 2 days before
select is(tests.msgs(:'mw', 'M7'), 2, '2-day (final) check-in (M7)');
select ok((select body_text from public.message where module_week_id = :'mw' and template_id = 'M7' and channel = 'Email') like '%Sun, Jan 31 · 9:00 AM PST%',
  'final check-in shows the class day and time in PT');
select is(tests.click(:'mw', :'i1', 'AllSet'), 'all_set', 'All set is recorded');
select is((select answer from public.request where module_week_id = :'mw' and kind = 'CheckIn' and check_in_days = 2), 'AllSet', 'nothing else happens');
select ok(public.submit_response_page(tests.token(:'mw', :'i1', 'AllSet'), '{}') like '%Already recorded%', 'second tap: Already recorded');

-- after the classes: completed
select tests.tick(:'dom', '2027-02-05 06:00+00');
select is(tests.mw_status(:'mw'), 'Completed', 'module week completed after the last class');
select is((select status from public.booking where module_week_id = :'mw'), 'Completed', 'booking completed');

-- last check-in with no reply → urgent, booking kept (default setting)
select tests.scenario('CN', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-29 18:00+00');
select tests.tick(:'dom', '2027-01-30 06:00+00');
select tests.tick(:'dom', '2027-01-30 18:00+00');
select is((select severity from public.attention_item where type = 'CheckInNoReply' and module_week_id = :'mw'), 'Urgent',
  'no reply to the last check-in → urgent attention item');
select is(tests.booked(:'mw'), 'CN Instr1', 'booking kept by default');

-- Need help from a check-in
select tests.scenario('NH', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-21 18:00+00');
select ok(public.response_page(tests.token(:'mw', :'i1', 'NeedHelp')) like '%Here are your materials%I still need help%',
  'Need help shows the materials first, then the form');
select ok(public.submit_response_page(tests.token(:'mw', :'i1', 'NeedHelp'),
  '{"cat_zoom":"1","details":"No Zoom link yet","urgency":"Within24h","reply_channel":"Email"}') like '%will reply by%',
  'help form submitted; confirmation page shows who will reply and by when');
select is((select answer from public.request where module_week_id = :'mw' and kind = 'CheckIn'), 'NeedHelp', 'check-in answered with Need help');
select is(tests.booked(:'mw'), 'NH Instr1', 'booking stays');
select is((select count(*)::int from public.message where module_week_id = :'mw' and template_id = 'M13' and channel = 'Email'), 1,
  'acknowledgement (M13) via the chosen channel');

-- =============================================================== cancellation by time band
-- 15 days before: normal, long windows
select tests.scenario('C15', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.at('2027-01-16 18:00+00');
select ok(public.response_page(tests.token(:'mw', :'i1', 'CantMakeIt')) like '%This will release your class%',
  'Can''t make it asks "are you sure?" first');
select is(tests.click(:'mw', :'i1', 'CantMakeIt'), 'cancelled', 'cancellation recorded');
select is(tests.booked(:'mw'), null, 'booking released');
select is(tests.msgs(:'mw', 'M10'), 2, 'instructor gets M10');
select is((select severity from public.attention_item where dedupe_key = 'atrisk:' || :'mw'), 'Normal', '15 days before: normal alert');
select is(tests.msgs(:'mw', 'T5'), 1, 'owner and ops alerted (T5)');
select is(tests.asking(:'mw'), 'C15 Instr2', 'outreach restarts, skipping the instructor who cancelled');
select is((select deadline_at - sent_at from public.request where module_week_id = :'mw' and status = 'Sent'), interval '48 hours', 'long-band windows (48h)');

-- 7 days before: urgent, 12/24
select tests.scenario('C07', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.at('2027-01-24 18:00+00');
select tests.click(:'mw', :'i1', 'CantMakeIt');
select is((select severity from public.attention_item where dedupe_key = 'atrisk:' || :'mw'), 'Urgent', '7 days before: urgent');
select is((select deadline_at - sent_at from public.request where module_week_id = :'mw' and status = 'Sent'), interval '24 hours', '3–10 days: move on after 24h');
select is((select reminder_at from public.request where module_week_id = :'mw' and status = 'Sent'), '2027-01-25 16:00+00'::timestamptz,
  '3–10 days: reminder after 12h would be 10 PM PT (quiet hours) → moved to 8:00 AM PT');
select tests.click(:'mw', (:'j'::jsonb ->> 'i2')::uuid, 'No');
select is(tests.msgs(:'mw', 'T3'), 1, 'under 10 days: owner tagged on each move (T3)');

-- 2 days before: urgent windows 3/6 and urgent outreach item
select tests.scenario('C02', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.at('2027-01-29 18:00+00');
select tests.click(:'mw', :'i1', 'CantMakeIt');
select is((select at_risk from public.module_week where id = :'mw'), true, 'At risk');
select is((select deadline_at - sent_at from public.request where module_week_id = :'mw' and status = 'Sent'), interval '6 hours', 'under 3 days: move on after 6h');
select is((select reminder_at - sent_at from public.request where module_week_id = :'mw' and status = 'Sent'), interval '3 hours', 'under 3 days: remind after 3h');
select is((select severity from public.attention_item where dedupe_key = 'urgentfill:' || :'mw'), 'Urgent', 'urgent item so ops can phone people too');

-- after the class started: no automation
select tests.at('2027-01-31 18:00+00');
select is(tests.click(:'mw', :'i1', 'CantMakeIt'), 'already_recorded', 'used link');

-- =============================================================== time change before confirmation
select tests.scenario('TB', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select public.change_class_time((select id from public.class_session where module_week_id = :'mw' and class_type = 'Live class'), '2027-01-31', '10:00', '14:00');
select is((select time_version from public.module_week where id = :'mw'), 2, 'time change bumps the time version');
select is(tests.msgs(:'mw', 'M5'), 2, 'the instructor being asked gets an updated message (M5) instead of a new request');
select is((select count(*)::int from public.request where module_week_id = :'mw'), 1, 'no new request');
select is(tests.click(:'mw', :'i1', 'Yes'), 'confirmed', 'Yes still works with the new time');
select is((select lower(time_range) from public.booking_slot s join public.class_session c on c.id = s.class_id
            where c.module_week_id = :'mw' and c.class_type = 'Live class'), '2027-01-31 18:00+00'::timestamptz, 'booked at the new time (10:00 AM PST)');

-- =============================================================== time change after confirmation
select tests.scenario('TA', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.at('2027-01-05 18:00+00');
select public.change_class_time((select id from public.class_session where module_week_id = :'mw' and class_type = 'Assignment review'), '2027-02-04', '17:00', '19:00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'TimeChange'), 1, 'confirmed instructor gets a time-change request');
select is(tests.msgs(:'mw', 'M5'), 2, 'M5 on both channels');
select is(tests.click(:'mw', :'i1', 'StillWorks'), 'still_works', 'Still works keeps the booking');
select is((select time_version_confirmed from public.booking where module_week_id = :'mw' and status = 'Active'), 2, 'booking confirmed for the new time');
select tests.at('2027-01-06 18:00+00');
select public.change_class_time((select id from public.class_session where module_week_id = :'mw' and class_type = 'Assignment review'), '2027-02-04', '16:00', '18:00');
select is(tests.click(:'mw', :'i1', 'DoesntWork'), 'released', 'Doesn''t work releases the booking');
select is(tests.asking(:'mw'), 'TA Instr2', 'and restarts outreach');

-- no reply to a time change → attention, booking kept
select tests.scenario('TN', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.at('2027-01-05 18:00+00');
select public.change_class_time((select id from public.class_session where module_week_id = :'mw' and class_type = 'Live class'), '2027-01-31', '08:00', '12:00');
select tests.tick(:'dom', '2027-01-08 18:00+00');
select is((select count(*)::int from public.attention_item where type = 'TimeChangeNotConfirmed' and module_week_id = :'mw'), 1, 'no reply → attention item');
select is(tests.booked(:'mw'), 'TN Instr1', 'booking kept');

-- =============================================================== class cancelled by the team
select tests.scenario('CC', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select public.cancel_module_week(:'mw', 'Cohort merged');
select is(tests.mw_status(:'mw'), 'Cancelled', 'module week cancelled');
select is((select status from public.booking where module_week_id = :'mw'), 'Cancelled', 'booking cancelled');
select is(tests.msgs(:'mw', 'M11'), 2, 'instructor told (M11)');
select ok(public.response_page(tests.token(:'mw', :'i1', 'CantMakeIt')) like '%no longer scheduled%', 'old links explain the class is no longer scheduled');

select tests.scenario('CR', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select public.cancel_module_week(:'mw');
select is(tests.msgs(:'mw', 'M12'), 2, 'not yet confirmed: the open request is closed with M12');

-- =============================================================== daylight saving in messages
select tests.scenario('DS', 'Live', '2027-03-14', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-02-12 18:00+00');
select ok((select body_text from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Email')
          like '%Live class: Sun, Mar 14 · 9:00 AM to 1:00 PM PDT%', 'first PDT Sunday shows 9:00 AM PDT');
select ok((select body_text from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Email')
          like '%Assignment review: Thu, Mar 18 · 6:00 PM to 8:00 PM PDT%', 'review shows 6:00 PM PDT');

-- =============================================================== outage: nothing lost or duplicated
select tests.scenario('OU', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.tick(:'dom', '2027-01-02 17:00+00');
-- n8n down for 3 hours (no runs at 18:00, 19:00, 20:00)
select tests.tick(:'dom', '2027-01-02 21:00+00');
select is(tests.msgs(:'mw', 'M2'), 2, 'the missed reminder is sent once after the outage');
select tests.tick(:'dom', '2027-01-02 22:00+00');
select tests.tick(:'dom', '2027-01-02 22:00+00');
select is(tests.msgs(:'mw', 'M2'), 2, 'and never twice');
select is((select count(*)::int from public.request where module_week_id = :'mw'), 1, 'still one request');

select * from finish();
rollback;
