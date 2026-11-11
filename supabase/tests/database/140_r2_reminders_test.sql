-- Release 2: every reminder can be switched off or set to 0, per domain with an optional cohort
-- override, and turning reminders off never stops the main automation.
-- Each scenario has its own domain. Class week: live class Sun Jan 31 2027, 9:00 AM PST.
-- Outreach starts Jan 1 (30 days), the reminder is due after 24 hours, moving on after 48 hours.
begin;
\ir ../helpers/helpers.psql
select plan(30);

create or replace function tests.set(p_dom uuid, p_key text, p_value text) returns void language sql as $$
  select public.set_setting_at('Domain', p_dom, p_key, p_value::jsonb);
$$;
create or replace function tests.sc(p_name text) returns jsonb language sql as $$ select tests.scenario(p_name, 'Live', '2027-01-31', 3); $$;

-- =============================================================== 1. waiting for an answer: default
select tests.sc('RA') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select isnt((select reminder_at from public.request where module_week_id = :'mw' and status = 'Sent'), null, '1. by default a reminder is planned while we wait');
select tests.tick(:'dom', '2027-01-02 18:00+00');
select is(tests.msgs(:'mw', 'M2'), 2, '1. and sent after 24 hours on Discord and email');

-- =============================================================== 2. switched off
select tests.sc('RB') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.set(:'dom', 'answer_reminders', 'false');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is((select reminder_at from public.request where module_week_id = :'mw' and status = 'Sent'), null, '2. off: no reminder is planned');
select tests.tick(:'dom', '2027-01-02 18:00+00');
select is(tests.msgs(:'mw', 'M2'), 0, '2. and none is sent');
select tests.tick(:'dom', '2027-01-03 18:00+00');
select is(tests.asking(:'mw'), 'RB Instr2', '2. the next instructor is still asked after 48 hours');

-- =============================================================== 3. set to 0
select tests.sc('RC') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.set(:'dom', 'window_long_reminder_h', '0');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is((select reminder_at from public.request where module_week_id = :'mw' and status = 'Sent'), null, '3. 0 hours means no reminder');
select tests.tick(:'dom', '2027-01-03 18:00+00');
select is(tests.asking(:'mw'), 'RC Instr2', '3. moving on is not affected');

-- =============================================================== 4. cohort override
select tests.sc('RD') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
insert into public.cohort (domain_id, name) values (:'dom', 'RD Weekend') returning id as coh \gset
update public.module_week set cohort_id = :'coh' where id = :'mw';
select tests.set(:'dom', 'answer_reminders', 'false');
select public.set_setting_at('Cohort', :'coh', 'answer_reminders', 'true');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select isnt((select reminder_at from public.request where module_week_id = :'mw' and status = 'Sent'), null,
  '4. a cohort can switch a reminder back on for its own classes');

-- =============================================================== 5. switched off part way
select tests.sc('RE') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.set(:'dom', 'answer_reminders', 'false');
select tests.tick(:'dom', '2027-01-02 18:00+00');
select is(tests.msgs(:'mw', 'M2'), 0, '5. switching off part way stops a reminder that was already planned');
select tests.tick(:'dom', '2027-01-03 18:00+00');
select is(tests.asking(:'mw'), 'RE Instr2', '5. and the next instructor is still asked');

-- =============================================================== 6. reminders before class: default
select tests.sc('RF') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-21 18:00+00');
select is(tests.msgs(:'mw', 'M6'), 2, '6. by default the instructor is reminded 10 days before');

-- =============================================================== 7. "Remind the instructor after they are assigned" off
select tests.sc('RG') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.set(:'dom', 'remind_instructor_after_assign', 'false');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select is(tests.booked(:'mw'), 'RG Instr1', '7. confirming still works');
select tests.tick(:'dom', '2027-01-21 18:00+00');
select tests.tick(:'dom', '2027-01-29 18:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'CheckIn'), 0,
  '7. off: no reminders before class');

-- =============================================================== 8. reminders before class: empty list, and one day only
select tests.sc('RH') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.set(:'dom', 'checkin_days', '[]');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-21 18:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'CheckIn'), 0, '8. an empty list means no reminders before class');
select tests.set(:'dom', 'checkin_days', '[2]');
select tests.tick(:'dom', '2027-01-29 18:00+00');
select is((select array_agg(check_in_days)::text from public.request where module_week_id = :'mw' and kind = 'CheckIn'), '{2}',
  '8. a list with only 2 sends only the last reminder');

