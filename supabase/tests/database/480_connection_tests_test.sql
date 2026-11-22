-- Release 3, A7 (decision 310): Connections statuses and Send a test.
begin;
\ir ../helpers/helpers.psql
select plan(12);

select tests.company();
select tests.login_google('cta@example.com'); select tests.as_postgres();
select tests.login_google('ctb@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id, discord_prompt_dismissed_at)
select initcap(split_part(u.email, '@', 1)), u.email, u.id, now() from auth.users u where u.email in ('cta@example.com', 'ctb@example.com')
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id;
select public.set_admin((select id from public.team_member where email = 'cta@example.com'), true);
-- Nothing set up yet.
update public.discord_server set access = 'Waiting';
update public.app_config set admin_discord_channel_id = null where id = 1;
update public.action_queue set processed_at = null;
update public.message set status = 'Cancelled' where status in ('Sent', 'Failed', 'Pending', 'Scheduled');

select tests.login_google('cta@example.com');
select public.connection_status() as s \gset
select ok(not (:'s'::jsonb ->> 'discord_ready')::boolean and not (:'s'::jsonb ->> 'email_ready')::boolean,
  '1. nothing set up: Discord and email are not ready');
select throws_ok($$ select public.send_connection_test('Discord') $$, '22023',
  'No Discord server is approved yet. Add the bot with the invite link, then approve the server under Discord servers.',
  '2. a Discord test needs an approved server, and says how to get one');
select throws_ok($$ select public.send_connection_test('Fax') $$, '22023', 'Choose Discord or Email.', '3. only Discord or Email');

select tests.as_postgres();
select tests.approve_server('999000000000004801');
select throws_ok($$ select public.send_connection_test('Discord') $$, '42501', null, '4. a test needs a signed in team member');
select tests.login_google('cta@example.com');
select throws_ok($$ select public.send_connection_test('Discord') $$, '22023',
  'Choose the admin alert channel first, under Discord servers on this page.', '5. a Discord test needs the admin alert channel');

select tests.as_postgres();
update public.app_config set admin_discord_channel_id = '999000000000004811' where id = 1;
insert into public.action_queue (action, payload, status, processed_at) values ('deliver', '{}', 'Done', now());
insert into public.discord_channel (id, server_id, name) values ('999000000000004811', '999000000000004801', 'admin-alerts')
on conflict (id) do nothing;
select tests.login_google('cta@example.com');
select public.connection_status() as s \gset
select ok((:'s'::jsonb ->> 'discord_ready')::boolean and (:'s'::jsonb ->> 'email_ready')::boolean
          and :'s'::jsonb ->> 'discord_last_sent' is null,
  '6. set up and nothing sent: ready, no messages yet');

select lives_ok($$ select public.send_connection_test('Discord') $$, '7. an admin sends a Discord test');
select tests.as_postgres();
select ok(exists (select 1 from public.message m where m.template_id = 'T21' and m.channel = 'Discord'
                   and m.discord_channel_id = '999000000000004811' and m.status in ('Pending', 'Scheduled')),
  '8. it posts to the admin alert channel through the usual queue');
select tests.login_google('cta@example.com');
select throws_ok($$ select public.send_connection_test('Discord') $$, '22023',
  'A test was sent less than a minute ago. Wait a minute, then try again.', '9. one test a minute');
select lives_ok($$ select public.send_connection_test('Email') $$, '10. an admin sends an email test');
select tests.as_postgres();
select ok(exists (select 1 from public.message m where m.template_id = 'T21' and m.channel = 'Email' and m.to_address = 'cta@example.com')
          and (select count(*) from public.history_event h where h.action like 'Connection test sent: %') = 2,
  '11. the email goes to the admin''s own address, and both tests are in Activity history');

select tests.login_google('ctb@example.com');
select throws_ok($$ select public.send_connection_test('Email') $$, '42501', null, '12. only admins can send a test');

select * from finish();
rollback;
