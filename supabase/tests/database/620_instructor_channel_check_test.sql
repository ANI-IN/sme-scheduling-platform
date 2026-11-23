-- Owner's request of 23 November 2026 (decision 330): an instructor's Discord channel by link, ID or suggestion,
-- checked before it is saved (approved server, the bot can post, the instructor can see it), one welcome.
begin;
\ir ../helpers/helpers.psql
select plan(25);

select tests.scenario('CC', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
insert into public.discord_server (id, name, status, access) values
  ('999000000000062001', 'Server One', 'Ready', 'Approved'), ('999000000000062002', 'Server Two', 'Ready', 'Approved');
insert into public.discord_server_domain (server_id, domain_id) values ('999000000000062001', :'dom');
insert into public.discord_channel (id, server_id, name, bot_can_post) values
  ('999000000000062101', '999000000000062001', 'victor', true),
  ('999000000000062102', '999000000000062001', 'other-person', true),
  ('999000000000062103', '999000000000062002', 'elsewhere', true);
update public.domain set discord_server_id = '999000000000062001' where id = :'dom';
update public.app_config set discord_bot_user_id = '720000000000000099' where id = 1;
update public.instructor set full_name = 'CC Victor', discord_user_id = '720000000000000001', discord_status = 'Found'
 where id = :'i1';
update public.instructor set discord_user_id = null where id = :'i2';
-- The scenario gives each instructor a made up channel; these two start without one, as a new instructor does.
delete from public.instructor_channel where instructor_id in (:'i1', :'i2') and domain_id = :'dom';

-- What WF4 would answer from Discord: the channel and its overwrites, the roles, the bot and the instructor.
-- Roles: @everyone (the server id) with nothing, BOT with the given bits, MEM with nothing.
create or replace function tests.cc(p_check uuid, p_bot_bits bigint, p_overwrites jsonb, p_member_status int default 200)
returns jsonb language plpgsql as $$
declare v_action uuid := (select action_id from public.channel_check where id = p_check);
begin
  return public.record_discord_result(v_action, jsonb_build_object(
    'channel', jsonb_build_object('status', 200, 'body', jsonb_build_object('id', '999000000000062101', 'name', 'victor',
      'permission_overwrites', p_overwrites)),
    'roles', jsonb_build_object('status', 200, 'body', jsonb_build_array(
      jsonb_build_object('id', '999000000000062001', 'permissions', '0'),
      jsonb_build_object('id', '730000000000000001', 'permissions', p_bot_bits::text),
      jsonb_build_object('id', '730000000000000002', 'permissions', '0'))),
    'bot', jsonb_build_object('status', 200, 'body', jsonb_build_object('user', jsonb_build_object('id', '720000000000000099'),
      'roles', jsonb_build_array('730000000000000001'))),
    'member', jsonb_build_object('status', p_member_status, 'body', case when p_member_status = 200 then
      jsonb_build_object('user', jsonb_build_object('id', '720000000000000001'), 'roles', jsonb_build_array('730000000000000002')) end)));
end $$;
-- The bot may do all four things; the instructor's role may see the channel and read its history.
\set allbits 84992
\set member_ok '[{"id": "730000000000000002", "type": 0, "allow": "66560", "deny": "0"}]'

-- 1 to 4: what can be pasted.
select is(private.parse_discord_channel('https://discord.com/channels/999000000000062001/999000000000062101'),
  '999000000000062101', '1. a channel link');
select is(private.parse_discord_channel(' 999000000000062101 '), '999000000000062101', '2. a channel ID');
select is(private.parse_discord_channel('<#999000000000062101>'), '999000000000062101', '3. a channel mention');
select is(private.parse_discord_channel('#victor'), null, '4. a name is not a link or an ID');

-- 5 to 7: what is said at once.
select throws_ok(format($$ select public.check_instructor_channel(%L, %L, 'https://discord.com/channels/999000000000062002/999000000000062103') $$, :'i1', :'dom'),
  '22023', '#elsewhere is in Server Two, which is not approved for this domain. An admin approves it on Setup, Domains.',
  '5. a channel in a server not approved for the domain is refused, with what to do');
select throws_ok(format($$ select public.check_instructor_channel(%L, %L, '999000000000062102') $$, :'i2', :'dom'),
  '22023', null, '6. someone not found on Discord yet is refused');
select throws_ok(format($$ select public.check_instructor_channel(%L, %L, 'not a link') $$, :'i1', :'dom'),
  '22023', null, '7. something that is not a link or an ID is refused');

-- 8 to 12: a pasted link starts a check; the instructor cannot see the channel, so it is not saved.
select (public.check_instructor_channel(:'i1', :'dom', 'https://discord.com/channels/999000000000062001/999000000000062101') ->> 'check_id') as c1 \gset
select is((select status from public.channel_check where id = :'c1'), 'Checking', '8. the check starts');
select is((select action || ' ' || (payload ->> 'channel_id') from public.action_queue where id = (select action_id from public.channel_check where id = :'c1')),
  'discord_channel 999000000000062101', '9. and asks the automation to look in Discord');
select ok(exists (select 1 from jsonb_array_elements(public.next_discord_lookups(20)) w
                   where w ->> 'action' = 'discord_channel' and w ->> 'user_id' = '720000000000000001'
                     and w ->> 'bot_user_id' = '720000000000000099' and w ->> 'server_id' = '999000000000062001'),
  '10. which hands it the channel, the server, the instructor and the bot');
select tests.cc(:'c1', :'allbits', '[]');
select alike((select array_to_string(problems, ' ') from public.channel_check where id = :'c1'),
  'Give CC Victor access to #victor (View Channels), then choose the channel again.',
  '11. an instructor who cannot see the channel: exactly what to fix');
select ok(not exists (select 1 from public.instructor_channel where instructor_id = :'i1' and domain_id = :'dom'),
  '12. and it is not saved as their channel');

-- 13 to 14: by ID; the bot may not embed links.
select (public.check_instructor_channel(:'i1', :'dom', '999000000000062101') ->> 'check_id') as c2 \gset
select tests.cc(:'c2', 68608, :'member_ok');
select is((select array_to_string(problems, ' ') from public.channel_check where id = :'c2'),
  'Let the bot post in #victor: give the bot''s role Embed Links there, then choose the channel again.',
  '13. a channel the bot cannot post in: exactly what to fix');
select ok(not exists (select 1 from public.instructor_channel where instructor_id = :'i1' and domain_id = :'dom'),
  '14. and it is not saved');

-- 15: the instructor is not in the server.
select (public.check_instructor_channel(:'i1', :'dom', '999000000000062101') ->> 'check_id') as c3 \gset
select tests.cc(:'c3', :'allbits', :'member_ok', 404);
select is((select array_to_string(problems, ' ') from public.channel_check where id = :'c3'),
  'CC Victor is not a member of Server One. Invite them to the server, then choose the channel again.',
  '15. someone who is not in the server: invite them');

-- 16: a newer check replaces one still running, and the old answer changes nothing.
select (public.check_instructor_channel(:'i1', :'dom', '999000000000062101') ->> 'check_id') as c4 \gset
select (public.check_instructor_channel(:'i1', :'dom', '999000000000062101') ->> 'check_id') as c5 \gset
select is(tests.cc(:'c4', :'allbits', :'member_ok') ->> 'stale', 'true', '16. an answer for a replaced check changes nothing');

-- 17 to 22: everything is right: saved, ready, one welcome that tags them, logged.
select is(tests.cc(:'c5', :'allbits', :'member_ok') ->> 'status', 'Ready', '17. the bot can post and they can see it');
select is((select channel_id from public.instructor_channel where instructor_id = :'i1' and domain_id = :'dom'),
  '999000000000062101', '18. it is saved as their channel');
select ok((select ready_at is not null from public.instructor_channel where instructor_id = :'i1' and domain_id = :'dom'),
  '19. marked Channel ready');
select is((select count(*)::int from public.message where template_id = 'M22' and instructor_id = :'i1' and channel = 'Discord'
            and status <> 'Cancelled'), 1, '20. one welcome is posted in the channel');
select is((select discord_channel_id from public.message where template_id = 'M22' and instructor_id = :'i1' and channel = 'Discord' limit 1),
  '999000000000062101', '21. in their channel');
select ok(exists (select 1 from public.history_event where action = 'Discord channel ready for CC Victor'), '22. and logged');

-- 23: checking the same channel again sends no second welcome.
select (public.check_instructor_channel(:'i1', :'dom', '999000000000062101') ->> 'check_id') as c6 \gset
select tests.cc(:'c6', :'allbits', :'member_ok');
select is((select count(*)::int from public.message where template_id = 'M22' and instructor_id = :'i1' and channel = 'Discord'
            and status <> 'Cancelled'), 1, '23. the welcome goes only once');

-- 24 to 25: a channel already someone else's, and an alert channel, are refused at once.
update public.instructor set discord_user_id = '720000000000000002' where id = :'i2';
select throws_ok(format($$ select public.check_instructor_channel(%L, %L, '999000000000062101') $$, :'i2', :'dom'),
  '22023', '#victor is already the channel of CC Victor. Each instructor needs their own channel, so nobody else can answer for them.',
  '24. a channel already another instructor''s is refused');
update public.domain set alert_discord_channel_id = '999000000000062102' where id = :'dom';
select throws_ok(format($$ select public.check_instructor_channel(%L, %L, '999000000000062102') $$, :'i2', :'dom'),
  '22023', null, '25. an alert channel is refused');

select * from finish();
rollback;
