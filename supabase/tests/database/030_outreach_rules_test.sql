-- M2 scenarios (PRD 20.3) continued: exhausted ranking + escalation, manual selection (Stop /
-- Continue), switching mode with a request open, skip, cross-domain clash, unavailability,
-- deactivation, ranking change mid-outreach + undo, quiet hours, kill switch, test mode,
-- readiness failure and escalation.
begin;
\ir ../helpers/helpers.psql
-- These checks are about quiet hours, which are off unless an admin turns them on (decision 332): on here.
update public.setting_definition set default_value = 'true' where key = 'instructor_quiet_hours_on';
select plan(57);

-- =============================================================== everyone declines → Needs instructor
select tests.scenario('EX', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'No');
select tests.click(:'mw', :'i2', 'No');
select is(tests.mw_status(:'mw'), 'NeedsInstructor', 'everyone declines → Needs instructor');
select is((select severity from public.attention_item where dedupe_key = 'exhausted:' || :'mw'), 'Urgent', 'urgent attention item (ranking exhausted)');
select is(tests.msgs(:'mw', 'T4'), 1, 'T4 posted immediately in the alert channel, tagging owner + ops');
select ok((select mention_user_ids from public.message where module_week_id = :'mw' and template_id = 'T4' and team_member_id is null) @>
          (select array_agg(discord_user_id) from public.team_member where id in ((:'j'::jsonb ->> 'owner')::uuid, (:'j'::jsonb ->> 'ops')::uuid)),
  'T4 tags the module owner and ops contact');
select tests.tick(:'dom', '2027-01-01 23:00+00');
select is((select count(*)::int from public.message where template_id = 'REM' and attention_item_id = (select id from public.attention_item where dedupe_key = 'exhausted:' || :'mw')),
  2, 'urgent items repeat every 4h until acknowledged (to owner + ops)');
select tests.tick(:'dom', '2027-01-02 03:00+00');
select is(tests.msgs(:'mw', 'T13'), 1, 'escalation after 8h, posted in the alert channel');
select public.attention_ack((select id from public.attention_item where dedupe_key = 'exhausted:' || :'mw'));
select tests.tick(:'dom', '2027-01-02 09:00+00');
select is((select count(*)::int from public.message where template_id = 'REM' and attention_item_id = (select id from public.attention_item where dedupe_key = 'exhausted:' || :'mw')),
  4, 'I''m on it pauses repeats');
-- manual assignment resolves it
select is((public.assign_manually(:'mw', :'i1', 'Phoned them')) ->> 'ok', 'true', 'assign manually works with the same booking function');
select is((select status from public.attention_item where dedupe_key = 'exhausted:' || :'mw'), 'Done', 'reminders stop when resolved');

