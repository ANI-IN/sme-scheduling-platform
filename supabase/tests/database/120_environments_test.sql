-- Release Milestone 7: Sandbox and Production rules, Sandbox starting data and reset.
begin;
\ir ../helpers/helpers.psql
select plan(17);

select tests.scenario('EV', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'i1') as i1 \gset
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
select is(tests.out_msg('ev-5', 'Discord', :'tester', null, '222222222222222222'), 'Pending', 'Sandbox posts in an allowed Discord server');
update public.app_config set sandbox_allowed_discord_servers = '{}' where id = 1;
select is(tests.out_msg('ev-6', 'Discord', :'tester', null, '222222222222222222'), 'Cancelled', 'and nowhere else');
select is((select status from public.message where unique_key = 'ev-4'), 'Pending', 'messages already allowed are not changed');
update public.message set status = 'Sending' where unique_key = 'ev-4';
update public.app_config set sandbox_allowed_email_domains = '{}' where id = 1;
update public.message set status = 'Pending' where unique_key = 'ev-4';
select is((select status from public.message where unique_key = 'ev-4'), 'Cancelled', 'the check runs again before a message is sent');

-- =============================================================== Sandbox reset
select (select count(*) from public.history_event) as hist_before \gset
insert into public.holiday (date, name) values ('2028-01-01', 'EV global holiday') on conflict do nothing;
insert into public.team_member (name, email) select 'EV Ops', 'ops@example.com'
  where not exists (select 1 from public.team_member where email = 'ops@example.com');
select tests.login_google('ops@example.com');
select throws_ok($$ select public.reset_sandbox_data('yes') $$, '22023', null, 'resetting needs RESET typed');
select public.reset_sandbox_data('RESET', 'me@allowed.test', '333333333333333333') as reset \gset
select tests.as_postgres();
select is((select string_agg(name, ', ' order by name) from public.domain), 'Backend, Fullstack', 'Sandbox has Backend and Fullstack');
select is((select count(*)::int from public.cohort where status = 'Running'), 4, 'with a weekend and a weekday cohort each, running at the same time');
select is((select count(distinct discord_user_id)::int from public.instructor where is_test), 1,
  'test instructors share one Discord user ID and use plus addresses of one mailbox');
select ok((select count(*) from public.history_event) > :hist_before, 'Activity history is kept, never deleted');
select ok(exists (select 1 from public.team_member where email = 'ops@example.com' and not is_placeholder),
  'real team members keep their access after a reset');
update public.app_config set environment = 'Production' where id = 1;
select tests.login_google('ops@example.com');
select throws_ok($$ select public.reset_sandbox_data('RESET') $$, '42501', null, 'Production data can never be reset');
select tests.as_postgres();

select * from finish();
rollback;
