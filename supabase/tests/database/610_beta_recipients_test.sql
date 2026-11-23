-- Owner's urgent list of 23 November 2026 (decision 329): colleagues on the beta list may receive messages, blocked
-- messages are marked and can be sent again, and new work pokes n8n at once.
begin;
\ir ../helpers/helpers.psql
select plan(18);

select tests.company();
select tests.scenario('BR', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
update public.instructor set is_test = false, primary_email = 'vin@example.com', discord_user_id = '710000000000000001' where id = :'i1';
update public.instructor set is_test = false, primary_email = 'stranger@example.com', discord_user_id = '710000000000000002' where id = :'i2';
insert into public.team_member (name, email, is_admin) values ('BR Admin', 'br.admin@example.com', true)
on conflict ((lower(email))) do update set is_admin = true;
select tests.login_google('br.user@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id)
select 'BR User', 'br.user@example.com', u.id from auth.users u where u.email = 'br.user@example.com'
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id, is_admin = false;
delete from public.message;
select public.set_recipient_rules('{example.com}', 'Test instructors and signed in colleagues');
insert into public.discord_channel (id, server_id, name) values ('810000000000000001', '999000000000000001', 'br-post')
on conflict (id) do nothing;

create or replace function tests.br(p_key text, p_channel text, p_to text, p_instructor uuid, p_dm text default null,
  p_tags text[] default '{}') returns text language plpgsql as $$
begin
  insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, to_address,
    instructor_id, discord_dm_user_id, mention_user_ids, subject, body_text)
  values ('Instructor', 'M1', p_channel, 'Pending', p_key, 'BR', p_to, p_instructor, p_dm, p_tags, 'BR', 'BR');
  return (select status from public.message where unique_key = p_key);
end $$;

-- 1 to 4: a real instructor is blocked until their email is on the beta list; the block is marked and explained.
select is(tests.br('br-1', 'Email', 'vin@example.com', :'i1'), 'Cancelled', '1. a real instructor not on the beta list is blocked');
select ok((select blocked from public.message where unique_key = 'br-1'), '2. the message is marked blocked');
select alike((select last_error from public.message where unique_key = 'br-1'),
  'Not sent: during the beta, messages go only to test instructors, signed in colleagues and people on the beta list.%Settings, Admin%Send again.',
  '3. with the reason and what to do');
insert into public.beta_access (email) values ('vin@example.com');
select is(tests.br('br-4', 'Email', 'vin@example.com', :'i1'), 'Pending', '4. once their email is on the beta list, email goes out before any sign in');
select ok(not (select blocked from public.message where unique_key = 'br-4'), '5. and it is not marked blocked');

-- 6 to 8: Discord direct messages and tags of that instructor's own account; a stranger stays blocked.
select is(tests.br('br-6', 'Discord', null, :'i1', '710000000000000001'), 'Pending', '6. a direct message to their own Discord account goes out');
select is(tests.br('br-7', 'Discord', null, :'i2', '710000000000000002'), 'Cancelled', '7. one to an instructor who is not on the beta list is blocked');
select alike((select last_error from public.message where unique_key = 'br-7'), 'Not sent: during the beta, %', '8. with a plain reason');

-- 9 to 12: Send again after the rule allows it; only blocked messages, and logged.
select tests.login_google('br.user@example.com');
select public.resend_message((select id from public.message where unique_key = 'br-7'));
select tests.as_postgres();
select ok((select bool_and(status = 'Cancelled' and blocked) from public.message where unique_key like 'br-7:resend:%'),
  '9. Send again while the rule still stops it is blocked again, with the reason');
delete from public.message where unique_key like 'br-7:resend:%';
insert into public.beta_access (email) values ('stranger@example.com');
select tests.login_google('br.user@example.com');
select lives_ok(format($$ select public.resend_message((select id from public.message where unique_key = %L)) $$, 'br-7'),
  '10. once allowed, Send again queues it');
select tests.as_postgres();
select is((select count(*)::int from public.message where unique_key like 'br-7:resend:%' and status in ('Pending', 'Scheduled') and not blocked), 1,
  '11. as a new message that goes out (now, or at the instructor''s first sending time)');
select ok(exists (select 1 from public.history_event where action like 'Sent again after it was blocked:%'), '12. logged in Activity history');

-- 13 to 16: the setting: admins only, logged, and off means the beta list alone no longer counts.
select tests.login_google('br.user@example.com');
select throws_ok($$ select public.set_beta_list_recipients(false) $$, '42501', null, '13. only an admin changes the setting');
select tests.as_postgres();
select lives_ok($$ select public.set_beta_list_recipients(false) $$, '14. an admin (here the setup command) switches it off');
select ok(exists (select 1 from public.history_event where action = 'People on the beta list receive messages only after signing in'),
  '15. the change is logged');
select is(tests.br('br-16', 'Email', 'vin@example.com', :'i1'), 'Cancelled', '16. with it off, the beta list alone no longer lets a message through');

-- 17: a signed in colleague who is also an instructor receives messages whatever the setting.
update public.instructor set primary_email = 'br.user@example.com' where id = :'i2';
select is(tests.br('br-17', 'Email', 'br.user@example.com', :'i2'), 'Pending', '17. a signed in colleague who teaches receives messages');

-- 18: new work never fails because of the poke (the clock on, no pg_net or Vault in the test database).
update public.app_config set clock_enabled = true, n8n_poke_url = 'https://n8n.example.com/webhook/poke' where id = 1;
select lives_ok($$ insert into public.action_queue (action, payload) values ('discord_member', '{}') $$,
  '18. queueing a Discord check with the clock on works even when the poke cannot be sent');

select * from finish();
rollback;
