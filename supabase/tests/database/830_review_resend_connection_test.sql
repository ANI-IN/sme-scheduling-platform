-- Decision 349: R11, sending again goes to the current address, channel and Discord account, once at a time;
-- R16, a refused login waits and raises one alert; R18, each bounce once; R28, a lost app action again.
begin;
\ir ../helpers/helpers.psql
select plan(14);

select tests.scenario('RA', 'Live', '2027-01-31', 1) as a \gset
select tests.scenario('RB', 'Live', '2027-01-31', 1) as b \gset
select (:'a'::jsonb ->> 'domain') as da, (:'b'::jsonb ->> 'domain') as db, (:'a'::jsonb ->> 'i1') as ia,
       (:'b'::jsonb ->> 'i1') as ib, (:'a'::jsonb ->> 'mw') as mwa, (:'b'::jsonb ->> 'mw') as mwb,
       (:'a'::jsonb ->> 'ops') as ops \gset
select email as ops_email from public.team_member where id = :'ops' \gset
update public.instructor set discord_user_id = '700000000000000801' where id = :'ia';
update public.instructor set discord_user_id = '700000000000000803' where id = :'ib';
select channel_id as cha from public.instructor_channel where instructor_id = :'ia' and domain_id = :'da' \gset
select channel_id as chb from public.instructor_channel where instructor_id = :'ib' and domain_id = :'db' \gset
select tests.tick(:'da', '2027-01-01 18:00+00');
select tests.tick(:'db', '2027-01-01 18:00+00');
select set_config('app.test_now', '', true);
-- Then the same person is a test instructor in both domains, with one Discord account.
update public.instructor set is_test = true where id in (:'ia', :'ib');
update public.instructor set discord_user_id = '700000000000000801' where id = :'ib';

-- =============================================================== R11
select id as ask from public.message where instructor_id = :'ia' and template_id = 'M1' and channel = 'Email' limit 1 \gset
select id as post from public.message where instructor_id = :'ia' and template_id = 'M1' and channel = 'Discord' limit 1 \gset
update public.message set status = 'Sent', sent_at = now() where id in (:'ask', :'post');
-- A real instructor now, with a corrected email and a new Discord account.
update public.instructor set is_test = false, primary_email = 'ra.corrected@example.org', discord_user_id = '700000000000000802'
 where id = :'ia';
insert into public.discord_channel (id, server_id, name) values ('800000000000000901', '999000000000000001', 'ra-new')
on conflict (id) do nothing;
update public.instructor_channel set channel_id = '800000000000000901' where instructor_id = :'ia' and domain_id = :'da';
select tests.login_member(:'ops_email');
select (public.resend_message(:'ask') ->> 'message_id') as copy \gset
select tests.as_postgres();
select is((select to_address from public.message where id = :'copy'), 'ra.corrected@example.org',
  '4. an email sent again goes to the instructor''s current address');
select tests.login_member(:'ops_email');
select throws_like(format($$ select public.resend_message(%L) $$, :'ask'), '%already being sent again%',
  '5. not twice while the first copy waits');
select (public.resend_message(:'post') ->> 'message_id') as postcopy \gset
select tests.as_postgres();
select is((select discord_channel_id from public.message where id = :'postcopy'), '800000000000000901',
  '6. a channel post goes to their current channel');
update public.message set status = 'Cancelled' where id = :'postcopy';
select tests.login_member(:'ops_email');
select (public.resend_message(:'post') ->> 'message_id') as postcopy2 \gset
select tests.as_postgres();
select ok((select body_text not like '%700000000000000801%' and not ('700000000000000801' = any (mention_user_ids))
             from public.message where id = :'postcopy2'), '7. and tags their current Discord account, not the old one');

-- =============================================================== R16
select id as m16 from public.message where instructor_id = :'ib' and template_id = 'M1' and channel = 'Discord' limit 1 \gset
select tests.taken(:'m16');
select is(public.report_message_result(:'m16', false, null, '401 Unauthorized', true) ->> 'status', 'Retry',
  '8. an expired login is not a failed message, even when n8n calls it permanent');
select ok((select retry_at > now() + interval '10 minutes' and attempts = 0 from public.message where id = :'m16'),
  '9. it waits and keeps its tries');
select is((select count(*)::int from public.attention_item where dedupe_key like 'connection:Discord:%' and status <> 'Done'), 1,
  '10. one alert says the Discord connection is broken');
select is((select discord_failed_at from public.instructor where id = :'ib'), null, '11. nobody''s account is marked as failing');
select id as m16e from public.message where instructor_id = :'ib' and template_id = 'M1' and channel = 'Email' limit 1 \gset
select tests.taken(:'m16e');
select is(public.report_message_result(:'m16e', false, null, 'invalid_grant: Token has been expired or revoked.', true) ->> 'status',
  'Retry', '12. the same for the email connection');

-- =============================================================== R18
update public.message set status = 'Sent', sent_at = now(), external_id = 'thread-b' where id = :'m16e';
select to_address as bmail from public.message where id = :'m16e' \gset
select is(public.record_bounce(:'bmail', 'bounce-b1', 'Mailbox not found', 'thread-b', true) ->> 'matched', 'true', '13. a bounce is recorded');
select is(public.record_bounce(:'bmail', 'bounce-b1', 'Mailbox not found', 'thread-b', true) ->> 'duplicate', 'true', '14. only once');
select is((select count(*)::int from public.history_event where action like 'Email bounced:%'), 1, '15. one history entry');

-- =============================================================== R28
insert into public.action_queue (action, payload, status) values ('run_check_now', '{"k":"old"}', 'Processing');
insert into public.action_queue (action, payload, status) values ('run_check_now', '{"k":"new"}', 'Processing');
alter table public.action_queue disable trigger user;
update public.action_queue set updated_at = now() - interval '20 minutes' where payload ->> 'k' = 'old';
alter table public.action_queue enable trigger user;
set local request.jwt.claims = '{"role": "service_role"}';
set local request.jwt.claim.role = 'service_role';
select ok(exists (select 1 from public.next_actions(20) a where a.payload ->> 'k' = 'old'),
  '20. an action taken 20 minutes ago and never finished is handed out again');
select ok(not exists (select 1 from public.next_actions(20) a where a.payload ->> 'k' = 'new'), '21. a fresh one is left alone');
reset request.jwt.claim.role;
reset request.jwt.claims;

select * from finish();
rollback;
