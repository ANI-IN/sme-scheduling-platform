-- Release 2 Milestone D: who gets which Discord post, direct message and email.
begin;
\ir ../helpers/helpers.psql
select plan(31);

select tests.scenario('NT', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3,
       (:'j'::jsonb ->> 'owner') as owner, (:'j'::jsonb ->> 'ops') as ops \gset
-- Instructor 1 has a channel in this domain. Instructor 2 has Discord but no channel. Instructor 3 has no Discord.
update public.instructor set discord_channel_id = null where id in (:'i1', :'i2', :'i3');
delete from public.instructor_channel where instructor_id in (:'i1', :'i2', :'i3');
insert into public.discord_channel (id, server_id, name, category) values
  ('910000000000000001', '111111111111111111', 'nt-instr1', '1-1'), ('910000000000000002', '111111111111111111', 'nt-instr2', '1-1');
insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name) values (:'i1', :'dom', '910000000000000001', 'nt-instr1');
update public.instructor set discord_user_id = null where id = :'i3';
-- The operations person has no Discord: they get email copies.
update public.team_member set discord_user_id = null where id = :'ops';

create or replace function tests.m(p_mw uuid, p_tpl text, p_instr uuid) returns setof public.message language sql as $$
  select * from public.message where module_week_id = p_mw and template_id = p_tpl and instructor_id = p_instr order by created_at;
$$;

-- =============================================================== 1. a request to an instructor with a channel
select private.queue_instructor_message('M1', :'i1', :'mw', null, '2027-01-02 18:00+00', '[{"label": "Yes", "answer": "Yes", "url": "https://x/?t=1"}, {"label": "No", "answer": "No", "url": "https://x/?t=2"}]');
select is((select string_agg(channel || ':' || coalesce(discord_channel_id, '-') || ':' || coalesce(discord_dm_user_id, '-'), ', ' order by channel)
             from tests.m(:'mw', 'M1', :'i1')), 'Discord:910000000000000001:-, Email:-:-',
  '1. a request goes to the instructor''s channel and by email, not by direct message');
select ok((select mention_user_ids = array[(select discord_user_id from public.instructor where id = :'i1')] and body_text like 'Hi <@%'
             from tests.m(:'mw', 'M1', :'i1') where channel = 'Discord'), '1. the instructor is tagged in the post');
select is((select jsonb_array_length(buttons) from tests.m(:'mw', 'M1', :'i1') where channel = 'Discord'), 2, '1. with Yes and No buttons');

-- =============================================================== 2. no channel in this domain: a direct message
select private.queue_instructor_message('M1', :'i2', :'mw', null, '2027-01-02 18:00+00');
select is((select string_agg(channel || ':' || coalesce(discord_channel_id, '-') || ':' || (discord_dm_user_id is not null), ', ' order by channel)
             from tests.m(:'mw', 'M1', :'i2')), 'Discord:-:true, Email:-:false',
  '2. without a channel in this domain the request goes by direct message and email');

-- =============================================================== 3. no Discord at all: email only
select private.queue_instructor_message('M1', :'i3', :'mw', null, '2027-01-02 18:00+00');
select is((select string_agg(channel, ', ') from tests.m(:'mw', 'M1', :'i3')), 'Email', '3. without Discord the request goes by email only');

-- =============================================================== 4. a channel in another domain is not used here
select tests.scenario('NU', 'Live', '2027-02-07', 1) as j2 \gset
select (:'j2'::jsonb ->> 'mw') as mw2, (:'j2'::jsonb ->> 'domain') as dom2 \gset
select private.queue_instructor_message('M1', :'i1', :'mw2', null, '2027-01-02 18:00+00');
select is((select string_agg(channel || ':' || (discord_dm_user_id is not null), ', ' order by channel) from tests.m(:'mw2', 'M1', :'i1')),
  'Discord:true, Email:false', '4. a channel belongs to one domain: in another domain the instructor gets a direct message');

