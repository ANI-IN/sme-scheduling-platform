-- Release 3, M4 (decisions 278 and 288): Discord servers approved by an admin.
begin;
\ir ../helpers/helpers.psql
select plan(27);

select tests.company();
select tests.scenario('DA', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
insert into public.domain (name, status) values ('DA Other', 'Draft') returning id as dom2 \gset
-- The first instructor is asked, so a conversation is open (replies are read while one is).
select tests.tick(:'dom', '2027-01-01 18:00+00');
-- A normal user and an admin who have both signed in.
select tests.login_google('nina@example.com'); select tests.as_postgres();
select tests.login_google('omar@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id, discord_prompt_dismissed_at, is_admin)
select initcap(split_part(u.email, '@', 1)), u.email, u.id, now(), u.email = 'omar@example.com'
  from auth.users u where u.email in ('nina@example.com', 'omar@example.com')
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id, is_admin = excluded.is_admin;
-- The bot lists a new server with two channels (as the automation does).
insert into public.discord_server (id, name, status) values ('910000000000000001', 'Tester server', 'NotChecked');
insert into public.discord_channel (id, server_id, name) values ('910000000000000011', '910000000000000001', 'test-instructor-a'),
  ('910000000000000012', '910000000000000001', 'alerts');
delete from public.action_queue;
delete from public.message;

-- 1 to 6: a new server waits, and the bot does nothing there.
select is((select access from public.discord_server where id = '910000000000000001'), 'Waiting', '1. a new server waits for approval');
select private.queue_server_check('910000000000000001');
select is((select count(*)::int from public.action_queue where action = 'discord_server'), 0, '2. a waiting server is not checked (its channels are not read)');
select ok(not (private.member_servers('instructor', :'i1') ? '910000000000000001'), '3. usernames are not searched in a waiting server');
select throws_ok(format('select public.set_domain_discord_server(%L, %L)', :'dom', '910000000000000001'), '22023', null,
  '4. a domain cannot choose a waiting server');
insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, discord_channel_id, domain_id, subject, body_text)
values ('Admin', 'T_DA', 'Discord', 'Pending', 'da-5', 'DA', '910000000000000012', :'dom', 'DA', 'DA');
select is((select status from public.message where unique_key = 'da-5'), 'Cancelled', '5. nothing is posted in a waiting server');
select alike((select last_error from public.message where unique_key = 'da-5'), 'The bot only posts in Discord servers an admin has approved%', '6. with the reason');

-- 7 to 8: only admins decide.
select tests.login_google('nina@example.com');
select throws_ok(format('select public.set_discord_server_access(%L, ''Approved'', array[%L]::uuid[])', '910000000000000001', :'dom'),
  '42501', 'Only an admin can change this.', '7. a normal user cannot approve a server');
select tests.as_postgres();
select tests.login_google('omar@example.com');
select lives_ok(format('select public.set_discord_server_access(%L, ''Approved'', array[%L]::uuid[])', '910000000000000001', :'dom'),
  '8. an admin approves it for one domain');
select tests.as_postgres();

-- 9 to 19: approved for that domain only.
select is((select access from public.discord_server where id = '910000000000000001'), 'Approved', '9. the server is approved');
select ok(exists (select 1 from public.history_event where action = 'Discord server approved'), '10. the approval is logged');
select is((select count(*)::int from public.action_queue where action = 'discord_server' and payload ->> 'server_id' = '910000000000000001'), 1,
  '11. its channels are read right after the approval');
select ok(private.member_servers('instructor', :'i1') ? '910000000000000001', '12. usernames are searched there now');
select lives_ok(format('select public.set_domain_discord_server(%L, %L)', :'dom', '910000000000000001'), '13. the approved domain can use it');
select throws_ok(format('select public.set_domain_discord_server(%L, %L)', :'dom2', '910000000000000001'), '22023', null,
  '14. another domain cannot');
select lives_ok(format('select public.set_instructor_channel(%L, %L, %L)', :'i1', :'dom', '910000000000000011'),
  '15. an instructor channel can be chosen there for the approved domain');
select throws_ok(format('select public.set_instructor_channel(%L, %L, %L)', :'i1', :'dom2', '910000000000000011'), '22023', null,
  '16. not for another domain');
insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, discord_channel_id, domain_id, subject, body_text)
values ('Admin', 'T_DA', 'Discord', 'Pending', 'da-17', 'DA', '910000000000000012', :'dom', 'DA', 'DA'),
       ('Admin', 'T_DA', 'Discord', 'Pending', 'da-18', 'DA', '910000000000000012', :'dom2', 'DA', 'DA'),
       ('Admin', 'T_DA', 'Discord', 'Pending', 'da-19', 'DA', '910000000000000099', :'dom', 'DA', 'DA');
select is((select status from public.message where unique_key = 'da-17'), 'Pending', '17. posts for the approved domain go out');
select is((select status from public.message where unique_key = 'da-18'), 'Cancelled', '18. posts for another domain are blocked');
select is((select status from public.message where unique_key = 'da-19'), 'Cancelled', '19. a channel the bot never listed is blocked');

-- 20: typed replies are read only in approved servers (the instructor was asked in the setup).
update public.instructor set discord_user_id = '920000000000000001' where id = :'i1';
select ok(exists (select 1 from public.discord_watchlist() w where w.channel_id = '910000000000000011'),
  '20. replies are read in a channel of an approved server');

-- 21 to 26: removing access.
select tests.login_google('omar@example.com');
select lives_ok(format('select public.set_discord_server_access(%L, ''Removed'')', '910000000000000001'), '21. an admin removes access at any time');
select tests.as_postgres();
select is((select discord_status from public.domain where id = :'dom'), 'Problem', '22. the domain that used it needs a fix');
select ok(exists (select 1 from public.attention_item where domain_id = :'dom' and title = 'Discord server no longer available'),
  '23. with one task');
select ok(not exists (select 1 from public.discord_watchlist() w where w.channel_id = '910000000000000011'), '24. replies are no longer read there');
insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, discord_channel_id, domain_id, subject, body_text)
values ('Admin', 'T_DA', 'Discord', 'Pending', 'da-25', 'DA', '910000000000000012', :'dom', 'DA', 'DA');
select is((select status from public.message where unique_key = 'da-25'), 'Cancelled', '25. and nothing is posted');
select ok(exists (select 1 from public.history_event where action = 'Discord server access removed'), '26. the removal is logged');

-- 27: refusing a waiting server.
insert into public.discord_server (id, name, status) values ('910000000000000002', 'Unknown server', 'NotChecked');
select public.set_discord_server_access('910000000000000002', 'Refused');
select is((select access from public.discord_server where id = '910000000000000002'), 'Refused', '27. a server can be refused');

select * from finish();
rollback;
