-- Release 2 Milestone F, second round of reviews (docs/reviews/tests-and-docs.md): cases that had no
-- test, or only a test that could not fail.
begin;
\ir ../helpers/helpers.psql
select plan(19);

-- =============================================================== TST-2: "Can't make it" after the class started
-- Nothing automatic happens: the booking stays, nobody else is asked, and the team gets an urgent task.
select tests.scenario('FS', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is(tests.click(:'mw', :'i1', 'Yes'), 'confirmed', 'started 1. instructor 1 confirms');
-- The first class is Sunday 9:00 AM Pacific (17:00 UTC). An hour after it began they press Can't make it.
select tests.at('2027-01-31 18:00+00');
select is(tests.click(:'mw', :'i1', 'CantMakeIt'), 'cancelled', 'started 2. their answer is taken (never used link)');
select is(tests.booked(:'mw'), 'FS Instr1', 'started 3. the booking stays: nothing is released after the class started');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'Outreach'
            and status in ('Queued', 'Sent', 'Reminded')), 0, 'started 4. nobody else is asked');
select ok(exists (select 1 from public.attention_item a join public.booking b on a.dedupe_key = 'started:' || b.id
                   where b.module_week_id = :'mw' and a.severity = 'Urgent' and a.status <> 'Done'),
  'started 5. the team gets an urgent task to handle it directly');

-- =============================================================== TST-10: manual assignment rules
select tests.at('2027-01-10 18:00+00');  -- well before these classes
select tests.scenario('FM', 'Live', '2027-01-31', 3) as k \gset
select (:'k'::jsonb ->> 'domain') as mdom, (:'k'::jsonb ->> 'mw') as mmw, (:'k'::jsonb ->> 'i2') as m2,
       (:'k'::jsonb ->> 'i3') as m3, (:'k'::jsonb ->> 'module') as mmod \gset
-- An instructor whose contact details are not checked yet may still be assigned by hand (decision 42).
update public.instructor set verified_at = null, version = version where id = :'m2';
select public.assign_manually(:'mmw', :'m2', 'Spoke on the phone');
select is(tests.booked(:'mmw'), 'FM Instr2', 'manual 12. an instructor not checked yet can be assigned by hand');
-- A test instructor is never booked in a Live domain, not even by hand.
select public.release_booking(:'mmw', 'Changed plan', false);
select tests.make_instructor('FM Tester', true, true) as tester \gset
select throws_like($$ select public.assign_manually('$$ || :'mmw' || $$'::uuid, '$$ || :'tester' || $$'::uuid) $$,
  '%Test instructor%', 'manual 13. a test instructor cannot be assigned in a Live domain');
-- Someone who said they cannot teach those dates is refused, with the dates.
insert into public.instructor_unavailability (instructor_id, from_date, to_date, reason)
values (:'m3', '2027-01-30', '2027-02-06', 'Holiday');
select throws_like($$ select public.assign_manually('$$ || :'mmw' || $$'::uuid, '$$ || :'m3' || $$'::uuid) $$,
  '%Unavailable Jan 30 to Feb 6%', 'manual 14. an instructor who cannot teach those dates is refused, with the dates');
-- Someone teaching another class at the same time is refused.
delete from public.instructor_unavailability where instructor_id = :'m3';
select tests.make_module(:'mdom', 'FM Other', 2) as omod \gset
select tests.make_week(:'omod', '2027-01-31') as omw \gset
select tests.raw_book(:'omw', :'m3');
select throws_like($$ select public.assign_manually('$$ || :'mmw' || $$'::uuid, '$$ || :'m3' || $$'::uuid) $$,
  'Can''t book: Teaching FM Other%the same time as this class%', 'manual 15. an instructor teaching at the same time is refused, with the other class named');
select is((select count(*)::int from public.booking where module_week_id = :'mmw' and status = 'Active'), 0,
  'manual 16. and no booking is left behind by any refusal');

-- =============================================================== Back to back classes are allowed
-- A class ending at 1:00 PM and another starting at 1:00 PM do not overlap.
select tests.scenario('FB', 'Live', '2027-01-31', 1) as b \gset
select (:'b'::jsonb ->> 'domain') as bdom, (:'b'::jsonb ->> 'mw') as bmw, (:'b'::jsonb ->> 'i1') as b1 \gset
select tests.make_module(:'bdom', 'FB Next', 2) as bmod2 \gset
select tests.make_week(:'bmod2', '2027-01-31') as bmw2 \gset
update public.class_session c set
  starts_at = (select max(x.ends_at) from public.class_session x where x.module_week_id = :'bmw' and x.starts_at < '2027-02-01'),
  ends_at = (select max(x.ends_at) from public.class_session x where x.module_week_id = :'bmw' and x.starts_at < '2027-02-01') + interval '1 hour'
 where c.module_week_id = :'bmw2' and c.starts_at < '2027-02-01';