-- =============================================================== 5 to 8. the confirmation
select public.assign_manually(:'mw', :'i1');
select is((select count(*)::int from tests.m(:'mw', 'M4', :'i1') where channel = 'Discord' and discord_channel_id = '910000000000000001'), 1,
  '5. the confirmation is posted in the instructor''s channel');
select ok((select mention_user_ids @> array[(select discord_user_id from public.instructor where id = :'i1'),
                                           (select discord_user_id from public.team_member where id = :'owner')]
             from tests.m(:'mw', 'M4', :'i1') where discord_channel_id is not null),
  '5. tagging the instructor and the owner');
select ok((select body_text like '%Team: <@%' from tests.m(:'mw', 'M4', :'i1') where discord_channel_id is not null), '5. the team tags are in the text');
select is((select count(*)::int from tests.m(:'mw', 'M4', :'i1') where channel = 'Discord' and discord_dm_user_id is not null and discord_channel_id is null), 1,
  '6. the instructor also gets the confirmation by direct message');
select is((select count(*)::int from tests.m(:'mw', 'M4', :'i1') where channel = 'Email'), 1, '6. and by email');
select is(tests.msgs(:'mw', 'T2'), 0, '7. no extra post in the alert channel: the team is tagged in the instructor''s channel');
select is((select channel from public.message where module_week_id = :'mw' and template_id = 'T2' and team_member_id = :'owner'), 'Discord',
  '7. the owner gets a direct message');
select is((select channel from public.message where module_week_id = :'mw' and template_id = 'T2' and team_member_id = :'ops'), 'Email',
  '7. the operations person without Discord gets an email instead');
select is((select count(*)::int from public.message where module_week_id = :'mw' and template_id = 'T2' and team_member_id = :'owner'), 1,
  '8. one copy per person (no duplicates)');
-- Queuing the same messages again changes nothing.
select private.queue_instructor_message('M4', :'i1', :'mw', (select request_id from public.message where module_week_id = :'mw' and template_id = 'M4' limit 1), now());
select is((select count(*)::int from tests.m(:'mw', 'M4', :'i1')), 3, '8. queuing the confirmation again sends nothing twice');

-- =============================================================== 9. a confirmation without a channel
select public.assign_manually(:'mw2', :'i1');
select is((select string_agg(channel || ':' || (discord_dm_user_id is not null), ', ' order by channel) from tests.m(:'mw2', 'M4', :'i1')),
  'Discord:true, Email:false', '9. without a channel: the confirmation goes by direct message and email (once each)');
select is(tests.msgs(:'mw2', 'T2'), 1, '9. and the team is tagged in the alert channel instead');

-- =============================================================== 10. reminders and help replies
select private.queue_instructor_message('M6', :'i1', :'mw', null, now());
select is((select string_agg(channel || ':' || coalesce(discord_channel_id, '-'), ', ' order by channel) from tests.m(:'mw', 'M6', :'i1')),
  'Discord:910000000000000001, Email:-', '10. a reminder before class goes to the channel and by email');
select private.queue_instructor_message('M14', :'i1', :'mw', null, now(), '[]', '{"text": "The Zoom link is fixed.", "from": "Ops"}');
select is((select string_agg(channel || ':' || coalesce(discord_channel_id, '-'), ', ' order by channel) from tests.m(:'mw', 'M14', :'i1')),
  'Discord:910000000000000001, Email:-', '10. a help reply goes to the channel and by email');

-- =============================================================== 11. replacement
insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name) values (:'i2', :'dom', '910000000000000002', 'nt-instr2');
select public.release_booking(:'mw', 'Found someone closer to the time zone', true);
select is((select string_agg(channel || ':' || coalesce(discord_channel_id, '-'), ', ' order by channel) from tests.m(:'mw', 'M16', :'i1')),
  'Discord:910000000000000001, Email:-', '11. the released instructor gets a thank you and release note in their own channel');
