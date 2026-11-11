-- Release 2 Milestone F, the reviewers' second pass (docs/reviews/*.md, "Confirmation (second pass)"):
-- the fixes in migration 20261112000007.
begin;
\ir ../helpers/helpers.psql
select plan(19);

-- =============================================================== SCH-5: one planner at a time per domain
-- Planning takes a lock for the domain that a second planner waits for (checked here on the lock itself).
select tests.scenario('GP', 'Live', '2027-01-31', 1) as p \gset
select (:'p'::jsonb ->> 'domain') as pdom, (:'p'::jsonb ->> 'module') as pmod \gset
select ok(not exists (select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()),
  'SCH-5 no planning lock is held before planning');
select public.create_module_weeks(:'pdom',
  (select jsonb_agg(jsonb_build_object('module_id', :'pmod'::uuid, 'week_start_date', w ->> 'week_start_date', 'classes', w -> 'classes'))
     from jsonb_array_elements(public.generate_classes(:'pdom', :'pmod', array['2027-03-07']::date[])) w), true, 'SCH-5 test');
select ok(exists (select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid() and granted),
  'SCH-5 planning holds the domain''s planning lock until the plan is saved');

select tests.scenario('GA', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'ops') as ops \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');

-- =============================================================== SEC-11: a link's secret only for its own person
-- The placeholder of instructor 1's Yes button, pasted into a message for a team member.
select substring(buttons::text from '\{\{t:[0-9a-f]{32}\}\}') as ph
  from public.message where module_week_id = :'mw' and instructor_id = :'i1' and template_id = 'M1'
   and buttons::text like '%{{t:%' limit 1 \gset
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, team_member_id, to_address, body_text)
values (:'dom', 'Team', 'T9', 'Email', 'sec11-team', 'Pending', :'ops', 'ops@example.com', 'Look: ' || :'ph');
-- SEC-15: the same instructor's real link pasted into a test copy (what a domain being tested sends).
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id, to_address, body_text, is_test)
values (:'dom', 'Instructor', 'M14', 'Email', 'sec15-test-copy', 'Pending', :'i1', 'testing@example.com', 'Look: ' || :'ph', true);
create temp table claimed on commit drop as select c.* from public.claim_outbound_messages(100) c;
select ok((select body_text from claimed where unique_key = 'sec11-team') = 'Look: expired',
  'SEC-11 another person''s link placeholder never turns into the working link');
select is((select body_text from claimed where unique_key = 'sec15-test-copy'), 'Look: expired',
  'SEC-15 a real link never goes into a test copy, even for the same instructor');
select is((select is_test from public.message where unique_key = 'sec15-test-copy'), true, 'SEC-15 (the copy is a test copy)');
select ok(exists (select 1 from claimed c join public.response_link l on position(l.token in c.buttons::text) > 0
                   join public.request r on r.id = l.request_id
                  where c.module_week_id = :'mw' and c.instructor_id = :'i1' and r.instructor_id = :'i1'),
  'SEC-11 the instructor''s own message still gets their own working links');

-- =============================================================== SEC-12: the answer pages have working buttons
select is(tests.click(:'mw', :'i1', 'Yes'), 'confirmed', 'SEC-12 instructor 1 confirms');
select tests.tick(:'dom', '2027-01-21 18:00+00');  -- the reminder 10 days before class
select tests.token(:'mw', :'i1', 'AllSet') as allset \gset
select public.submit_response_page(:'allset', '{}')::text as page \gset
select ok(position('{{t:' in :'page') = 0, 'SEC-12 the page after "All set" has no placeholder left');
select ok(exists (select 1 from public.response_link l join public.request r on r.id = l.request_id
                   where r.instructor_id = :'i1' and l.answer = 'NeedHelp' and position(l.token in :'page') > 0),
  'SEC-12 and its Need help button carries the instructor''s own working link');

-- =============================================================== DIS-13: never sent twice after a lost answer
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, team_member_id, to_address,
                            body_text, attempts, claimed_at)
values (:'dom', 'Team', 'T9', 'Email', 'dis13-stuck', 'Sending', :'ops', 'ops@example.com', 'Hello', 1, now() - interval '20 minutes');
select public.claim_outbound_messages(1);
select is((select status from public.message where unique_key = 'dis13-stuck'), 'Failed',
  'DIS-13 a message the automation took but never answered for is not sent again');
