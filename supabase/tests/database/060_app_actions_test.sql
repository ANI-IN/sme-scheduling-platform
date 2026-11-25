-- App actions and access (AUTH-4, SCH-1/3/4, HIS-3, SYS-1, PRD 7.3 Reply, resend).
begin;
\ir ../helpers/helpers.psql
select plan(24);

select tests.scenario('AP', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'module') as mod,
       (:'j'::jsonb ->> 'i1') as i1 \gset

-- =============================================================== function permissions
select ok(not has_function_privilege('anon', 'public.engine_tick(uuid, timestamptz)', 'EXECUTE'), 'anon cannot run the engine');
select ok(not has_function_privilege('anon', 'public.record_response(text, text)', 'EXECUTE'), 'anon cannot record answers');
select ok(not has_function_privilege('authenticated', 'public.record_response(text, text)', 'EXECUTE'), 'the app cannot record instructor answers (n8n only)');
select ok(not has_function_privilege('authenticated', 'public.claim_outbound_messages(int)', 'EXECUTE'), 'the app cannot claim the outbox');
select ok(not has_function_privilege('authenticated', 'public.response_page(text)', 'EXECUTE'), 'the app cannot render instructor pages');
select ok(has_function_privilege('authenticated', 'public.assign_manually(uuid, uuid, text, boolean, text)', 'EXECUTE'), 'the app can call action functions');
select tests.login_as('outsider@gmail.com');
select throws_ok(format('select public.pause_outreach(%L, true)', :'mw'), '42501', null, 'a non-company account is refused inside the function');
select tests.as_postgres();
select tests.login_as('ops@example.com');
select lives_ok(format('select public.pause_outreach(%L, true)', :'mw'), 'a company account can act');
select ok(exists (select 1 from public.history_event where action = 'Asking paused' and actor_kind = 'TeamMember' and actor_label = 'ops@example.com'),
  'the action is recorded with the member who did it (AUTH-3)');
select public.pause_outreach(:'mw', false);
select tests.as_postgres();

-- =============================================================== kill switch holds queued instructor messages
select tests.tick(:'dom', '2027-01-01 18:00+00');
select public.set_kill_switch(false);
select is((select count(*)::int from public.claim_outbound_messages(100) where audience = 'Instructor'), 0,
  'kill switch on: n8n cannot claim instructor messages');
select ok((select count(*)::int from public.message where module_week_id = :'mw' and template_id = 'M1' and status = 'Pending') = 2,
  'they are held, not lost');
select public.set_kill_switch(true);
select is((select count(*)::int from public.claim_outbound_messages(100) where module_week_id = :'mw' and template_id = 'M1'), 2,
  'kill switch off: they go out');

-- =============================================================== reply and resend
select tests.click(:'mw', :'i1', 'Yes');
select public.record_inbound_message('Discord', (select discord_user_id from public.instructor where id = :'i1'), null, 'Will there be a recording?', 'ap-1');
select public.reply_to_instructor((select id from public.attention_item where type = 'TypedReply' and module_week_id = :'mw'), 'Yes, we record every class.');
select is(tests.msgs(:'mw', 'M14'), 2, 'Reply from Needs Attention is sent to the instructor (M14)');
select is((select status from public.attention_item where type = 'TypedReply' and module_week_id = :'mw'), 'Acknowledged', 'and the item is acknowledged');
select tests.taken((select id from public.message where module_week_id = :'mw' and template_id = 'M4' and channel = 'Email'));
select public.report_message_result((select id from public.message where module_week_id = :'mw' and template_id = 'M4' and channel = 'Email'), true, 'gmail-x');
select public.resend_message((select id from public.message where module_week_id = :'mw' and template_id = 'M4' and channel = 'Email'));
select is(tests.msgs(:'mw', 'M4'), 3, 'resend creates a new outbox row (new unique key)');

-- =============================================================== planner (SCH-1, SCH-4) across daylight saving
select (public.generate_classes(:'dom', :'mod', array['2027-03-07', '2027-03-14']::date[])) as g \gset
select is(:'g'::jsonb -> 0 -> 'classes' -> 0 ->> 'shown', 'Sun, Mar 7 · 9:00 AM to 1:00 PM PST', 'generator: Mar 7 live class at 9:00 AM PST');
select is(:'g'::jsonb -> 1 -> 'classes' -> 0 ->> 'shown', 'Sun, Mar 14 · 9:00 AM to 1:00 PM PDT', 'generator: Mar 14 (first PDT Sunday) still 9:00 AM');
select is((:'g'::jsonb -> 1 -> 'classes' -> 0 ->> 'starts_at')::timestamptz, '2027-03-14 16:00+00'::timestamptz, 'stored 16:00 UTC');
select lives_ok(format($$select public.create_module_weeks(%L, (select jsonb_agg(jsonb_build_object('module_id', w ->> 'module_id', 'week_start_date', w ->> 'week_start_date', 'classes', w -> 'classes')) from jsonb_array_elements(%L::jsonb) w))$$,
  :'dom', :'g'), 'planned weeks are created');
select throws_ok(format($$select public.create_module_weeks(%L, (select jsonb_agg(jsonb_build_object('module_id', w ->> 'module_id', 'week_start_date', w ->> 'week_start_date', 'classes', w -> 'classes')) from jsonb_array_elements(%L::jsonb) w))$$,
  :'dom', :'g'), '23505', null, 'planning the same weeks again is refused with a message');

-- shift onto an existing week is refused in plain words; a valid shift keeps 9:00 AM PT across DST (SCH-3)
select throws_ok(format('select public.shift_classes(%L, 1, false)', (select id from public.module_week where module_id = :'mod' and week_start_date = '2027-03-07')),
  'P0001', null, 'shifting onto a week the module already has is refused');
select public.shift_classes((select id from public.module_week where module_id = :'mod' and week_start_date = '2027-03-07'), 1, true);
select is((select to_char(c.starts_at at time zone 'America/Los_Angeles', 'YYYY-MM-DD HH24:MI') from public.class_session c
            join public.module_week w on w.id = c.module_week_id
           where w.module_id = :'mod' and w.week_start_date = '2027-03-14' and c.class_type = 'Live class'),
  '2027-03-14 09:00', 'shift this + later: the PST week moved into PDT and still starts at 9:00 AM PT');
select is((select count(*)::int from public.module_week where module_id = :'mod' and week_start_date in ('2027-03-14', '2027-03-21')), 2,
  'both weeks moved by one week, no duplicates');

-- =============================================================== undo a setting change (HIS-3)
-- A team member changes the setting in the app (only their changes can be undone).
select tests.login_member('ap.ops@example.com');
select public.set_setting(:'dom', 'outreach_days', '25');
select tests.as_postgres();
select public.undo_history_event((select id from public.history_event where entity_table = 'setting' and action = 'setting added' order by id desc limit 1));
select is(private.setting_int(:'dom', 'outreach_days'), 30, 'undo of a setting restores the default');

select * from finish();
rollback;
