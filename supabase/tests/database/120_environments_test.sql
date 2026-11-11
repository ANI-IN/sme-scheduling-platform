-- Release Milestone 7: Sandbox and Production rules, and the Sandbox reset (to empty since decision 251).
begin;
\ir ../helpers/helpers.psql
select plan(23);

select tests.scenario('EV', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.scenario('EVT', 'Test', '2027-01-31', 1) as jt \gset
select (:'jt'::jsonb ->> 'domain') as tdom, (:'jt'::jsonb ->> 'i1') as ti1 \gset
select tests.make_instructor('EV Tester', true, true) as tester \gset

create or replace function tests.out_msg(p_key text, p_channel text, p_instructor uuid, p_to text, p_chan text default null)
returns text language sql as $$
  insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id, to_address, discord_channel_id, body_text)
  values ((select id from public.domain where name = 'EV'), 'Instructor', 'M1', p_channel, p_key, 'Pending', p_instructor, p_to, p_chan, 'Hello')
  returning status;
$$;

-- =============================================================== Production
update public.app_config set environment = 'Production' where id = 1;
select is(tests.out_msg('ev-1', 'Email', :'tester', 'tester@example.org'), 'Cancelled', 'Production never messages a test instructor');
select is((select last_error from public.message where unique_key = 'ev-1'), 'Production never messages test instructors.',
  'and says why');
select ok(exists (select 1 from public.history_event where action = 'Message blocked'), 'a blocked message is recorded in Activity history');
select is(tests.out_msg('ev-2', 'Email', :'i1', 'real@example.org'), 'Pending', 'real instructors are messaged as usual in Production');

-- =============================================================== Sandbox
update public.app_config set environment = 'Sandbox', discord_guild_id = '111111111111111111',
       sandbox_allowed_email_domains = array['allowed.test'], sandbox_allowed_discord_servers = array['111111111111111111'] where id = 1;
select is(tests.out_msg('ev-3', 'Email', :'i1', 'someone@realcompany.com'), 'Cancelled', 'Sandbox does not email domains that are not allowed');
select is(tests.out_msg('ev-4', 'Email', :'tester', 'me+a@allowed.test'), 'Pending', 'Sandbox emails allowed domains');
-- TST-1: a real instructor is never emailed from Sandbox, even at an address on an allowed domain
-- (staff who also teach have company addresses, and the company domain is usually allowed).
select is(tests.out_msg('ev-4b', 'Email', :'i1', 'staff@allowed.test'), 'Cancelled',
  'Sandbox never emails a real instructor, even at an allowed address');
select ok((select last_error from public.message where unique_key = 'ev-4b') like 'Sandbox never contacts real instructors by email%',
  'and says why');
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, to_address, body_text)
values (:'dom', 'Team', 'T4', 'Email', 'ev-4c', 'Pending', 'ops@allowed.test', 'Hello team') returning status as team_status \gset
select is(:'team_status'::text, 'Pending', 'team members at an allowed address still get email in Sandbox');
-- In a domain that is being tested, every copy goes to the testing email, so it may go out.
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id, to_address, body_text)
values (:'tdom', 'Instructor', 'M1', 'Email', 'ev-4d', 'Pending', :'ti1', 'testing@allowed.test', 'Hello') returning status as test_status \gset
select is(:'test_status'::text, 'Pending', 'a real instructor''s copy in a domain being tested goes to the testing email');
insert into public.discord_channel (id, server_id, name) values ('222222222222222222', '111111111111111111', 'testing');
select is(tests.out_msg('ev-5', 'Discord', :'tester', null, '222222222222222222'), 'Pending', 'Sandbox posts in an allowed Discord server');
select is(tests.out_msg('ev-5b', 'Discord', :'tester', null, '333333333333333333'), 'Cancelled',
  'Sandbox never posts to a channel the bot has not listed (no guessing the server, SEC-5)');
update public.app_config set sandbox_allowed_discord_servers = '{}' where id = 1;
select is(tests.out_msg('ev-6', 'Discord', :'tester', null, '222222222222222222'), 'Cancelled', 'and nowhere else');
select is((select status from public.message where unique_key = 'ev-4'), 'Pending', 'messages already allowed are not changed');
update public.message set status = 'Sending' where unique_key = 'ev-4';
update public.app_config set sandbox_allowed_email_domains = '{}' where id = 1;
update public.message set status = 'Pending' where unique_key = 'ev-4';
select is((select status from public.message where unique_key = 'ev-4'), 'Cancelled', 'the check runs again before a message is sent');

-- =============================================================== Sandbox reset
create temp table hist_before on commit drop as select id from public.history_event;
insert into public.holiday (date, name) values ('2028-01-01', 'EV global holiday') on conflict do nothing;
insert into public.team_member (name, email) select 'EV Ops', 'ops@example.com'
  where not exists (select 1 from public.team_member where email = 'ops@example.com');
select tests.login_google('ops@example.com');
select throws_ok($$ select public.reset_sandbox_data('yes') $$, '22023', null, 'resetting needs RESET typed');
insert into public.team_member (name, email, is_placeholder) values ('EV Placeholder', 'ev.placeholder@example.com', true);
select public.reset_sandbox_data('RESET') as reset \gset
select tests.as_postgres();
select is(:'reset'::jsonb, '{"emptied": true}'::jsonb, 'a reset says the Sandbox was emptied');
select is((select count(*)::int from public.domain) + (select count(*)::int from public.cohort)
          + (select count(*)::int from public.module) + (select count(*)::int from public.module_week),
  0, 'a reset leaves no domains, cohorts, modules or classes: no practice data is loaded');
select is((select count(*)::int from public.instructor) + (select count(*)::int from public.holiday), 0,
  'and no instructors, test instructors or holidays');
select ok(not exists (select id from hist_before except select id from public.history_event),
  'Activity history is kept, never deleted: every row from before the reset is still there');
select ok(exists (select 1 from public.team_member where email = 'ops@example.com' and not is_placeholder),
  'real team members keep their access after a reset');
select ok(not exists (select 1 from public.team_member where email = 'ev.placeholder@example.com'),
  'placeholder team members are removed');
update public.app_config set environment = 'Production' where id = 1;
select tests.login_google('ops@example.com');
select throws_ok($$ select public.reset_sandbox_data('RESET') $$, '42501', null, 'Production data can never be reset');
select tests.as_postgres();

select * from finish();
rollback;
