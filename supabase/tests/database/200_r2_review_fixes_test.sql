-- Release 2 Milestone F: one or more checks for each high and medium review finding that was fixed
-- (docs/reviews/*.md). The finding ID is at the start of each description.
begin;
\ir ../helpers/helpers.psql
-- These checks are about quiet hours, which are off unless an admin turns them on (decision 332): on here.
update public.setting_definition set default_value = 'true' where key = 'instructor_quiet_hours_on';
select plan(41);

select tests.scenario('RF', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3,
       (:'j'::jsonb ->> 'owner') as owner, (:'j'::jsonb ->> 'ops') as ops \gset

-- ============================================================ Discord and notifications
-- DIS-3: a check that hits a temporary Discord error keeps the account and the contact check.
update public.instructor set discord_username = 'rf.instr1', version = version where id = :'i1';
update public.instructor set discord_user_id = '930000000000000001', discord_status = 'Found' where id = :'i1';
update public.instructor set verified_at = now() where id = :'i1';
select public.record_discord_result((select id from public.action_queue where action = 'discord_member' and payload ->> 'id' = :'i1' order by created_at desc limit 1),
  '{"searches": [{"server_id": "111111111111111111", "status": 429, "body": []}]}');
select ok((select discord_user_id is not null and verified_at is not null and discord_status = 'Problem' from public.instructor where id = :'i1'),
  'DIS-3 a temporary Discord error keeps the Discord account and the contact check');

-- DIS-7: the username changed while Discord was searched: the answer is not used, a new check is queued.
select public.check_discord('instructor', :'i1');
select public.next_discord_lookups(50) is not null as handed_out \gset
update public.instructor set discord_username = 'rf.instr1.new', version = version where id = :'i1';
select (public.record_discord_result((select id from public.action_queue where action = 'discord_member' and payload ->> 'id' = :'i1' and status = 'Processing' limit 1),
  '{"searches": [{"server_id": "111111111111111111", "status": 200, "body": []}]}') ->> 'stale')::boolean as stale \gset
select ok(:'stale'::boolean and exists (select 1 from public.action_queue where action = 'discord_member' and payload ->> 'id' = :'i1' and status = 'Queued'),
  'DIS-7 an answer for an old username is ignored and the new username is looked up');
update public.action_queue set status = 'Processing', updated_at = now() - interval '11 minutes' where action = 'discord_member' and payload ->> 'id' = :'i1';
select public.next_discord_lookups(50);
select ok(exists (select 1 from public.action_queue where action = 'discord_member' and payload ->> 'id' = :'i1' and status = 'Processing' and updated_at > now() - interval '1 minute'),
  'DIS-7 a check stuck for more than 10 minutes is handed out again');

-- DIS-12: the bot's permissions decide which channels can be chosen.
select ok(private.discord_can_post('{"permission_overwrites": []}', '1', '[{"id": "1", "permissions": "3072"}]', '[]', '9'),
  'DIS-12 View Channels and Send Messages from the everyone role: the bot can post');
select ok(not private.discord_can_post('{"permission_overwrites": [{"id": "1", "type": 0, "allow": "0", "deny": "1024"}]}', '1',
            '[{"id": "1", "permissions": "3072"}]', '[]', '9'),
  'DIS-12 a private channel that hides it from everyone: the bot cannot post');
select ok(private.discord_can_post('{"permission_overwrites": [{"id": "1", "type": 0, "allow": "0", "deny": "1024"}, {"id": "5", "type": 0, "allow": "3072", "deny": "0"}]}', '1',
            '[{"id": "1", "permissions": "3072"}, {"id": "5", "permissions": "0"}]', '["5"]', '9'),
  'DIS-12 the bot''s role allowed in a private channel (like the 1-1 category): the bot can post');
insert into public.discord_channel (id, server_id, name, bot_can_post) values ('920000000000000001', '111111111111111111', 'locked', false),
  ('920000000000000002', '111111111111111111', 'rf-shared', true);
-- Release 3 M4: the server is approved first (decision 288).
select tests.approve_server('111111111111111111');
update public.domain set discord_server_id = '111111111111111111', version = version where id = :'dom';
select throws_like($$ select public.set_instructor_channel('$$ || :'i2' || $$'::uuid, '$$ || :'dom' || $$'::uuid, '920000000000000001') $$,
  '%cannot post in #locked%', 'DIS-12 a channel the bot cannot post in cannot be chosen');

-- DIS-15: one channel is never two instructors' channel.
select public.set_instructor_channel(:'i2', :'dom', '920000000000000002');
select throws_like($$ select public.set_instructor_channel('$$ || :'i3' || $$'::uuid, '$$ || :'dom' || $$'::uuid, '920000000000000002') $$,
  '%already the channel of%', 'DIS-15 another instructor''s channel cannot be chosen');

-- DIS-6: choosing "No channel" really means a direct message (the old Release 1 channel is not used).
select public.set_instructor_channel(:'i3', :'dom', null);
update public.instructor set discord_channel_id = tests.rand_discord() where id = :'i3';
select private.queue_instructor_message('M1', :'i3', :'mw', null, '2027-01-02 18:00+00', '[]', '{}', false, 'dis6');
select is((select discord_channel_id is null and discord_dm_user_id is not null from public.message
            where instructor_id = :'i3' and template_id = 'M1' and channel = 'Discord' and unique_key like '%dis6'), true,
  'DIS-6 without a channel in the domain the instructor gets a direct message, never an old channel');

-- DIS-9: a direct message never carries the team's tags.
select public.assign_manually(:'mw', :'i3');
select ok((select body_text not like '%Team:%' and cardinality(mention_user_ids) <= 1 from public.message
            where instructor_id = :'i3' and template_id = 'M4' and discord_dm_user_id is not null limit 1),
  'DIS-9 the confirmation by direct message does not list or tag the team');

-- DIS-4: a team member without Discord gets email for personal reminders.
update public.team_member set discord_user_id = null, digest_channel = 'Discord', version = version where id = :'ops';
select private.queue_team_message('REM', :'dom', 'person', :'ops', '{}', 'Reminder', 'Still open', 'rf-rem', now());
select is((select string_agg(channel, ',') from public.message where unique_key like 'rf-rem:%'), 'Email',
  'DIS-4 a team member without Discord gets the reminder by email');

-- DIS-1, DIS-10: a failed direct message to a team member: one email instead, one task, no loop.
update public.team_member set discord_user_id = tests.rand_discord(), version = version where id = :'owner';
select private.queue_team_message('T4', :'dom', 'people', null, array[:'owner'::uuid], 'Alert', 'Something', 'rf-dm', now());
select id as dm_id from public.message where unique_key like 'rf-dm:%' \gset
select public.report_message_result(:'dm_id', false, null, 'Discord 403: 50007', true);
select is((select count(*)::int from public.message where unique_key like 'rf-dm:%:fallback%' and channel = 'Email'), 1,
  'DIS-10 a team member whose direct message failed gets the same message by email');
select ok((select detail like '% gets it by email instead.%' from public.attention_item where dedupe_key = 'msgfail:' || :'dm_id'),
  'DIS-10 the task says what really reached them');

-- DIS-1: alerts with nowhere to post do not create failing posts.
update public.domain set alert_discord_channel_id = null, version = version where id = :'dom';
update public.app_config set admin_discord_channel_id = null where id = 1;
select private.queue_team_message('T4', :'dom', 'alert', null, array[:'ops'::uuid], 'Alert', 'Nowhere', 'rf-noalert', now());
select ok(not exists (select 1 from public.message where unique_key = 'rf-noalert:Discord')
          and exists (select 1 from public.attention_item where dedupe_key = 'noalert:' || :'dom'),
  'DIS-1 without an alert channel nothing is posted; one task asks to choose a channel');

-- DIS-13: a message stuck in Sending after its third try is not sent again.
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, claimed_at, attempts, body_text, to_address)
values (:'dom', 'Team', 'T4', 'Email', 'rf-stuck', 'Sending', now() - interval '20 minutes', 3, 'x', 'a@example.com');
select public.claim_outbound_messages(1);
select is((select status from public.message where unique_key = 'rf-stuck'), 'Failed', 'DIS-13 a message stuck after three tries is marked failed, not sent again');

-- DIS-5: a help reply always goes out (channel or direct message, plus email).
update public.instructor set discord_user_id = null, version = version where id = :'i3';
insert into public.help_request (domain_id, module_week_id, requester_instructor_id, source, categories, details, urgency, reply_channel, status, raised_at, response_target_at)
values (:'dom', :'mw', :'i3', 'Instructor', array['other'], 'Help', 'NoRush', 'Discord', 'Open', now(), now() + interval '1 day') returning id as hid \gset
select public.help_reply(:'hid', 'Here you go', false);
select is((select string_agg(channel, ',') from public.message where help_request_id = :'hid' and template_id = 'M14'), 'Email',
  'DIS-5 a reply to someone who chose Discord but has none still goes by email');

-- ============================================================ Outreach, answers and reminders
-- OUT-2: an ask that has not gone out is withdrawn when the request closes, and so is "no longer needed".
select tests.scenario('RG', 'Live', '2027-01-31', 2) as k \gset
select (:'k'::jsonb ->> 'domain') as dom2, (:'k'::jsonb ->> 'mw') as mw2, (:'k'::jsonb ->> 'i1') as g1, (:'k'::jsonb ->> 'i2') as g2 \gset
select tests.tick(:'dom2', '2027-01-01 18:00+00');
update public.message set status = 'Scheduled' where module_week_id = :'mw2' and template_id = 'M1';
select public.assign_manually(:'mw2', :'g2');
select public.claim_outbound_messages(100);
select is((select count(*)::int from public.message where module_week_id = :'mw2' and template_id = 'M1' and status <> 'Cancelled'), 0,
  'OUT-2 a request that never went out is withdrawn when someone else is assigned');
select is((select count(*)::int from public.message where module_week_id = :'mw2' and template_id = 'M12' and instructor_id = :'g1' and status <> 'Cancelled'), 0,
  'OUT-2 and the instructor is not told "no longer needed" about a request they never saw');

-- OUT-3: a replacement after "release without asking again" gets reminders.
select public.release_booking(:'mw2', 'Test', false);
select public.assign_manually(:'mw2', :'g1');
select is((select paused from public.module_week where id = :'mw2'), false, 'OUT-3 a confirmed week is not left paused');

-- OUT-4: quiet hours of a cohort apply to its classes.
select cohort_id as coh from public.module_week where id = :'mw2' \gset
insert into public.setting (scope, cohort_id, key, value) values ('Cohort', :'coh', 'instructor_quiet_start', '"22:00"'), ('Cohort', :'coh', 'instructor_quiet_end', '"10:00"');
select ok(private.instructor_send_time(:'mw2', '2027-01-05 17:30+00', false, 'US') >= '2027-01-05 18:00+00',
  'OUT-4 a cohort''s quiet hours (until 10 AM) hold a 9:30 AM message');

-- OUT-5: weekly reminders stop when reminders are set to 0.
insert into public.setting (scope, domain_id, key, value) values ('Domain', :'dom2', 'reminder_r2_normal_h', '0')
on conflict do nothing;
update public.setting set value = '0' where scope = 'Domain' and domain_id = :'dom2' and key = 'reminder_r2_normal_h';
insert into public.attention_item (domain_id, type, severity, title, dedupe_key, recipients, opened_at, r1_at, last_reminder_at)
values (:'dom2', 'ThinBench', 'Normal', 'Thin', 'rf-thin', array[:'ops'::uuid], now() - interval '20 days', now() - interval '20 days', now() - interval '8 days');
select private.step_reminders(:'dom2', now());
select is((select count(*)::int from public.message where attention_item_id = (select id from public.attention_item where dedupe_key = 'rf-thin')), 0,
  'OUT-5 weekly reminders are switched off with the other reminders');

-- OUT-6: a class week that is over without an instructor is closed, and its tasks too.
select tests.scenario('RH', 'Live', '2027-01-31', 1) as h \gset
select (:'h'::jsonb ->> 'domain') as dom3, (:'h'::jsonb ->> 'mw') as mw3 \gset
select private.raise_attention(:'dom3', 'RankingExhausted', 'Urgent', 'Nobody', null, 'rf-ex', array[:'ops'::uuid], '2027-01-30 00:00+00', jsonb_build_object('module_week_id', :'mw3'));
select private.step_complete(:'dom3', '2027-02-10 00:00+00');
select is((select status from public.module_week where id = :'mw3'), 'Completed', 'OUT-6 a week that is over is closed even without an instructor');
select is((select status from public.attention_item where dedupe_key = 'rf-ex'), 'Done', 'OUT-6 and its urgent task stops');

-- OUT-7: a merged help request that becomes urgent is upgraded.
select (private.create_help_request(:'mw', :'i1', null, 'Instructor', array['other'], 'Small thing', 'NoRush', 'Either', '2027-01-10 00:00+00') ->> 'id') as h1 \gset
select private.create_help_request(:'mw', :'i1', null, 'Instructor', array['other'], 'Zoom broken', 'Urgent', 'Either', '2027-01-10 00:30+00');
select is((select severity from public.help_request where id = :'h1'), 'Urgent', 'OUT-7 the merged request becomes urgent');
select ok((select response_target_at <= '2027-01-10 06:30+00' from public.help_request where id = :'h1'), 'OUT-7 with an urgent reply target');

-- OUT-8: cancelling a class week closes its help requests.
select public.cancel_module_week(:'mw', 'Not needed');
select is((select status from public.help_request where id = :'h1'), 'Closed', 'OUT-8 help requests of a cancelled class week are closed');

-- OUT-9: escalations of normal tasks wait for team quiet hours.
select is(private.team_send_time(:'dom2', '2027-01-05 18:00+00') > '2027-01-05 18:00+00', true,
  'OUT-9 (check) 11:30 PM India time is inside team quiet hours');

-- ============================================================ Scheduling and time zones
select tests.scenario('RS', 'Live', '2027-02-14', 2) as s \gset
select (:'s'::jsonb ->> 'domain') as sdom, (:'s'::jsonb ->> 'module') as smod, (:'s'::jsonb ->> 'mw') as smw, (:'s'::jsonb ->> 'i1') as s1 \gset
-- SCH-1: classes of one week never overlap.
select throws_like($$ select public.add_one_class('$$ || :'smw' || $$'::uuid, null, null, '2027-02-14', '10:00', '11:00', 'Office hours', null, true) $$,
  '%overlaps another class of the same class week%', 'SCH-1 adding a class on top of another class of the same week is refused');
select throws_like($$ select public.change_class_time((select id from public.class_session where module_week_id = '$$ || :'smw' || $$' and class_type = 'Assignment review'), '2027-02-14', '10:00', '12:00') $$,
  '%overlaps another class of the same class week%', 'SCH-1 moving a class on top of another class of the same week is refused');
-- SCH-3: start equal to end is refused; warnings are shown.
select throws_like($$ select public.change_class_time((select id from public.class_session where module_week_id = '$$ || :'smw' || $$' and class_type = 'Assignment review'), '2027-02-18', '18:00', '18:00') $$,
  '%must end after it starts%', 'SCH-3 a class time with the same start and end is refused');
select is((public.change_class_time((select id from public.class_session where module_week_id = :'smw' and class_type = 'Assignment review'), '2027-02-18', '04:00', '05:00') ->> 'needs_confirmation')::boolean, true,
  'SCH-3 a time outside 6 AM to 10 PM asks for confirmation first');
-- SCH-2: a class added to a booked week is part of the booking straight away.
select public.assign_manually(:'smw', :'s1');
select public.add_one_class(:'smw', null, null, '2027-02-16', '18:00', '19:00', 'Office hours', null, true);
select is((select count(*)::int from public.booking_slot s join public.booking b on b.id = s.booking_id
            where b.module_week_id = :'smw' and b.status = 'Active' and s.active),
          (select count(*)::int from public.class_session where module_week_id = :'smw' and status = 'Planned'),
  'SCH-2 every class of a booked week holds a slot for the instructor');
-- SCH-4: moving dates onto another class of the instructor is refused, naming the clash.
select tests.make_module(:'sdom', 'RS Other') as smod2 \gset
select tests.rank(:'smod2', :'s1');
select tests.make_week(:'smod2', '2027-02-21') as smw2 \gset
select public.assign_manually(:'smw2', :'s1');
select throws_like($$ select public.shift_classes('$$ || :'smw' || $$'::uuid, 1, false) $$, '%cannot teach%at the new dates%',
  'SCH-4 moving dates onto the instructor''s other class is refused instead of releasing them');
-- SCH-6: the help page answers in the class's time zone.
select ok(private.fmt_local('2027-02-14 03:30+00', 'India') like '%IST%', 'SCH-6 (check) India times are labelled IST');

-- ============================================================ Security and access
-- SEC-2: a removed person stays removed.
select tests.make_team_member('RF Removed', 'Ops') as gone \gset
update public.team_member set access_removed_at = now(), active = false where id = :'gone';
select throws_like($$ update public.team_member set email = 'new.address@example.com' where id = '$$ || :'gone' || $$' $$,
  '%cannot be changed%', 'SEC-2 the email of someone whose access was removed cannot be changed');
select throws_like($$ delete from public.team_member where id = '$$ || :'gone' || $$' $$,
  '%stay on the Team page%', 'SEC-2 and they cannot be deleted to get round it');

-- SEC-3: the team never sees an answer link's secret; the automation gets it when sending.
select ok(not exists (select 1 from public.message m join public.response_link l on position(l.token in coalesce(m.body_text, '') || coalesce(m.body_html, '') || coalesce(m.buttons::text, '')) > 0),
  'SEC-3 no answer link secret is stored in any message');
-- The automation receiving the real links is checked strictly in 210 (TST-4).

-- SEC-4: the link addresses cannot be changed from the app.
select throws_like($$ select public.set_app_config(jsonb_build_object('response_base_url', 'https://elsewhere.example/x', 'version', (select version from public.app_config where id = 1))) $$,
  '%set when the app is set up%', 'SEC-4 the answer link address cannot be changed from the app');

-- SEC-5: a message with both a channel and a direct message is never sent.
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, discord_channel_id, discord_dm_user_id, body_text)
values (:'dom', 'Team', 'T4', 'Discord', 'rf-both', 'Pending', '920000000000000002', '555555555555555555', 'x') returning status as both_status \gset
select is(:'both_status'::text, 'Cancelled', 'SEC-5 a Discord message with both a channel and a person is blocked');

-- SEC-6: a database that was never configured cannot be reset.
update public.app_config set environment = 'Sandbox', environment_set_at = null where id = 1;
select throws_like($$ select public.reset_sandbox_data('RESET') $$, '%never set up%', 'SEC-6 data cannot be reset on a database that was never configured');
select is((select column_default from information_schema.columns where table_schema = 'public' and table_name = 'app_config' and column_name = 'environment'),
  '''Sandbox''::text', 'SEC-6 a new database starts as Sandbox (Google sign in only), not Development');

select * from finish();
rollback;