select ok((select body_text from tests.m(:'mw', 'M16', :'i1') where channel = 'Discord') like '%Thank you for being ready to teach%',
  '11. the note thanks them');
select public.assign_manually(:'mw', :'i2');
select is((select discord_channel_id from tests.m(:'mw', 'M4', :'i2') where discord_channel_id is not null), '910000000000000002',
  '11. the new confirmation goes to the new instructor''s channel');

-- =============================================================== 12 to 14. failures say exactly what to fix
select id as dm_msg from public.message where module_week_id = :'mw2' and template_id = 'M4' and channel = 'Discord' \gset
select public.report_message_result(:'dm_msg', false, null, 'Discord 403: {"code": 50007, "message": "Cannot send messages to this user"}', true);
select ok((select detail from public.attention_item where dedupe_key = 'msgfail:' || :'dm_msg') like '%does not accept direct messages from the server%choose a channel%',
  '12. a refused direct message creates a task that says what to do');
select ok(exists (select 1 from public.message m join public.attention_item a on a.id = m.attention_item_id
                   where a.dedupe_key = 'msgfail:' || :'dm_msg' and m.template_id = 'T14' and m.channel = 'Email'),
  '12. and the operations team gets an email (Discord may be what is broken)');
select is((select max(n)::int from (select count(*) n from public.message m join public.attention_item a on a.id = m.attention_item_id
            where a.dedupe_key = 'msgfail:' || :'dm_msg' and m.team_member_id is not null group by m.team_member_id) x), 1,
  '12. one message per operations person about the failure, never two');
select id as t14_mail from public.message m where m.template_id = 'T14' and m.channel = 'Email'
   and m.attention_item_id = (select id from public.attention_item where dedupe_key = 'msgfail:' || :'dm_msg') limit 1 \gset
select public.report_message_result(:'t14_mail', false, null, 'invalid_grant', true);
select is((select count(*)::int from public.attention_item where dedupe_key = 'msgfail:' || :'t14_mail'), 0,
  '12. when that email fails too, it is only logged: no new task, so failures never go round in circles');
select ok(exists (select 1 from public.history_event where category = 'Discord' and action like 'M4 failed to NT Instr1 via Discord direct message'),
  '12. the failure is in Activity history under Discord');
select id as ch_msg from public.message where module_week_id = :'mw' and template_id = 'M6' and channel = 'Discord' \gset
select public.report_message_result(:'ch_msg', false, null, 'Discord 404: {"code": 10003, "message": "Unknown Channel"}', true);
select ok((select detail from public.attention_item where dedupe_key = 'msgfail:' || :'ch_msg') like '%#nt-instr1 no longer exists. Choose a new channel%',
  '13. a deleted channel: the task names it and says to choose a new one');
select id as ok_msg from public.message where module_week_id = :'mw' and template_id = 'M14' and channel = 'Discord' \gset
select public.report_message_result(:'ok_msg', true, 'discord-1');
select ok(exists (select 1 from public.history_event where category = 'Discord' and action = 'M14 sent to NT Instr1 via Discord (#nt-instr1)'),
  '14. every Discord send is in Activity history with the channel');

-- =============================================================== 15. testing: never a direct message
select tests.scenario('NX', 'Test', '2027-01-31', 1) as j3 \gset
select (:'j3'::jsonb ->> 'mw') as mw3, (:'j3'::jsonb ->> 'i1') as x1 \gset
update public.instructor set discord_channel_id = null where id = :'x1';
select private.queue_instructor_message('M1', :'x1', :'mw3', null, now());
select is((select string_agg(channel || ':' || (discord_dm_user_id is null) || ':' || (discord_channel_id = (select test_discord_channel_id from public.domain d join public.module_week w on w.domain_id = d.id where w.id = :'mw3')), ', ' order by channel)
             from tests.m(:'mw3', 'M1', :'x1') where channel = 'Discord'), 'Discord:true:true',
  '15. in a testing domain, Discord copies go only to the testing channel, never by direct message');

select * from finish();
rollback;
