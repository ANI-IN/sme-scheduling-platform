-- Release 3, M4b (decisions 283 and 289): low review findings that affect security or data.
begin;
\ir ../helpers/helpers.psql
select plan(28);

select tests.scenario('SF', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
insert into public.team_member (name, email) values ('SF Ops', 'sf.ops@example.com') on conflict do nothing;

-- 1 to 8: SEC 7, only the automation calls these. A signed in person is refused by the grants, and even a caller
-- that has the grants but is not the automation (the service role's rights with a signed in person's identity) is
-- refused inside each function.
select tests.login_google('sf.ops@example.com');
select throws_ok($$ select public.claim_outbound_messages(5) $$, '42501', null, '1. a signed in person cannot take messages to send');
select tests.as_postgres();
create or replace function tests.as_service_rights_but_a_person() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role": "authenticated", "email": "sf.ops@example.com"}', true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  execute 'set local role service_role';
end $$;
select tests.as_service_rights_but_a_person();
select throws_ok($$ select public.claim_outbound_messages(5) $$, '42501', 'Only the automation can do this.', '2. nor anyone else who is not the automation');
select throws_ok($$ select public.next_actions(5) $$, '42501', 'Only the automation can do this.', '3. app actions');
select throws_ok($$ select public.record_inbound_message('Email', 'x@example.com', 'Hi', 'Hello', 'ext-1') $$, '42501',
  'Only the automation can do this.', '4. recording a reply as if it came in');
select throws_ok($$ select public.daily_jobs() $$, '42501', 'Only the automation can do this.', '5. the daily jobs');
select throws_ok($$ select public.engine_tick_all() $$, '42501', 'Only the automation can do this.', '6. the automatic check for every domain');
reset role;
select tests.as_postgres();
select lives_ok($$ select public.claim_outbound_messages(5) $$, '7. the automation still can');
select lives_ok($$ select public.next_actions(5) $$, '8. and takes app actions');

-- 9 to 10: DIS 17, two replies in the same second.
insert into public.attention_item (domain_id, type, severity, title, instructor_id, module_week_id, dedupe_key)
values (:'dom', 'TypedReply', 'Normal', 'SF reply', :'i1', :'mw', 'sf-reply') returning id as item \gset
select tests.login_google('sf.ops@example.com');
select public.reply_to_instructor(:'item', 'First answer');
select public.reply_to_instructor(:'item', 'Second answer');
select tests.as_postgres();
select is((select count(*)::int from public.message where template_id = 'M14' and instructor_id = :'i1' and channel = 'Email'), 2,
  '9. two replies in the same second are two messages');
select is((select count(distinct split_part(unique_key, ':reply:', 2))::int from public.message where template_id = 'M14' and instructor_id = :'i1'), 2,
  '10. each with its own key');

-- 11 to 12: DIS 15, alert and testing channels are never an instructor's channel.
select throws_like(format('select public.set_instructor_channel(%L, %L, (select alert_discord_channel_id from public.domain where id = %L))',
  :'i2', :'dom', :'dom'), '%is an alert or testing channel%', '11. the domain''s alert channel cannot be an instructor''s channel');
select throws_like(format('select public.set_instructor_channel(%L, %L, (select test_discord_channel_id from public.domain where id = %L))',
  :'i2', :'dom', :'dom'), '%is an alert or testing channel%', '12. nor its testing channel');

-- 13 to 14: N12, pausing still works and is refused for a confirmed class week.
select tests.login_google('sf.ops@example.com');
select lives_ok(format('select public.pause_outreach(%L, true)', :'mw'), '13. pausing a class week still works');
select tests.as_postgres();
update public.module_week set paused = false where id = :'mw';
select tests.tick(:'dom', '2027-01-01 18:00+00');
select tests.click(:'mw', :'i1', 'Yes');
select tests.login_google('sf.ops@example.com');
select throws_ok(format('select public.pause_outreach(%L, true)', :'mw'), '22023', null, '14. a confirmed class week is not paused');
select tests.as_postgres();

-- 15 to 16: OUT 14, a released instructor's Need help link closes.
select tests.scenario('SG', 'Live', '2027-01-31', 2) as k \gset
select (:'k'::jsonb ->> 'domain') as dom2, (:'k'::jsonb ->> 'mw') as mw2, (:'k'::jsonb ->> 'i1') as j1 \gset
select tests.tick(:'dom2', '2027-01-01 18:00+00');
select tests.click(:'mw2', :'j1', 'Yes');
select tests.tick(:'dom2', '2027-01-21 18:00+00');
select tests.click(:'mw2', :'j1', 'CantMakeIt');
select is(public.submit_help_request(tests.token(:'mw2', :'j1', 'NeedHelp'), '{zoom}', 'Link please', 'NoRush', 'Either') ->> 'result',
  'closed', '15. after a release, the old instructor''s Need help link has closed');
select is((select count(*)::int from public.help_request where module_week_id = :'mw2'), 0,
  '16. and no help request is filed against the replacement''s booking');

-- 17 to 18: N1, an unanswered help request keeps its task when the classes are over.
select tests.scenario('SH', 'Live', '2027-01-31', 1) as h \gset
select (:'h'::jsonb ->> 'domain') as dom3, (:'h'::jsonb ->> 'mw') as mw3, (:'h'::jsonb ->> 'i1') as h1 \gset
select tests.tick(:'dom3', '2027-01-01 18:00+00');
select tests.click(:'mw3', :'h1', 'Yes');
select tests.tick(:'dom3', '2027-01-21 18:00+00');
select public.submit_help_request(tests.token(:'mw3', :'h1', 'NeedHelp'), '{payment}', 'About my payment', 'NoRush', 'Either');
select tests.tick(:'dom3', '2027-02-15 18:00+00');
select is((select status from public.module_week where id = :'mw3'), 'Completed', '17. the classes are over');
select ok(exists (select 1 from public.attention_item a join public.help_request h on a.dedupe_key = 'help:' || h.id
                   where h.module_week_id = :'mw3' and a.status <> 'Done' and h.status in ('Open', 'InProgress', 'WaitingOnInstructor')),
  '18. the unanswered help request still has its task, so someone answers it');

-- 19 to 20: SEC 14, an answer link quoted in a typed reply cannot be used by whoever reads the task.
select public.record_inbound_message('Email', (select primary_email from public.instructor where id = :'h1'), 'Re: your class',
  E'Thanks, all good.\n> Yes: https://pages.example.test/r?t=ABCDEFGHIJKLMNOPQRSTUVWXYZ012345', 'ext-sec14');
select ok((select body_text from public.message where unique_key = 'in:Email:ext-sec14') like '%?t=(link removed)%',
  '19. the secret part of a quoted answer link is removed from the stored reply');
select ok(not exists (select 1 from public.message where unique_key = 'in:Email:ext-sec14' and body_text like '%ABCDEFGHIJKLMNOP%'),
  '20. and the secret itself is not kept');

-- 21 to 22: SEC 8, links close when the class is over and expire after 90 days.
select ok(public.response_page(tests.token(:'mw3', :'h1', 'CantMakeIt'))::text like '%Link closed%',
  '21. a link closes when its classes are over');
select tests.scenario('SI', 'Live', '2027-01-31', 1) as g \gset
select (:'g'::jsonb ->> 'domain') as dom4, (:'g'::jsonb ->> 'mw') as mw4, (:'g'::jsonb ->> 'i1') as g1 \gset
select tests.tick(:'dom4', '2027-01-01 18:00+00');
select tests.click(:'mw4', :'g1', 'Yes');
update public.response_link set created_at = now() - interval '91 days'
 where token = tests.token(:'mw4', :'g1', 'CantMakeIt');
select ok(public.response_page(tests.token(:'mw4', :'g1', 'CantMakeIt'))::text like '%Link closed%', '22. every link expires after 90 days');

-- 23 to 24: SEC 8, Need help takes only the offered categories and cannot be replayed.
select tests.tick(:'dom4', '2027-01-21 18:00+00');
select public.submit_help_request(tests.token(:'mw4', :'g1', 'NeedHelp'), '{zoom,made_up}', 'Zoom link please', 'NoRush', 'Either');
select is((select categories from public.help_request where module_week_id = :'mw4'), '{zoom}'::text[],
  '23. only the categories the page offers are kept');
select public.submit_help_request(tests.token(:'mw4', :'g1', 'NeedHelp'), '{zoom}', 'Again', 'NoRush', 'Either');
select is((select count(*)::int from public.help_request where module_week_id = :'mw4'), 1,
  '24. sending the same help request again a moment later does not file another one');

-- 25 to 28: SCH new 3, 4 and 5, the classes of one class week never overlap.
select tests.make_domain('SJ') as dom5 \gset
select tests.make_module(:'dom5', 'SJ module') as mod5 \gset
select throws_like(format($$ select public.create_module_weeks(%L, jsonb_build_array(jsonb_build_object('module_id', %L, 'cohort', 'Main cohort',
  'classes', jsonb_build_array(
    jsonb_build_object('class_type', 'Live class', 'title', 'Twice', 'date', '2027-05-02', 'start_time', '09:00', 'end_time', '10:00'),
    jsonb_build_object('class_type', 'Live class', 'title', 'Twice', 'date', '2027-05-02', 'start_time', '09:00', 'end_time', '10:00'))))) $$,
  :'dom5', :'mod5'), '%overlaps another class of the same class week%', '25. a class listed twice in a plan is refused (SCH new 5)');
select throws_like(format($$ select public.create_module_weeks(%L, jsonb_build_array(jsonb_build_object('module_id', %L, 'cohort', 'Main cohort',
  'classes', jsonb_build_array(
    jsonb_build_object('class_type', 'Live class', 'title', 'US class', 'date', '2027-05-09', 'start_time', '18:00', 'end_time', '20:00', 'region', 'US'),
    jsonb_build_object('class_type', 'Other', 'title', 'India class', 'date', '2027-05-10', 'start_time', '07:00', 'end_time', '09:00', 'region', 'India'))))) $$,
  :'dom5', :'mod5'), '%overlaps another class of the same class week%',
  '26. a US class and an India class that overlap in real time are refused (each in its own region)');

select tests.make_week(:'mod5', '2027-06-06') as mw5 \gset
select public.set_week_same_instructor(:'mw5', false, 'Split for the test');
update public.class_session set starts_at = (select min(starts_at) from public.class_session c join public.module_week w on w.id = c.module_week_id where w.split_group = :'mw5'),
       ends_at = (select min(starts_at) from public.class_session c join public.module_week w on w.id = c.module_week_id where w.split_group = :'mw5') + interval '1 hour'
 where id = (select c.id from public.class_session c join public.module_week w on w.id = c.module_week_id
              where w.split_group = :'mw5' order by c.starts_at desc limit 1);
select throws_ok(format('select public.set_week_same_instructor(%L, true)', :'mw5'), '23P01', null,
  '27. joining class weeks whose classes overlap into one is refused (SCH new 3)');

select tests.make_week(:'mod5', '2027-03-14') as mw6 \gset
insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region, status)
values (:'mw6', 'Other', 'India session', '2027-03-14 20:00+00', '2027-03-14 22:00+00', 'India', 'Planned');
select throws_like(format('select public.shift_classes(%L, -1, false)', :'mw6'), '%would overlap%',
  '28. moving a US and India class week back across the clock change, where its classes would overlap, is refused (SCH new 4)');

select * from finish();
rollback;
