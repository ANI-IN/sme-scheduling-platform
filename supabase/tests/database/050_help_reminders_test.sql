-- M2 scenarios (PRD 20.3): Need Help (routing, acknowledgement, half-time reminder, escalation,
-- reply, follow-up, merge, convert to cancellation), checklist nudge + escalation, schedule running
-- low, email bounce, Discord failure, typed replies, digests, heartbeat.
begin;
\ir ../helpers/helpers.psql
select plan(40);

-- =============================================================== Need Help
select tests.scenario('HP', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'owner') as owner, (:'j'::jsonb ->> 'ops') as ops \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.at('2027-01-21 18:00+00');
select (public.submit_help_request(tests.token(:'mw', :'i1', 'NeedHelp'), array['materials'], 'Need last run''s slides', 'NoRush', 'Either')) as h \gset
select is(:'h'::jsonb ->> 'result', 'help_created', 'help request created from the confirmation''s Need help button');
select (:'h'::jsonb ->> 'help_request_id') as hid \gset
select is((select routed_to from public.help_request where id = :'hid'), array[:'owner']::uuid[], 'class materials → routed to the module owner');
select is((select response_target_at from public.help_request where id = :'hid'), '2027-01-22 18:00+00'::timestamptz,
  'no rush and class > 7 days away → 24h target');
select is((select count(*)::int from public.message where help_request_id = :'hid' and template_id = 'M13'), 2, 'instructor gets the acknowledgement (M13)');
select is((select count(*)::int from public.message where help_request_id = :'hid' and template_id = 'T7' and unique_key not like '%:copy'), 1, 'owner tagged right away (T7)');
select ok(:'h'::jsonb ->> 'message' = 'Concurrency HP Owner will reply by Fri, Jan 22 · 10:00 AM PST.', 'confirmation shows who replies and by when (PT)');

-- duplicate within 1 hour merges
select tests.at('2027-01-21 18:30+00');
select is((public.submit_help_request(tests.token(:'mw', :'i1', 'NeedHelp'), array['zoom'], 'Also the Zoom link', 'NoRush', 'Either')) ->> 'help_request_id',
  :'hid', 'a second request within 1 hour merges into the first');
select is((select categories from public.help_request where id = :'hid'), array['materials', 'zoom'], 'categories merged');

select tests.tick(:'dom', '2027-01-22 06:00+00');
select is((select count(*)::int from public.message where help_request_id = :'hid' and template_id = 'REM'), 1, 'reminder to the assignee at half the target time');
select tests.tick(:'dom', '2027-01-22 18:00+00');
select is((select count(*)::int from public.message where help_request_id = :'hid' and template_id = 'T13' and unique_key not like '%:copy'), 1, 'escalation to the alert channel when the target passes');

select public.help_reply(:'hid', 'Slides are in the Drive folder.', false);
select is((select status from public.help_request where id = :'hid'), 'WaitingOnInstructor', 'reply → waiting on instructor');
select is((select count(*)::int from public.message where help_request_id = :'hid' and template_id = 'M14'), 2, 'reply sent to the instructor (M14)');
select ok((select first_response_at from public.help_request where id = :'hid') is not null, 'first response recorded');

select public.record_inbound_message('Email', 'HP Instr1 <hp.instr1@example.org>', 'Re: help', 'Thanks, but the link is broken', 'gmail-hp-1');
select is((select status from public.help_request where id = :'hid'), 'Open', 'an instructor follow-up re-opens the help request');
select is((select count(*)::int from public.message where help_request_id = :'hid' and direction = 'Inbound'), 1, 'follow-up attached to it');
select is((public.record_inbound_message('Email', 'hp.instr1@example.org', 'Re: help', 'dup', 'gmail-hp-1')) ->> 'duplicate', 'true',
  'reading the same email twice does nothing');

select public.help_convert_to_cancellation(:'hid');
select is((select status from public.help_request where id = :'hid'), 'ConvertedToCancellation', 'convert to cancellation');
select is(tests.booked(:'mw'), null, 'starts the cancellation flow (booking released)');
select is(tests.asking(:'mw'), 'HP Instr2', 'and outreach restarts');

-- routing: zoom → ops; urgent near class
select tests.scenario('HZ', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'ops') as ops \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.at('2027-01-30 06:00+00');
select (public.submit_help_request(tests.token(:'mw', :'i1', 'NeedHelp'), array['zoom'], null, 'NoRush', 'Discord') ->> 'help_request_id') as hz \gset
select is((select routed_to from public.help_request where id = :'hz'), array[:'ops']::uuid[], 'Zoom / calendar → routed to ops');
select is((select severity || ' ' || (response_target_at - raised_at)::text from public.help_request where id = :'hz'), 'Urgent 02:00:00',
  'class less than 2 days away → 2h target, urgent from the start');
