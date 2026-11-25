-- Release 3, A9: what already works with more than one Discord server (no new routing; a check of today's rules).
-- One domain posts to channels in three approved servers; its instructors' channels are in different servers; a server
-- added later changes nothing for existing instructors; a deleted channel leaves the email copy and one clear task.
begin;
\ir ../helpers/helpers.psql
select plan(14);

select tests.scenario('MS', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset

-- Three servers approved for this domain only, one channel each; a fourth server approved for no domain.
insert into public.discord_server (id, name, status, access) values
  ('999000000000049001', 'Server A', 'Ready', 'Approved'), ('999000000000049002', 'Server B', 'Ready', 'Approved'),
  ('999000000000049003', 'Server C', 'Ready', 'Approved'), ('999000000000049004', 'Server E', 'Ready', 'Approved');
insert into public.discord_server_domain (server_id, domain_id) values
  ('999000000000049001', :'dom'), ('999000000000049002', :'dom'), ('999000000000049003', :'dom');
insert into public.discord_channel (id, server_id, name, bot_can_post) values
  ('999000000000049101', '999000000000049001', 'ms-alerts', true),
  ('999000000000049102', '999000000000049002', 'instr-one', true),
  ('999000000000049103', '999000000000049003', 'instr-two', true),
  ('999000000000049104', '999000000000049004', 'elsewhere', true);
update public.domain set alert_discord_channel_id = '999000000000049101', discord_server_id = '999000000000049001' where id = :'dom';

-- Instructors whose channels are in different servers.
select lives_ok(format($$ select public.set_instructor_channel(%L, %L, '999000000000049102') $$, :'i1', :'dom'),
  '1. an instructor''s channel can be in server B');
select lives_ok(format($$ select public.set_instructor_channel(%L, %L, '999000000000049103') $$, :'i2', :'dom'),
  '2. another instructor''s channel can be in server C, for the same domain');
select throws_ok(format($$ select public.set_instructor_channel(%L, %L, '999000000000049104') $$, :'i2', :'dom'), '22023',
  'An admin must approve the Discord server of #elsewhere for this domain first: Setup, Domains, open the domain, Discord server.',
  '3. a channel in a server not approved for this domain is refused, with what to do');

-- A new channel needs a new contact check (decision 176); the instructors confirm it, as they would.
update public.instructor set verified_at = now() where id in (:'i1', :'i2');

-- A domain using channels in three servers: the team alert in A, the instructors in B and C.
select private.queue_team_message('T9', :'dom', 'alert', null, '{}', 'MS check', 'MS check', 'ms-alert-1', now());
select is((select discord_channel_id || ' ' || status from public.message where unique_key = 'ms-alert-1:Discord'),
  '999000000000049101 Pending', '4. the domain''s alert goes to its channel in server A');
select public.start_asking_now(:'mw');
-- Sent now, or held until the instructor's quiet hours end (it depends on the time the test runs): either way queued.
select is((select discord_channel_id || ' ' || (status in ('Pending', 'Scheduled'))::text from public.message
            where module_week_id = :'mw' and instructor_id = :'i1' and channel = 'Discord' and discord_channel_id is not null
            order by created_at limit 1), '999000000000049102 true',
  '5. the first instructor is asked in their channel in server B');
select ok(exists (select 1 from public.message where module_week_id = :'mw' and instructor_id = :'i1' and channel = 'Email'
                   and status <> 'Cancelled'), '6. and by email, as every instructor is');
select public.skip_to_next(:'mw');
-- Sent now, or held until the instructor's quiet hours end (it depends on the time the test runs): either way queued.
select is((select discord_channel_id || ' ' || (status in ('Pending', 'Scheduled'))::text from public.message
            where module_week_id = :'mw' and instructor_id = :'i2' and channel = 'Discord' and discord_channel_id is not null
            order by created_at limit 1), '999000000000049103 true',
  '7. the next instructor is asked in their channel in server C');
select is((select count(*)::int from public.message m where m.domain_id = :'dom' and m.status = 'Cancelled'
            and m.discord_channel_id in ('999000000000049101', '999000000000049102', '999000000000049103')), 0,
  '8. the guard lets every one of them out: each channel''s own server is approved for the domain');

-- Adding a server later changes nothing for existing instructors.
select tests.login_google('msadmin@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id) select 'Ms Admin', u.email, u.id from auth.users u where u.email = 'msadmin@example.com'
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id;
update public.team_member set is_admin = true where email = 'msadmin@example.com';
select tests.login_google('msadmin@example.com');
select lives_ok($$ select public.set_discord_server_access('999000000000049004', 'Approved',
  array[(select id from public.domain where name = 'MS')]) $$, '9. an admin approves a new server for the domain later');
select tests.as_postgres();
select is((select string_agg(right(channel_id, 3), ',' order by right(channel_id, 3)) from public.instructor_channel where domain_id = :'dom'),
  '102,103', '10. the existing instructors keep their channels');
select ok(private.server_allowed('999000000000049001', :'dom') and private.server_allowed('999000000000049002', :'dom')
          and private.server_allowed('999000000000049003', :'dom') and private.server_allowed('999000000000049004', :'dom')
          and (select discord_server_id from public.domain where id = :'dom') = '999000000000049001',
  '11. the other servers stay approved and the domain''s main server is unchanged');

-- A deleted channel: the post fails for good, the email copy already went, and one clear task says so.
select id as m1 from public.message where module_week_id = :'mw' and instructor_id = :'i1' and channel = 'Discord'
   and discord_channel_id = '999000000000049102' order by created_at limit 1 \gset
select tests.taken(:'m1');
select public.report_message_result(:'m1', false, null, 'Unknown Channel (10003)', true);
select tests.taken(:'m1');
select public.report_message_result(:'m1', false, null, 'Unknown Channel (10003)', true);
select is((select count(*)::int from public.attention_item a where a.type = 'MessageFailed' and a.domain_id = :'dom'
            and a.dedupe_key = 'msgfail:' || :'m1'), 1, '12. one task, even when the failure is reported twice');
select ok((select a.title like '%could not be posted in%Discord channel.%' and a.detail like '%still got it by email%'
             from public.attention_item a where a.dedupe_key = 'msgfail:' || :'m1'),
  '13. the task says what failed and that the email still reached them');
select ok((select discord_failed_at is not null from public.instructor where id = :'i1'),
  '14. the instructor is marked, so their Discord channel is checked before the next message');

select * from finish();
rollback;
