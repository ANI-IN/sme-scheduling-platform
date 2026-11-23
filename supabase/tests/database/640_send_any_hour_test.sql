-- Owner, 23 November 2026 (decision 332): instructor messages go at any hour unless a domain turns quiet hours on
-- (then in the instructor's own time zone, else the class's); every time is shown in both zones; reminders and
-- deadlines keep their length; and a class week never shows Asking with no request open.
begin;
\ir ../helpers/helpers.psql
select plan(24);

-- =============================================================== 1 to 6: at any hour, by default
select tests.scenario('SA', 'Live', '2027-01-31', 2) as a \gset
select (:'a'::jsonb ->> 'domain') as adom, (:'a'::jsonb ->> 'mw') as amw, (:'a'::jsonb ->> 'i1') as ai1 \gset
update public.instructor set time_zone = 'India' where id = :'ai1';
-- 3:00 AM India time on Jan 2 is 21:30 UTC on Jan 1; the class is a US class.
select tests.tick(:'adom', '2027-01-01 21:30+00');
select is(tests.asking(:'amw'), 'SA Instr1', '1. the India instructor of a US class is asked at 3:00 AM India time');
select ok(not exists (select 1 from public.message where module_week_id = :'amw' and template_id = 'M1' and not_before <> '2027-01-01 21:30+00'),
  '2. and every copy of the request goes at once, not held for the night');
select ok((select count(*) from public.message where module_week_id = :'amw' and template_id = 'M1' and status = 'Pending') >= 2,
  '3. on Discord and by email, ready to send now');
select ok((select reminder_at = sent_at + interval '24 hours' and deadline_at = sent_at + interval '48 hours'
             from public.request where module_week_id = :'amw' and kind = 'Outreach' and status = 'Sent'),
  '4. the reminder and the deadline keep their usual length (24 and 48 hours)');
select ok(exists (select 1 from public.message where module_week_id = :'amw' and template_id = 'M1' and channel = 'Email'
                    and body_text ~ 'Live class: Sun, Jan 31 · 9:00 AM to 1:00 PM PST \(Sun, Jan 31 · 10:30 PM to 2:30 AM IST\)'),
  '5. class times are in US Pacific time and India time');
select ok(exists (select 1 from public.message where module_week_id = :'amw' and template_id = 'M1' and channel = 'Email'
                    and body_text ~ 'reply by [^\n]*P[SD]T \([^)]*IST\)'),
  '6. and so is the reply by time');

-- 7: a US instructor of an India class, at 3:00 AM Pacific time on Jan 2 (11:00 UTC), when asking for it starts.
select tests.scenario('SB', 'Live', '2027-01-31', 1) as b \gset
select (:'b'::jsonb ->> 'domain') as bdom, (:'b'::jsonb ->> 'mw') as bmw, (:'b'::jsonb ->> 'i1') as bi1 \gset
update public.instructor set time_zone = 'US' where id = :'bi1';
update public.class_session set region = 'India' where module_week_id = :'bmw';
select tests.tick(:'bdom', '2027-01-02 11:00+00');
select ok(exists (select 1 from public.message where module_week_id = :'bmw' and template_id = 'M1')
          and not exists (select 1 from public.message where module_week_id = :'bmw' and template_id = 'M1' and not_before <> '2027-01-02 11:00+00'),
  '7. the US instructor of an India class is asked at once at 3:00 AM Pacific time');

-- =============================================================== 8 to 13: quiet hours switched on for one domain
select tests.scenario('SC', 'Live', '2027-01-31', 2) as c \gset
select (:'c'::jsonb ->> 'domain') as cdom, (:'c'::jsonb ->> 'mw') as cmw, (:'c'::jsonb ->> 'i1') as ci1, (:'c'::jsonb ->> 'i2') as ci2 \gset
insert into public.setting (scope, domain_id, key, value) values ('Domain', :'cdom', 'instructor_quiet_hours_on', 'true');
update public.instructor set time_zone = 'India' where id = :'ci1';
select is(private.instructor_send_time(:'cdom', '2027-01-01 21:30+00', false, 'US', :'ci1'), '2027-01-02 02:30+00'::timestamptz,
  '8. on: 3:00 AM India time waits for 8:00 AM in the instructor''s own time zone (India)');
select is(private.instructor_send_time(:'cdom', '2027-01-01 07:00+00', false, 'US', :'ci1'), '2027-01-01 07:00+00'::timestamptz,
  '9. on: 12:30 PM India time goes at once, though it is 11:00 PM in the class''s US time');
select is(private.instructor_send_time(:'cdom', '2027-01-01 07:00+00', false, 'US', :'ci2'), '2027-01-01 16:00+00'::timestamptz,
  '10. on, no time zone for the instructor: the class''s time zone (11:00 PM Pacific waits for 8:00 AM Pacific)');