select tests.tick(:'dom', '2027-01-30 06:00+00');
select is((select at_risk_reason from public.module_week where id = :'mw'), 'Help pending', 'help still open 2 days before → At risk (help pending)');
select public.help_set_status(:'hz', 'Resolved', 'Sent the link by phone');
select is((select status from public.attention_item where dedupe_key = 'help:' || :'hz'), 'Done', 'resolving the help request closes its attention item');

-- =============================================================== checklist
select tests.scenario('CL', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-03 18:00+00');
select is((select count(*)::int from public.attention_item where dedupe_key = 'checklist:' || :'mw'), 0, 'no checklist nudge before 3 days');
select tests.tick(:'dom', '2027-01-04 19:00+00');
select is((select severity from public.attention_item where dedupe_key = 'checklist:' || :'mw'), 'Normal', 'checklist nudge 3 days after confirmation');
select tests.tick(:'dom', '2027-01-24 18:00+00');
select is((select severity from public.attention_item where dedupe_key = 'checklist:' || :'mw'), 'Urgent', 'not done 7 days before → urgent');
select is(tests.msgs(:'mw', 'T13'), 1, 'and escalated');
select public.set_checklist_item(ci.id, true) from public.checklist_item ci join public.class_session c on c.id = ci.class_id where c.module_week_id = :'mw';
select tests.tick(:'dom', '2027-01-24 19:00+00');
select is((select status from public.attention_item where dedupe_key = 'checklist:' || :'mw'), 'Done', 'all items done → resolved automatically');

-- schedule running low
select is(tests.open_items(:'dom', 'ScheduleLow'), 1, 'schedule running low (< 6 weeks planned ahead) → attention item');

-- =============================================================== failures
select tests.scenario('FL', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
-- SEC 9 (decision 311): a real bounce is in the Gmail thread of an email the app sent to that address.
update public.message set status = 'Sent', sent_at = now(), external_id = 'fl-thread-1'
 where id = (select id from public.message where module_week_id = :'mw' and channel = 'Email' and lower(to_address) = 'fl.instr1@example.org'
              order by created_at limit 1);
select public.record_bounce('fl.instr1@example.org', 'bounce-1', 'Mailbox not found', 'fl-thread-1', true);
select is(tests.open_items(:'dom', 'MessageFailed'), 1, 'email bounce → attention item');
select ok((select email_bounced_at from public.instructor where id = :'i1') is not null, 'instructor flagged until fixed');
create temp table d as select id from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Discord';
select public.report_message_result((select id from d), false, null, 'Missing Access');
select public.report_message_result((select id from d), false, null, 'Missing Access');
update public.message set attempts = 3 where id = (select id from d);
select is((public.report_message_result((select id from d), false, null, 'Missing Access')) ->> 'status', 'Failed', 'after retries the message is marked Failed');
select ok((select discord_failed_at from public.instructor where id = :'i1') is not null, 'Discord failure flagged on the instructor');
select is((select count(*)::int from public.attention_item where dedupe_key = 'msgfail:' || (select id from d)), 1, 'failure becomes an attention item');

-- typed reply
select public.record_inbound_message('Discord', (select discord_user_id from public.instructor where id = :'i1'), null, 'Can I start at 10 instead?', 'disc-1');
select is((select count(*)::int from public.attention_item where type = 'TypedReply' and module_week_id = :'mw'), 1, 'typed reply → attention item');
select is(tests.asking(:'mw'), 'FL Instr1', 'nothing changes automatically');

-- =============================================================== digests and heartbeat
select public.engine_tick_all('2027-01-05 05:30+00');   -- 11:00 AM IST
select ok((select count(*)::int from public.message where template_id = 'T12') > 0, 'daily digest sent to team members with open items');
select is((select count(*)::int from public.attention_item where status <> 'Done' and r1_at is null), 0, 'digest is the first reminder (R1) for normal items');
select public.engine_tick_all('2027-01-05 06:30+00');
select is((select count(*)::int from public.message where template_id = 'T12'),
          (select count(distinct team_member_id)::int from public.message where template_id = 'T12'), 'only one digest per person per day');
update public.app_config set admin_discord_channel_id = tests.rand_discord() where id = 1;
select public.daily_jobs('2027-01-05 05:30+00');
select is((select count(*)::int from public.message where template_id = 'T15'), 1, 'daily heartbeat (T15) to the admin channel');

select * from finish();
rollback;
