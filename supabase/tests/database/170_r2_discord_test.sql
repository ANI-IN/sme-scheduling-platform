-- Release 2 Milestone C: each domain uses an existing Discord server; people give a username and the
-- bot finds their user ID; instructors have one channel per domain chosen from the bot's list.
-- The automation's Discord answers are fed in here as raw HTTP results.
begin;
\ir ../helpers/helpers.psql
select plan(37);

select tests.company();
select tests.make_domain('DA') as dom \gset
select tests.make_domain('DB') as dom2 \gset
select tests.make_team_member('Disc Admin') as admin \gset

create or replace function tests.answer(p_action text, p_result jsonb, p_payload jsonb default '{}') returns jsonb language sql as $$
  select public.record_discord_result(
    (select id from public.action_queue where action = p_action and status = 'Processing' and payload @> p_payload
      order by created_at desc limit 1), p_result);
$$;
create or replace function tests.claim() returns jsonb language sql as $$ select public.next_discord_lookups(50); $$;

-- =============================================================== 1. the bot lists its servers
select public.check_discord('servers');
select is((select count(*)::int from public.action_queue where action = 'discord_servers' and status = 'Queued'), 1,
  '1. Refresh asks the automation for the bot''s servers');
select is((select count(*)::int from public.next_actions(20) where action like 'discord%'), 0,
  '1. the message runner (WF4) leaves Discord checks to the Discord workflow (WF6)');
select tests.claim();
select tests.answer('discord_servers', '{"guilds": {"status": 200, "body": [
  {"id": "111111111111111111", "name": "SME Backend"}, {"id": "222222222222222222", "name": "SME Fullstack"}]}}');
select is((select string_agg(name, ', ' order by name) from public.discord_server), 'SME Backend, SME Fullstack',
  '1. the servers are saved for people to choose from');

-- =============================================================== 2. choosing a domain's server
select throws_ok(format($$ select public.set_domain_discord_server(%L, '333333333333333333') $$, :'dom'), '22023', null,
  '2. a server the bot is not in cannot be chosen');
select public.set_domain_discord_server(:'dom', '111111111111111111');
select public.set_domain_discord_server(:'dom2', '222222222222222222');
select is((select discord_status from public.domain where id = :'dom'), 'Checking', '2. choosing a server starts a check');

-- =============================================================== 3. the server check: channels with their category
select tests.claim();
select tests.answer('discord_server', jsonb_build_object(
  'guild', '{"status": 200, "body": {"id": "111111111111111111", "name": "SME Backend"}}'::jsonb,
  'channels', '{"status": 200, "body": [
     {"id": "900000000000000001", "type": 4, "name": "1-1", "position": 1},
     {"id": "900000000000000002", "type": 0, "name": "maya-k", "parent_id": "900000000000000001", "position": 1},
     {"id": "900000000000000003", "type": 0, "name": "ravi-s", "parent_id": "900000000000000001", "position": 2},
     {"id": "900000000000000004", "type": 2, "name": "Voice", "position": 3}]}'::jsonb,
  'members', '{"status": 200}'::jsonb), jsonb_build_object('server_id', '111111111111111111'));
-- The Fullstack server: the members search is refused (Server Members Intent is off).
select tests.answer('discord_server', jsonb_build_object(
  'guild', '{"status": 200, "body": {"id": "222222222222222222", "name": "SME Fullstack"}}'::jsonb,
  'channels', '{"status": 200, "body": [{"id": "900000000000000010", "type": 0, "name": "general", "position": 1}]}'::jsonb,
  'members', '{"status": 403}'::jsonb), jsonb_build_object('server_id', '222222222222222222'));
select is((select discord_status from public.domain where id = :'dom'), 'Ready', '3. a server the bot can use is Ready');
select is((select string_agg(name || ' in ' || coalesce(category, '-'), ', ' order by position) from public.discord_channel
            where server_id = '111111111111111111'), 'maya-k in 1-1, ravi-s in 1-1',
  '3. text channels are listed with their category (voice channels are left out)');
select ok((select discord_problem from public.domain where id = :'dom2') like '%turn on Server Members Intent%',
  '3. without Server Members Intent the domain shows exactly what to turn on');
select ok(exists (select 1 from public.history_event where action = 'Discord server checked' and domain_id = :'dom'),
  '3. the check is in Activity history');