update public.class_session set starts_at = starts_at + interval '2 days', ends_at = ends_at + interval '2 days'
 where module_week_id = :'bmw2' and starts_at >= '2027-02-01';
select tests.raw_book(:'bmw', :'b1');
select lives_ok($$ select tests.raw_book('$$ || :'bmw2' || $$'::uuid, '$$ || :'b1' || $$'::uuid) $$,
  'back to back classes (one ends as the next starts) can both be booked for one instructor');

-- =============================================================== Several test instructors share one Discord username
-- The setup guide asks for one test Discord account for all test instructors (decision 95).
insert into public.discord_server (id, name) values ('777777777777777771', 'FX Sandbox') on conflict do nothing;
update public.domain set discord_server_id = '777777777777777771' where id = :'bdom';
insert into public.instructor (full_name, primary_email, is_test, discord_username)
values ('FX Tester A', 'fx+a@example.org', true, 'shared.tester') returning id as ta \gset
insert into public.instructor (full_name, primary_email, is_test, discord_username)
values ('FX Tester B', 'fx+b@example.org', true, 'shared.tester') returning id as tb \gset
create or replace function tests.answer_member(p_id uuid, p_result jsonb) returns jsonb language sql as $$
  select public.record_discord_result(
    (select id from public.action_queue where action = 'discord_member' and status = 'Processing'
        and payload ->> 'id' = p_id::text order by created_at desc limit 1), p_result);
$$;
select public.next_discord_lookups(50);
select tests.answer_member(:'ta', '{"searches": [{"server_id": "777777777777777771", "status": 200, "body": [
  {"user": {"id": "666666666666666661", "username": "shared.tester"}}]}]}');
select tests.answer_member(:'tb', '{"searches": [{"server_id": "777777777777777771", "status": 200, "body": [
  {"user": {"id": "666666666666666661", "username": "shared.tester"}}]}]}');
select is((select string_agg(discord_status, ', ' order by full_name) from public.instructor where id in (:'ta', :'tb')),
  'Found, Found', 'test instructors can all be found through one shared Discord username');
select is((select count(distinct discord_user_id)::int from public.instructor where id in (:'ta', :'tb')), 1,
  'and they share the one Discord account');

-- =============================================================== An India class: the request shows India time
select tests.scenario('FI', 'Live', '2027-01-31', 2) as ind \gset
select (:'ind'::jsonb ->> 'domain') as idom, (:'ind'::jsonb ->> 'mw') as imw \gset
update public.class_session set region = 'India' where module_week_id = :'imw';
select tests.tick(:'idom', '2027-01-01 18:00+00');
select ok(exists (select 1 from public.message where module_week_id = :'imw' and template_id = 'M1' and body_text like '%IST%'),
  'a request for an India class shows its time in India time (IST)');
select ok(not exists (select 1 from public.message where module_week_id = :'imw' and template_id = 'M1'
                      and (body_text like '%PST%' or body_text like '%PDT%')),
  'and not in US Pacific time');

-- =============================================================== TST-4: the automation gets the real answer links
select tests.scenario('FT', 'Live', '2027-01-31', 2) as t \gset
select (:'t'::jsonb ->> 'domain') as tdom, (:'t'::jsonb ->> 'mw') as tmw \gset
select tests.tick(:'tdom', '2027-01-01 18:00+00');
select ok(exists (select 1 from public.message where module_week_id = :'tmw' and template_id = 'M1' and status = 'Pending'
                   and buttons::text like '%{{t:%'),
  'SEC-3 a request waiting to be sent keeps placeholders, never the secrets');
create temp table claimed on commit drop as
  select c.* from public.claim_outbound_messages(1000) c where c.module_week_id = :'tmw' and c.template_id = 'M1';
select ok(exists (select 1 from claimed where buttons is not null), 'SEC-3 the automation takes the request to send');
select ok(not exists (select 1 from claimed where buttons::text like '%{{t:%'), 'SEC-3 no placeholder is left in what it gets');
select ok(not exists (select 1 from claimed c where c.buttons is not null and not exists (
            select 1 from public.response_link l join public.request r on r.id = l.request_id
             where r.module_week_id = :'tmw' and position(l.token in c.buttons::text) > 0)),
  'SEC-3 every button it gets carries the real link of that request');

select * from finish();
rollback;