select is(private.instructor_send_time(:'adom', '2027-01-01 07:00+00', false, 'US', :'ci2'), '2027-01-01 07:00+00'::timestamptz,
  '11. off (every other domain): the same moment goes at once');
select tests.tick(:'cdom', '2027-01-01 21:30+00');
select ok(not exists (select 1 from public.message where module_week_id = :'cmw' and template_id = 'M1' and (status <> 'Scheduled' or not_before <> '2027-01-02 02:30+00'))
          and exists (select 1 from public.message where module_week_id = :'cmw' and template_id = 'M1'),
  '12. on: the request to the India instructor waits for 8:00 AM India time');
select ok((select deadline_at = sent_at + interval '48 hours' and reminder_at = sent_at + interval '24 hours'
             from public.request where module_week_id = :'cmw' and kind = 'Outreach' and status = 'Sent'),
  '13. on: the reminder and the deadline still keep their usual length from when it is sent');

-- =============================================================== 14 to 24: never Asking with no request open
select tests.scenario('SD', 'Live', '2027-01-31', 3) as d \gset
select (:'d'::jsonb ->> 'domain') as ddom, (:'d'::jsonb ->> 'mw') as dmw \gset
select tests.tick(:'ddom', '2027-01-01 18:00+00');
select is(tests.asking(:'dmw'), 'SD Instr1', '14. asking the first instructor');
-- A request withdrawn by a path that does not ask the next instructor (as done by hand on 23 November, when the
-- instructor was also set to Not in use).
update public.instructor set status = 'Inactive' where id = (:'d'::jsonb ->> 'i1')::uuid;
select private.withdraw_open_request(:'dmw', 'test', '2027-01-01 18:30+00', false);
set constraints all immediate;
select is(tests.asking(:'dmw'), 'SD Instr2', '15. when the change is saved, the next instructor is asked');
select is((select status from public.module_week where id = :'dmw'), 'Asking', '16. and the week is Asking with a request open');
set constraints all deferred;

-- A request closed by a time change (Superseded) without asking again.
update public.request set status = 'Superseded', close_reason = 'test' where module_week_id = :'dmw' and kind = 'Outreach' and status = 'Sent';
set constraints all immediate;
select ok(tests.asking(:'dmw') is not null, '17. a request closed by a time change: someone is asked again');
set constraints all deferred;

-- Nobody left to ask: Needs instructor, with the usual task.
select tests.scenario('SE', 'Live', '2027-01-31', 1) as e \gset
select (:'e'::jsonb ->> 'domain') as edom, (:'e'::jsonb ->> 'mw') as emw, (:'e'::jsonb ->> 'i1') as ei1 \gset
select tests.tick(:'edom', '2027-01-01 18:00+00');
update public.instructor set status = 'Inactive' where id = :'ei1';
select private.withdraw_open_request(:'emw', 'test', '2027-01-01 18:30+00', false);
set constraints all immediate;
select is((select status from public.module_week where id = :'emw'), 'NeedsInstructor', '18. nobody left: Needs instructor, not Asking');
select ok(exists (select 1 from public.attention_item where domain_id = :'edom' and type = 'RankingExhausted' and status = 'Open'),
  '19. with the usual task to assign someone');
set constraints all deferred;

-- Asking cannot happen now (a Draft domain): Not asked yet, and nobody is messaged.
select tests.scenario('SF', 'Draft', '2027-01-31', 1) as f \gset
select (:'f'::jsonb ->> 'mw') as fmw \gset
update public.module_week set status = 'Asking', outreach_started_at = '2026-12-20' where id = :'fmw';
select is(private.settle_asking_weeks('2027-01-01 18:00+00') >= 1, true, '20. the clock finds the week Asking with nobody asked');
select is((select status from public.module_week where id = :'fmw'), 'Ready', '21. asking cannot happen now: Not asked yet');
select ok(not exists (select 1 from public.message where module_week_id = :'fmw'), '22. and nobody is messaged');

-- The clock puts a week left behind right, in a live domain.
select tests.scenario('SG', 'Live', '2027-01-31', 2) as g \gset
select (:'g'::jsonb ->> 'mw') as gmw \gset
update public.module_week set status = 'Asking', outreach_started_at = '2026-12-20' where id = :'gmw';
select private.settle_asking_weeks('2027-01-01 18:00+00');
select is(tests.asking(:'gmw'), 'SG Instr1', '23. a week left Asking with nobody asked: the clock asks the next instructor');
select ok(not exists (select 1 from public.module_week w where w.status = 'Asking'
                        and not exists (select 1 from public.request r where r.module_week_id = w.id and r.kind = 'Outreach'
                                          and r.status in ('Queued', 'Sent', 'Reminded'))),
  '24. no class week anywhere is Asking with no request open');

select * from finish();
rollback;