-- =============================================================== 4. a server the bot is not in
select public.check_discord('server', :'dom2');
select tests.claim();
select tests.answer('discord_server', '{"guild": {"status": 403}}');
select ok((select discord_problem from public.domain where id = :'dom2') like '%Open the invite link%',
  '4. a server the bot cannot open asks for the invite link');

-- =============================================================== 5. a username is cleaned and looked up
insert into public.instructor (full_name, primary_email, discord_username, verified_at)
values ('Maya Keane', 'maya.keane@example.org', ' @Maya.K ', now()) returning id as maya \gset
select is((select discord_username || ' ' || discord_status from public.instructor where id = :'maya'), 'maya.k Checking',
  '5. the username is saved in lowercase without @ and a check starts');
select ok(exists (select 1 from public.action_queue where action = 'discord_member' and payload ->> 'id' = :'maya'),
  '5. the automation is asked to find the person');
select throws_ok($$ insert into public.instructor (full_name, primary_email, discord_username) values ('Bad', 'bad@example.org', 'bad name!') $$,
  '22023', null, '5. a username with spaces or symbols is refused with an example');

-- =============================================================== 6. the work handed to the automation
insert into public.instructor_channel (instructor_id, domain_id, channel_id) values (:'maya', :'dom2', '900000000000000010');
select is((select x -> 'servers' from jsonb_array_elements(tests.claim()) x where x ->> 'username' = 'maya.k'),
  '["222222222222222222", "111111111111111111"]'::jsonb,
  '6. the servers of the instructor''s domains are searched first, then the others');

-- =============================================================== 7. found
select tests.answer('discord_member', '{"searches": [{"server_id": "222222222222222222", "status": 200, "body": []},
  {"server_id": "111111111111111111", "status": 200, "body": [
     {"user": {"id": "555555555555555551", "username": "maya.kay"}},
     {"user": {"id": "555555555555555552", "username": "maya.k"}}]}]}');
select is((select discord_status || ' ' || discord_user_id from public.instructor where id = :'maya'), 'Found 555555555555555552',
  '7. only the exact username counts: the right Discord account is found');
select ok(exists (select 1 from public.history_event where action = 'Discord account found' and instructor_id = :'maya'),
  '7. finding the account is in Activity history');

-- =============================================================== 8. not found
insert into public.instructor (full_name, primary_email, discord_username) values ('Ravi Singh', 'ravi@example.org', 'ravi.s')
returning id as ravi \gset
select tests.claim();
select tests.answer('discord_member', '{"searches": [{"server_id": "111111111111111111", "status": 200, "body": []}]}');
select is((select discord_status from public.instructor where id = :'ravi'), 'NotFound', '8. nobody with that username: Not found');
select ok((select discord_problem from public.instructor where id = :'ravi') like 'Nobody with the username ravi.s is in SME Backend%',
  '8. the problem names the username and the server');

-- =============================================================== 9. members search refused everywhere
update public.instructor set discord_username = 'ravi.singh' where id = :'ravi';
select tests.claim();
select tests.answer('discord_member', '{"searches": [{"server_id": "111111111111111111", "status": 403}]}');
select ok((select discord_problem from public.instructor where id = :'ravi') like '%turn on Server Members Intent%',
  '9. when the bot may not search members, the fix is named');

-- =============================================================== 10. the account belongs to someone else
update public.instructor set discord_username = 'maya.k2' where id = :'ravi';
select tests.claim();
select tests.answer('discord_member', '{"searches": [{"server_id": "111111111111111111", "status": 200, "body": [
  {"user": {"id": "555555555555555552", "username": "maya.k2"}}]}]}');
select is((select discord_status from public.instructor where id = :'ravi'), 'Problem', '10. an account already used by another instructor is refused');
select ok((select discord_problem from public.instructor where id = :'ravi') like '%already used by Maya Keane%', '10. and the other person is named');

-- =============================================================== 11. changing or removing the username
update public.instructor set discord_username = 'maya.new' where id = :'maya';
select is((select discord_user_id is null and discord_status = 'Checking' from public.instructor where id = :'maya'), true,
  '11. a new username forgets the old account and checks again');
select public.check_discord('instructor', :'maya');
select is((select count(*)::int from public.action_queue where action = 'discord_member' and status = 'Queued' and payload ->> 'id' = :'maya'), 1,
  '11. pressing Check Discord again does not queue the same check twice');