-- =============================================================== manual selection: custom order, Stop
select tests.scenario('MS', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select public.set_outreach_queue(:'mw', 'Manual', array[:'i3', :'i2']::uuid[], 'Stop', null, true);
select is(tests.asking(:'mw'), 'MS Instr3', 'manual mode asks the first ticked instructor (custom order)');
select tests.click(:'mw', :'i3', 'No');
select is(tests.asking(:'mw'), 'MS Instr2', 'then the next ticked instructor, one at a time');
select tests.click(:'mw', :'i2', 'No');
select is(tests.mw_status(:'mw'), 'NeedsInstructor', 'end of manual list with "Stop" → stop and alert');
select is(tests.asking(:'mw'), null, 'the ranking is not used');

-- manual selection: Continue with ranking
select tests.scenario('MC', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select public.set_outreach_queue(:'mw', 'Manual', array[:'i3']::uuid[], 'ContinueWithRanking', null, true);
select tests.click(:'mw', :'i3', 'No');
select is(tests.asking(:'mw'), 'MC Instr1', 'end of manual list with "Continue" → continues with the ranking');

-- =============================================================== switching mode with a request open
select tests.scenario('SW', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is((public.set_outreach_queue(:'mw', 'Manual', array[:'i3']::uuid[], 'Stop', null, true)) ->> 'needs_decision', 'true',
  'switching mode with a request open asks "keep waiting or withdraw?"');
select public.set_outreach_queue(:'mw', 'Manual', array[:'i3']::uuid[], 'Stop', 'keep', true);
select is(tests.asking(:'mw'), 'SW Instr1', 'keep: the open request stays');
select public.set_outreach_queue(:'mw', 'Manual', array[:'i3']::uuid[], 'Stop', 'withdraw', true);
select is(tests.asking(:'mw'), 'SW Instr3', 'withdraw: the open request is withdrawn and the manual list starts');
select is(tests.msgs(:'mw', 'M12'), 2, 'the withdrawn instructor is told politely (M12)');
select is((select count(*)::int from public.request where module_week_id = :'mw' and status in ('Sent', 'Reminded')), 1, 'still only one open request');

-- skip to next
select public.set_outreach_queue(:'mw', 'Sequential', null, null, 'keep');
select public.skip_to_next(:'mw');
select is(tests.asking(:'mw'), 'SW Instr2', 'skip to next asks the next in line (skipped instructors are not re-asked)');

-- =============================================================== cross-domain clash
select tests.scenario('XA', 'Live', '2027-01-31', 2) as ja \gset
select tests.scenario('XB', 'Live', '2027-01-31', 1) as jb \gset
-- XB's only instructor is also XA's primary; XB books them first.
select tests.rank((:'ja'::jsonb ->> 'module')::uuid, (:'jb'::jsonb ->> 'i1')::uuid, (:'ja'::jsonb ->> 'i1')::uuid);
select public.assign_manually((:'jb'::jsonb ->> 'mw')::uuid, (:'jb'::jsonb ->> 'i1')::uuid);
select tests.tick((:'ja'::jsonb ->> 'domain')::uuid, '2027-01-01 18:00+00');
select is(tests.asking((:'ja'::jsonb ->> 'mw')::uuid), 'XA Instr1', 'an instructor teaching in another domain at that time is skipped');
select ok((select note from public.history_event where module_week_id = (:'ja'::jsonb ->> 'mw')::uuid and action like 'Asked%' limit 1)
          like '%XB Instr1%Teaching %XB) on %the same time as this class%', 'skip reason logged ("Teaching <domain> at this time")');

-- clash appearing after the request was sent: Yes is refused politely, next instructor asked
select tests.scenario('YA', 'Live', '2027-01-31', 2) as ja \gset
select tests.scenario('YB', 'Live', '2027-01-31', 1) as jb \gset
select tests.tick((:'ja'::jsonb ->> 'domain')::uuid, '2027-01-01 18:00+00');
select tests.rank((:'jb'::jsonb ->> 'module')::uuid, (:'ja'::jsonb ->> 'i1')::uuid);
select public.assign_manually((:'jb'::jsonb ->> 'mw')::uuid, (:'ja'::jsonb ->> 'i1')::uuid);
select is((public.record_response(tests.token((:'ja'::jsonb ->> 'mw')::uuid, (:'ja'::jsonb ->> 'i1')::uuid, 'Yes'))) ->> 'result',
  'not_booked', 'Yes that now clashes with another domain is not booked');
select ok((public.record_response(tests.token((:'ja'::jsonb ->> 'mw')::uuid, (:'ja'::jsonb ->> 'i1')::uuid, 'Yes'))) ->> 'message' is not null,
  'the instructor sees an explanation');
select is(tests.asking((:'ja'::jsonb ->> 'mw')::uuid), 'YA Instr2', 'the next instructor is asked');
select is((select count(*)::int from public.attention_item where module_week_id = (:'ja'::jsonb ->> 'mw')::uuid and type = 'Other'), 1, 'ops notified');

-- =============================================================== unavailability and deactivation
select tests.scenario('UA', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
insert into public.instructor_unavailability (instructor_id, from_date, to_date, reason) values (:'i1', '2027-01-25', '2027-02-10', 'Travel');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is(tests.asking(:'mw'), 'UA Instr2', 'unavailable instructor is skipped for module weeks in that range');
select ok((public.preview_next(:'mw')) -> 'line' -> 0 ->> 'reason' like 'Unavailable Jan 25 to Feb 10', 'preview shows the reason');
-- deactivate the instructor being asked: request withdrawn, next asked
select public.deactivate_instructor(:'i2');
select is(tests.asking(:'mw'), 'UA Instr3', 'deactivating the instructor being asked withdraws the request and asks the next');
select tests.click(:'mw', :'i3', 'Yes');
select is((public.deactivate_instructor(:'i3')) ->> 'needs_decision', 'true', 'deactivating someone with bookings asks keep or release');
select public.deactivate_instructor(:'i3', jsonb_build_object((select id from public.booking where module_week_id = :'mw' and status = 'Active')::text, 'keep'));
select is(tests.booked(:'mw'), 'UA Instr3', 'keep: the booking stays');
update public.instructor set status = 'Active' where id = :'i3';
select public.deactivate_instructor(:'i3', jsonb_build_object((select id from public.booking where module_week_id = :'mw' and status = 'Active')::text, 'release'));
select is(tests.booked(:'mw'), null, 'release: the booking is released');
select is((select at_risk from public.module_week where id = :'mw'), true, 'module week marked At risk');

-- =============================================================== ranking change mid-outreach + undo
select tests.scenario('RK', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'module') as mod,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is((public.ranking_impact(:'mod', array[:'i1', :'i3', :'i2']::uuid[])) ->> 'affected_weeks', '1', 'impact preview counts upcoming unconfirmed weeks');
select is((public.ranking_impact(:'mod', array[:'i1', :'i3', :'i2']::uuid[])) -> 'weeks' -> 0 ->> 'next_after', 'RK Instr3', 'impact preview shows who would be next');
select is((select count(*)::int from public.module_ranking where module_id = :'mod' and rank = 2 and instructor_id = :'i2'), 1, 'preview did not save anything');
-- A team member saves the order in the app (only their changes can be undone).
select tests.login_member('rk.ops@example.com');
select public.save_ranking(:'mod', array[:'i1', :'i3', :'i2']::uuid[]);
select tests.as_postgres();
select is(tests.asking(:'mw'), 'RK Instr1', 'a ranking change never touches the request already sent');
select is((public.preview_next(:'mw')) ->> 'next', 'RK Instr3', '"who will be asked next" follows the new order');
select tests.click(:'mw', :'i1', 'No');
select is(tests.asking(:'mw'), 'RK Instr3', 'the next person asked follows the new order');
select public.undo_history_event((select id from public.history_event where action = 'Ranking saved' and entity_id = :'mod' order by id desc limit 1));
select is((select array_agg(instructor_id order by rank) from public.module_ranking where module_id = :'mod'), array[:'i1', :'i2', :'i3']::uuid[],
  'undo restores the previous ranking');
select ok(exists (select 1 from public.history_event where action = 'Undo: Ranking saved'), 'undo is logged');
select throws_ok(format('select public.undo_history_event(%s)', (select id from public.history_event where action = 'Ranking saved' and entity_id = :'mod' order by id limit 1)),
  '22023', 'This change was already undone.', 'a change can only be undone once');

-- =============================================================== quiet hours (PRD 9.4)
select tests.scenario('QH', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-02 06:00+00');    -- 10:00 PM PST: inside instructor quiet hours
select is((select status from public.message where module_week_id = :'mw' and template_id = 'M1' limit 1), 'Scheduled', 'messages in quiet hours wait');
select is((select not_before from public.message where module_week_id = :'mw' and template_id = 'M1' limit 1), '2027-01-02 16:00+00'::timestamptz,
  'they are released at 8:00 AM PT');
select is((select count(*)::int from public.claim_outbound_messages(100) where module_week_id = :'mw' and template_id = 'M1'), 0, 'n8n cannot claim them early');
select tests.tick(:'dom', '2027-01-02 16:00+00');
select is((select count(*)::int from public.message where module_week_id = :'mw' and template_id = 'M1' and status = 'Pending'), 2, 'released at 8 AM PT');

-- =============================================================== kill switch (SYS-1)
select tests.scenario('KS', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select public.set_kill_switch(false);
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw'), 0, 'kill switch on: nobody is asked');
select public.set_kill_switch(true);
select tests.tick(:'dom', '2027-01-01 19:00+00');
select is(tests.asking(:'mw'), 'KS Instr1', 'kill switch off: outreach resumes at the next run');

-- =============================================================== test mode routing (TST-1)
select tests.scenario('TM', 'Test', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is((select to_address from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Email'), 'test-inbox@example.com',
  'test mode: email goes to the test inbox');
select is((select discord_channel_id from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Discord'),
  (select test_discord_channel_id from public.domain where id = :'dom'), 'test mode: Discord goes to the test channel');
select ok((select body_text from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Discord') like '[TEST → would go to TM Instr1]%',
  'test mode: message prefixed with the real recipient');
select is((select cardinality(mention_user_ids) from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Discord'), 0,
  'test mode: real instructors are never @mentioned');

-- =============================================================== readiness failure (PRD 9.2, OUT-10)
select tests.scenario('RD', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'module') as mod \gset
delete from public.module_owner where module_id = :'mod';
select tests.tick(:'dom', '2026-12-17 18:00+00');
select is(tests.mw_status(:'mw'), 'NotReady', 'readiness fails without an owner');
select is((select count(*)::int from public.attention_item where dedupe_key = 'readiness:' || :'mw' and recipients @> array[(:'j'::jsonb ->> 'lead')::uuid]), 1,
  'no owner → routed to the domain lead');
select tests.tick(:'dom', '2026-12-27 18:00+00');   -- 35 days before
select is(tests.msgs(:'mw', 'T13'), 1, 'still failing at 35 days → escalation');
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw'), 0, 'outreach is blocked while readiness fails');
insert into public.module_owner (module_id, team_member_id) values (:'mod', (:'j'::jsonb ->> 'ops')::uuid);
select tests.tick(:'dom', '2027-01-01 19:00+00');
select is(tests.asking(:'mw'), 'RD Instr1', 'once fixed, outreach starts at the next run');

select * from finish();
rollback;
