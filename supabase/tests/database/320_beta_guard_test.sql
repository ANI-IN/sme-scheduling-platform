-- Release 3, M3 (decisions 277 and 287): the beta message guard and the daily email cap.
begin;
\ir ../helpers/helpers.psql
select plan(26);

select tests.company();
select tests.scenario('BG', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
update public.instructor set is_test = false where id = :'i1';
update public.instructor set is_test = true where id = :'i2';
-- A colleague who has signed in, with a Discord account; and a Discord account nobody on the team uses.
select tests.login_google('pat@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id, discord_user_id, discord_prompt_dismissed_at)
select 'Pat', 'pat@example.com', u.id, '700000000000000001', now() from auth.users u where u.email = 'pat@example.com'
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id, discord_user_id = excluded.discord_user_id;
insert into public.team_member (name, email, is_admin) values ('BG Admin', 'bg.admin@example.com', true)
on conflict ((lower(email))) do update set is_admin = true;
delete from public.message;
-- Release 3 M4: posts go only to channels the bot listed in an approved server.
insert into public.discord_channel (id, server_id, name) values ('800000000000000001', '999000000000000001', 'bg-post')
on conflict (id) do nothing;

create or replace function tests.q(p_key text, p_audience text, p_channel text, p_to text default null,
  p_instructor uuid default null, p_dm text default null, p_post text default null, p_tags text[] default '{}')
returns text language plpgsql as $$
begin
  insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, to_address,
    instructor_id, discord_dm_user_id, discord_channel_id, mention_user_ids, subject, body_text)
  values (p_audience, 'T_BG', p_channel, 'Pending', p_key, 'BG', p_to, p_instructor, p_dm, p_post, p_tags, 'BG', 'BG');
  return (select status from public.message where unique_key = p_key);
end $$;

-- 1 to 3: off by default (today's behaviour), and only admins change it.
select is(tests.q('bg-1', 'Team', 'Email', 'friend@gmail.com'), 'Pending', '1. with the default settings nothing new is blocked');
select tests.login_google('pat@example.com');
select throws_ok($$ select public.set_recipient_rules('{example.com}', 'Test instructors and signed in colleagues') $$,
  '42501', 'Only an admin can change this.', '2. only an admin changes who may receive messages');
select tests.as_postgres();
select lives_ok($$ select public.set_recipient_rules('{Example.com}', 'Test instructors and signed in colleagues') $$,
  '3. an admin (here the setup command) switches the beta guard on');
select ok(exists (select 1 from public.history_event where action = 'Who may receive messages changed'), '4. the change is logged');

-- 5 to 8: email.
select is(tests.q('bg-5', 'Team', 'Email', 'friend@gmail.com'), 'Cancelled', '5. email to an outside address is blocked');
select alike((select last_error from public.message where unique_key = 'bg-5'), 'Not sent: during the beta, email goes only to example.com addresses.%',
  '6. with the reason');
select ok(exists (select 1 from public.history_event where action = 'Message blocked' and note like 'Not sent: during the beta, email goes only to%'),
  '7. and logged in Activity history');
select is(tests.q('bg-8', 'Team', 'Email', 'colleague@example.com'), 'Pending', '8. email to a company address goes out');

-- 9 to 10: only test instructors are contacted.
select is(tests.q('bg-9', 'Instructor', 'Email', 'real@example.com', :'i1'), 'Cancelled', '9. a real instructor is never contacted, even at a company address');
select is(tests.q('bg-10', 'Instructor', 'Email', 'test.instructor@example.com', :'i2'), 'Pending', '10. a test instructor is');

-- 11 to 15: Discord direct messages and tags.
select is(tests.q('bg-11', 'Team', 'Discord', null, null, '700000000000000999'), 'Cancelled', '11. a direct message to a Discord account that is no signed in colleague''s is blocked');
select is(tests.q('bg-12', 'Team', 'Discord', null, null, '700000000000000001'), 'Pending', '12. a direct message to a signed in colleague goes out');
select is(tests.q('bg-13', 'Admin', 'Discord', null, null, null, '800000000000000001', '{700000000000000999}'), 'Cancelled',
  '13. a post that tags someone who is no signed in colleague is blocked');
select is(tests.q('bg-14', 'Admin', 'Discord', null, null, null, '800000000000000001', '{700000000000000001}'), 'Pending',
  '14. a post that tags only signed in colleagues goes out');
select is(tests.q('bg-15', 'Instructor', 'Discord', null, :'i1', null, '800000000000000001', '{700000000000000001}'), 'Cancelled',
  '15. a post to a real instructor is blocked whoever it tags');

-- 16: checked again when n8n claims the message (the setting changed in between).
select public.set_recipient_rules('{other.com}', 'Test instructors and signed in colleagues');
update public.message set status = 'Sending' where unique_key = 'bg-8';
select is((select status from public.message where unique_key = 'bg-8'), 'Cancelled', '16. a change between queueing and sending still stops the message');

-- 17 to 21: Production.
select public.set_recipient_rules('{example.com}', 'Test instructors and signed in colleagues');
update public.app_config set environment = 'Production' where id = 1;
update public.domain set status = 'Live' where id = :'dom';
update public.instructor set verified_at = coalesce(verified_at, now()) where id = :'i2';
select is(private.eligibility(:'i2', :'mw'), null, '17. in Production a test instructor may be asked while the beta setting is on');
select is(tests.q('bg-18', 'Instructor', 'Email', 'test.instructor@example.com', :'i2'), 'Pending', '18. and messaged');
select public.set_recipient_rules('{}', 'Anyone');
select is(private.eligibility(:'i2', :'mw'), 'Test instructor (not allowed in Live domains)', '19. with "Anyone", Production''s own rule is back');
select is(tests.q('bg-20', 'Instructor', 'Email', 'test.instructor@example.com', :'i2'), 'Cancelled', '20. and test instructors are never messaged');
select alike((select last_error from public.message where unique_key = 'bg-20'), 'Production never messages test instructors.%', '21. with Production''s reason');
update public.app_config set environment = 'Development' where id = 1;

-- 22 to 26: the daily email cap.
delete from public.message;
delete from public.attention_item where dedupe_key like 'email-cap:%';
update public.app_config set daily_email_cap = 1 where id = 1;
insert into public.message (audience, template_id, channel, status, recipient_label, to_address, subject, body_text, sent_at)
values ('Team', 'T_BG', 'Email', 'Sent', 'BG', 'a@example.com', 'BG', 'BG', now() - interval '1 hour');
select tests.q('bg-22', 'Team', 'Email', 'b@example.com');
select tests.q('bg-23', 'Team', 'Discord', null, null, '700000000000000001');
select is(private.email_cap_left(), 0, '22. one email sent in the last 24 hours reaches a cap of 1');
select is((select array_agg(channel) from public.claim_outbound_messages(25)), '{Discord}'::text[],
  '23. at the cap, emails wait and Discord messages still go out');
select is((select status from public.message where unique_key = 'bg-22'), 'Pending', '24. the email is kept for later, not cancelled');
select is((select count(*)::int from public.attention_item where dedupe_key like 'email-cap:%'), 1, '25. one task says the daily limit was reached');
select is(private.clock_work(), null, '26. the clock does not call n8n for emails that must wait');

select * from finish();
rollback;