update public.instructor set discord_username = null where id = :'maya';
select is((select discord_status from public.instructor where id = :'maya'), 'NotSet', '11. removing the username clears the status');

-- =============================================================== 12. one channel per domain, from the list
-- Core readiness (decision 263): an instructor channel may be in any server the bot is in.
select lives_ok(format($$ select public.set_instructor_channel(%L, %L, '900000000000000010') $$, :'ravi', :'dom'),
  '12. a channel in another server the bot is in can be chosen');
select public.set_instructor_channel(:'ravi', :'dom', null);
select throws_ok(format($$ select public.set_instructor_channel(%L, %L, '900000000000000099') $$, :'ravi', :'dom'), '22023', null,
  '12. a channel that is not in the list cannot be chosen');
select public.set_instructor_channel(:'ravi', :'dom', '900000000000000003');
select is((select channel_name from public.instructor_channel where instructor_id = :'ravi' and domain_id = :'dom'), 'ravi-s',
  '12. the chosen channel is saved with its name');
select ok(exists (select 1 from public.history_event where entity_table = 'instructor_channel'), '12. choosing a channel is in Activity history');

-- =============================================================== 13. messages go to the channel of the class's domain
update public.instructor set discord_username = 'ravi.s' where id = :'ravi';
select tests.claim();
select tests.answer('discord_member', '{"searches": [{"server_id": "111111111111111111", "status": 200, "body": [
  {"user": {"id": "555555555555555553", "username": "ravi.s"}}]}]}');
select tests.make_module(:'dom', 'Disc Module') as dmod \gset
select tests.make_week(:'dmod', '2027-03-07') as dmw \gset
select private.queue_instructor_message('M1', :'ravi', :'dmw', null, now());
select is((select discord_channel_id from public.message where instructor_id = :'ravi' and channel = 'Discord' and template_id = 'M1'),
  '900000000000000003', '13. a request goes to the instructor''s channel in that domain');

-- =============================================================== 14. team members: username instead of user ID
update public.team_member set discord_user_id = null, discord_status = 'NotSet' where id = :'admin';
select tests.login_as('disc.admin@example.com');
select is((public.my_account() ->> 'needs_discord')::boolean, true, '14. a team member without Discord is asked once for a username');
select public.update_my_profile('@Disc.Admin');
select is((public.my_account() ->> 'needs_discord')::boolean, false, '14. after giving a username the question stops');
select tests.as_postgres();
select is((select discord_username || ' ' || discord_status from public.team_member where id = :'admin'), 'disc.admin Checking',
  '14. and the bot is asked to find them');

-- =============================================================== 15. only the automation can claim and answer Discord work
select tests.login_as('disc.admin@example.com');
select throws_ok('select public.next_discord_lookups(5)', '42501', null, '15. the app cannot take the automation''s Discord work');
select throws_ok(format('select public.record_discord_result(%L, %L)', gen_random_uuid(), '{}'), '42501', null,
  '15. nor write Discord answers');
select tests.as_postgres();

-- =============================================================== 16. Sandbox never contacts real instructors by direct message
update public.app_config set environment = 'Sandbox', sandbox_allowed_discord_servers = array['111111111111111111'] where id = 1;
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id, discord_dm_user_id, body_text)
values (:'dom', 'Instructor', 'M4', 'Discord', 'disc-dm-1', 'Pending', :'ravi', '555555555555555553', 'Hello') returning status as dm_status \gset
select is(:'dm_status'::text, 'Cancelled', '16. in Sandbox a direct message to a real instructor is blocked');
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id, discord_channel_id, body_text)
values (:'dom', 'Instructor', 'M4', 'Discord', 'disc-ch-1', 'Pending', :'ravi', '900000000000000003', 'Hello') returning status as ch_status \gset
select is(:'ch_status'::text, 'Cancelled', '16. a post tagging a real instructor is blocked too (Sandbox never contacts real instructors)');
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, discord_channel_id, body_text)
values (:'dom', 'Team', 'T4', 'Discord', 'disc-ch-2', 'Pending', '900000000000000003', 'Hello team') returning status as team_status \gset
select is(:'team_status'::text, 'Pending', '16. a team post in a channel of an allowed server is fine');

select * from finish();
rollback;