select ok((select last_error from public.message where unique_key = 'dis13-stuck') like '%may or may not have arrived%',
  'DIS-13 and it says to check whether it arrived');

-- =============================================================== OUT-3: a confirmed class week is never paused
select throws_like($$ select public.pause_outreach('$$ || :'mw' || $$'::uuid, true) $$,
  '%already has a confirmed instructor%', 'OUT-3 a class week with a confirmed instructor cannot be paused');
-- With all messages paused, a time change makes no request yet, and says so.
update public.system_state set outreach_enabled = false where id = 1;
select is(private.week_times_changed(:'mw', '2027-01-22 18:00+00', false) ->> 'time_change_request', 'false',
  'OUT-3 a time change says no request was made while messages are paused');
update public.system_state set outreach_enabled = true where id = 1;

-- =============================================================== OUT-4: the cohort's quiet hours
-- Two class weeks asked at 8:00 AM Pacific: the domain's quiet hours end at 8:00, this cohort's
-- (11:00 PM to 11:00 AM) at 11:00.
select tests.scenario('GQ', 'Live', '2027-01-31', 2) as q \gset
select (:'q'::jsonb ->> 'domain') as qdom, (:'q'::jsonb ->> 'mw') as qmw \gset
insert into public.cohort (domain_id, name, status) values (:'qdom', 'Late risers', 'Running') returning id as qcoh \gset
update public.module_week set cohort_id = :'qcoh' where id = :'qmw';
insert into public.setting (scope, domain_id, cohort_id, key, value)
values ('Cohort', :'qdom', :'qcoh', 'instructor_quiet_start', '"23:00"'),
       ('Cohort', :'qdom', :'qcoh', 'instructor_quiet_end', '"11:00"');
select tests.tick(:'qdom', '2027-01-02 16:00+00');
select ok((select min(sent_at) from public.request where module_week_id = :'qmw' and kind = 'Outreach') >= '2027-01-02 19:00+00',
  'OUT-4 the request waits for the end of the cohort''s quiet hours (11:00 AM Pacific)');
select tests.scenario('GR', 'Live', '2027-01-31', 2) as r \gset
select (:'r'::jsonb ->> 'domain') as rdom, (:'r'::jsonb ->> 'mw') as rmw \gset
select tests.tick(:'rdom', '2027-01-02 16:00+00');
select ok((select min(sent_at) from public.request where module_week_id = :'rmw' and kind = 'Outreach') < '2027-01-02 19:00+00',
  'OUT-4 a class week without that cohort setting is asked at 8:00 AM, as the domain says');

-- =============================================================== No duplicate messages: the contact check
select public.send_test_message(:'i1');
select throws_like($$ select public.send_test_message('$$ || :'i1' || $$'::uuid) $$,
  '%already on its way%', 'a second contact check while the first is still on its way is refused');
select is((select count(*)::int from public.message m join public.request q on q.id = m.request_id
            where q.instructor_id = :'i1' and q.kind = 'Test' and m.channel = 'Email'), 1,
  'and only one contact check email exists');

-- =============================================================== SEC-5: Sandbox direct messages
update public.app_config set environment = 'Sandbox' where id = 1;
select tests.make_instructor('GA Tester', true, true) as tester \gset
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id, discord_dm_user_id, body_text)
values (:'dom', 'Instructor', 'M15', 'Discord', 'sec5-dm-1', 'Pending', :'tester', '120000000000000005', 'Hello')
returning status as s1 \gset
select is(:'s1'::text, 'Cancelled',
  'SEC-5 Sandbox never sends a direct message to an account that is not a team member''s, even for a test instructor');
update public.team_member set discord_user_id = '120000000000000006' where id = :'ops';
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id, discord_dm_user_id, body_text)
values (:'dom', 'Instructor', 'M15', 'Discord', 'sec5-dm-2', 'Pending', :'tester', '120000000000000006', 'Hello')
returning status as s2 \gset
select is(:'s2'::text, 'Pending', 'SEC-5 a test instructor using the tester''s own Discord account gets the direct message');
update public.app_config set environment = 'Development' where id = 1;

select * from finish();
rollback;
