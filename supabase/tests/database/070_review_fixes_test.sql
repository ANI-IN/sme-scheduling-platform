-- Regression tests for the independent review findings (M8).
begin;
select plan(22);

-- 1. Pausing a Test domain must keep test routing (BR-13).
select tests.scenario('PT', 'Test', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select public.set_domain_status(:'dom', 'Paused');
select tests.click(:'mw', :'i1', 'Yes');
select is((select to_address from public.message where module_week_id = :'mw' and template_id = 'M4' and channel = 'Email'), 'test-inbox@example.com',
  '#1 paused test domain: confirmation still goes to the test inbox');
select is((select bool_and(is_test) from public.message where module_week_id = :'mw' and template_id in ('M4', 'T2')), true,
  '#1 and is marked as a test message');

-- 2. A week must not stay "Asking" with nobody asked when the next ask is blocked.
select tests.scenario('SA', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select public.set_kill_switch(false);
select tests.click(:'mw', :'i1', 'No');
select is(tests.mw_status(:'mw'), 'Ready', '#2 a No while the kill switch is on leaves the week Ready (not stuck Asking)');
select public.set_kill_switch(true);
select tests.tick(:'dom', '2027-01-01 19:00+00');
select is(tests.asking(:'mw'), 'SA Instr2', '#2 the next run asks the next instructor');

-- 3. Release without restarting outreach stays stopped.
select tests.scenario('NR', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select public.release_booking(:'mw', 'Ops decision', false);
select tests.tick(:'dom', '2027-01-01 19:00+00');
select is(tests.asking(:'mw'), null, '#3 release without restart: nobody is asked at the next run');
select is((select paused from public.module_week where id = :'mw'), true, '#3 the week is paused until ops resumes it');

-- 4. Shifting a week sends one time-change message with the final times.
select tests.scenario('SH', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select public.shift_classes(:'mw', 1, false);
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'TimeChange'), 1, '#4 shift: one time-change request');
select is(tests.msgs(:'mw', 'M5'), 2, '#4 shift: one M5 per channel');
select ok((select body_text from public.message where module_week_id = :'mw' and template_id = 'M5' and channel = 'Email')
          like '%Sun, Feb 7%Thu, Feb 11%', '#4 the message shows the final times only');
select is((select time_version from public.module_week where id = :'mw'), 2, '#4 time version bumped once');

-- 5. Owner check-ins for two weeks due on the same day are both sent.
select tests.scenario('OC', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'owner') as owner \gset
select tests.make_week(:'mod', '2027-01-31', 'B') as mwb \gset
update public.class_session set starts_at = starts_at + interval '3 hours', ends_at = ends_at + interval '3 hours' where module_week_id = :'mwb';
select tests.tick(:'dom', '2027-01-17 17:30+00');
select tests.tick(:'dom', '2027-01-17 20:30+00');
select is((select count(*)::int from public.message where template_id = 'T11' and team_member_id = :'owner'), 2,
  '#5 two owner check-ins on the same day are both queued');

-- 6. Only the automation may run the engine at a chosen time.
select tests.login_as('ops@example.com');
select throws_ok(format('select public.engine_tick(%L, %L)', :'dom', '2027-01-20 00:00+00'), '42501', null,
  '#6 a team member cannot run the engine with a made-up "now"');
select tests.as_postgres();
select ok(not has_function_privilege('authenticated', 'public.engine_tick(uuid, timestamptz)', 'EXECUTE'), '#6 engine_tick is not granted to the app');

-- 7. "At risk (help pending)" clears when the help request is resolved.
select tests.scenario('HR', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.at('2027-01-30 06:00+00');
select (public.submit_help_request(tests.token(:'mw', :'i1', 'NeedHelp'), array['zoom'], null, 'NoRush', 'Either') ->> 'help_request_id') as hid \gset
select tests.tick(:'dom', '2027-01-30 06:00+00');
select is((select at_risk_reason from public.module_week where id = :'mw'), 'Help pending', '#7 flagged while help is open');
select public.help_set_status(:'hid', 'Resolved', 'Sorted by phone');
select is((select at_risk from public.module_week where id = :'mw'), false, '#7 flag cleared once the help request is resolved');

-- 8. A typed reply with nothing open still reaches someone.
select tests.make_instructor('Quiet Person') as qp \gset
select public.record_inbound_message('Email', 'quiet.person@example.org', 'hi', 'Just saying hello', 'q-1');
select ok((select cardinality(recipients) > 0 from public.attention_item where type = 'TypedReply' and instructor_id = :'qp'),
  '#8 typed reply with no open item is routed to ops');

-- 9. Moving the class much closer shortens the open request's window.
select tests.scenario('MV', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select public.change_class_time((select id from public.class_session where module_week_id = :'mw' and class_type = 'Live class'), '2027-01-02', '10:00', '14:00');
select ok((select deadline_at <= (select first_class_at from public.module_week where id = :'mw') from public.request
            where module_week_id = :'mw' and status in ('Sent', 'Reminded')), '#9 the deadline is never after the (new) first class');
select is((select deadline_at from public.request where module_week_id = :'mw' and status in ('Sent', 'Reminded')),
  '2027-01-02 00:00+00'::timestamptz, '#9 under 3 days now: move on 6h after the change');

-- 10. Moving a confirmed class while the kill switch is on waits for outreach to resume.
select tests.scenario('KM', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select public.set_kill_switch(false);
select public.change_class_time((select id from public.class_session where module_week_id = :'mw' and class_type = 'Live class'), '2027-01-31', '10:00', '14:00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'TimeChange'), 0, '#10 no time-change request while paused');
select public.set_kill_switch(true);
select tests.tick(:'dom', '2027-01-01 19:00+00');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'TimeChange'), 1, '#10 created at the next allowed run');

-- 11. Resending a message that hasn't gone out yet is refused.
select throws_ok(format('select public.resend_message(%L)', (select id from public.message where module_week_id = :'mw' and template_id = 'M5' limit 1)),
  'P0001', null, '#11 cannot resend a message that is still waiting to go out');

-- 12. Declines more than 10 days out reach the owner in the digest.
select tests.scenario('DG', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'owner') as owner \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'No');
update public.system_state set last_digest_date = null;
select public.engine_tick_all('2027-01-02 05:00+00');
select ok((select body_text from public.message where template_id = 'T12' and team_member_id = :'owner') like '%DG Instr1 said no%',
  '#12 the owner''s digest lists the decline');

select * from finish();
rollback;