-- =============================================================== 9. module owners: default, then 0
select tests.sc('RI') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-17 18:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'OwnerCheckIn'), 1, '9. by default the owners are asked 14 days before');
select tests.sc('RJ') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.set(:'dom', 'owner_checkin_days', '0');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-17 18:00+00');
select tests.tick(:'dom', '2027-01-25 18:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'OwnerCheckIn'), 0, '9. 0 days means the owners are not asked');

-- =============================================================== 10. "Remind the team after an instructor is assigned" off
select tests.sc('RK') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.set(:'dom', 'remind_team_after_assign', 'false');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-05 18:00+00');
select tests.tick(:'dom', '2027-01-17 18:00+00');
select tests.tick(:'dom', '2027-01-25 18:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'OwnerCheckIn'), 0, '10. off: owners are not asked');
select is(tests.open_items(:'dom', 'ChecklistOverdue'), 0, '10. off: no class task reminders');
select ok(exists (select 1 from public.checklist_item ci join public.class_session c on c.id = ci.class_id where c.module_week_id = :'mw'),
  '10. the class tasks themselves are still there');

-- =============================================================== 11. class task reminder: default, then 0
select tests.sc('RL') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-05 18:00+00');
select is(tests.open_items(:'dom', 'ChecklistOverdue'), 1, '11. by default the operations team is reminded about class tasks after 3 days');
select tests.sc('RM') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.set(:'dom', 'checklist_nudge_days', '0');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-05 18:00+00');
select is(tests.open_items(:'dom', 'ChecklistOverdue'), 0, '11. 0 days means no class task reminder');

-- =============================================================== 12. repeat reminders and escalation for open tasks set to 0
select tests.sc('RN') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.set(:'dom', 'reminder_r2_normal_h', '0');
select tests.set(:'dom', 'reminder_escalate_normal_h', '0');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-05 18:00+00');
update public.attention_item set r1_at = '2027-01-05 18:00+00', last_reminder_at = '2027-01-05 18:00+00' where domain_id = :'dom';
select tests.tick(:'dom', '2027-01-08 18:00+00');
select is((select count(*)::int from public.reminder r join public.attention_item a on a.id = r.attention_item_id
            where a.domain_id = :'dom' and r.level = 'R2'), 0, '12. 0 hours: no repeat reminder about an open task');
select is((select count(*)::int from public.attention_item where domain_id = :'dom' and escalated_at is not null), 0,
  '12. 0 hours: no escalation');

-- =============================================================== 13. daily summary off
select tests.sc('RO') as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'ops') as ops \gset
select tests.set(:'dom', 'daily_summary', 'false');
update public.team_member set receives_digest = true where id = :'ops';
select private.raise_attention(:'dom', 'ScheduleLow', 'Normal', 'RO test task', null, 'ro-task', array[:'ops']::uuid[], '2027-01-04 18:00+00');
update public.system_state set last_digest_date = null where id = 1;
select private.send_digests('2027-01-05 05:30+00');
select is((select count(*)::int from public.message where template_id = 'T12' and team_member_id = :'ops'), 0,
  '13. daily summary off: no summary for tasks of that domain');
select tests.set(:'dom', 'daily_summary', 'true');
update public.system_state set last_digest_date = null where id = 1;
select private.send_digests('2027-01-06 05:30+00');
select is((select count(*)::int from public.message where template_id = 'T12' and team_member_id = :'ops'), 1,
  '13. switched back on: the summary is sent');

-- =============================================================== 14. everything off: the main automation still runs
select tests.scenario('RP', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
select tests.set(:'dom', k, v) from (values ('answer_reminders', 'false'), ('remind_instructor_after_assign', 'false'),
  ('remind_team_after_assign', 'false'), ('daily_summary', 'false'), ('reminder_r2_normal_h', '0'), ('reminder_r2_urgent_h', '0'),
  ('reminder_escalate_normal_h', '0'), ('reminder_escalate_urgent_h', '0'), ('owner_checkin_days', '0'), ('checklist_nudge_days', '0')) x(k, v);
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is(tests.asking(:'mw'), 'RP Instr1', '14. with every reminder off, instructors are still asked in order');
select tests.click(:'mw', :'i1', 'No');
select tests.click(:'mw', :'i2', 'No');
select is(tests.mw_status(:'mw'), 'NeedsInstructor', '14. nobody left to ask is still detected');
select is((select severity from public.attention_item where dedupe_key = 'exhausted:' || :'mw'), 'Urgent', '14. and the urgent alert is still raised');
select is(tests.msgs(:'mw', 'T4'), 1, '14. and the team is still told at once');

select * from finish();
rollback;
