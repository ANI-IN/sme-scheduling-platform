-- Release Milestone 5: plain wording, message templates, holidays per domain, checklist, start asking
-- now, copying and batch saving settings, setup checklist, practice class.
begin;
\ir ../helpers/helpers.psql
select plan(27);

select tests.scenario('PG', 'Test', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1 \gset

-- =============================================================== plain wording
select is(private.plain_message_text('Thank you — you''re confirmed'), 'Thank you. You''re confirmed', 'a dash starts a new sentence');
select is(private.plain_message_text('9:00 AM – 1:00 PM'), '9:00 AM to 1:00 PM', 'a dash between times means "to"');
select is(private.plain_message_text('3–10 days'), '3 to 10 days', 'and between numbers');
insert into public.message (domain_id, audience, template_id, channel, unique_key, status, subject, body_text)
values (:'dom', 'Team', 'T0', 'Discord', 'pg-test-1', 'Cancelled', 'Escalation — readiness', 'Not done — please check');
select is((select body_text from public.message where unique_key = 'pg-test-1'), 'Not done. Please check',
  'team messages are stored without dashes');
select ok(position('—' in public.response_page('no-such-token')) = 0 and position('–' in public.response_page('no-such-token')) = 0,
  'confirm pages have no dashes');

-- =============================================================== message templates
select ok(position('—' in (private.render_instructor('M4', :'mw', :'i1') ->> 'body')) = 0, 'default instructor messages have no dashes');
select throws_ok(format($$ select public.save_message_template(%L, 'M1', 'Can you teach?', 'Hi {first_name}, can you teach {module}?') $$, :'dom'),
  '22023', null, 'a request without the classes and reply by date cannot be saved');
select throws_ok(format($$ select public.save_message_template(%L, 'M1', 'Hi', 'Hi {nickname} {module} {classes} {deadline}') $$, :'dom'),
  '22023', null, 'unknown details are refused');
select public.save_message_template(:'dom', 'M1', 'Teaching {module}?', E'Hello {first_name}! Could you teach {module}?\n{classes}\nReply by {deadline}.');
select ok((private.render_instructor('M1', :'mw', :'i1', '{"deadline": "Fri"}') ->> 'body') like 'Hello PG!%Reply by Fri.',
  'a saved template is used for the domain');
select is((select (x ->> 'changed')::boolean from jsonb_array_elements(public.message_templates(:'dom')) x where x ->> 'template_id' = 'M1'), true,
  'the templates page shows it as changed');
select ok((public.preview_message_template(:'dom', 'M1', 'Teaching {module}?', 'Hello {first_name} {module} {classes} {deadline}') ->> 'body') like 'Hello Alex%',
  'the live preview fills in sample details');
select public.reset_message_template(:'dom', 'M1');
select ok((private.render_instructor('M1', :'mw', :'i1', '{"deadline": "Fri"}') ->> 'body') like 'Hi PG,%', 'Reset to default brings back the default');

-- =============================================================== holidays per domain
insert into public.holiday (date, name, domain_id) values ('2027-05-05', 'PG only holiday', :'dom');
select is(private.holiday_on(:'dom', '2027-05-05'), 'PG only holiday', 'a domain can have its own holiday');
select is(private.holiday_on(tests.make_domain('PG Other'), '2027-05-05'), null, 'other domains do not see it');

-- =============================================================== checklist: extra task for one class
select tests.raw_book(:'mw', :'i1');
select public.add_checklist_item((select id from public.class_session where module_week_id = :'mw' order by starts_at limit 1), 'Book the bigger room')
  as item \gset
select ok(exists (select 1 from public.checklist_item where id = :'item' and added_manually), 'an extra task can be added to one class');
select lives_ok(format('select public.remove_checklist_item(%L)', :'item'), 'and removed again');

-- =============================================================== start asking now
select tests.make_week(:'mod', '2027-06-06') as mw2 \gset
select public.start_asking_now(:'mw2');
select ok(exists (select 1 from public.request where module_week_id = :'mw2' and kind = 'Outreach' and status in ('Sent', 'Queued')),
  'Start asking now asks the first instructor straight away');
select throws_ok(format('select public.start_asking_now(%L)', :'mw2'), '22023', null, 'but not while someone is already being asked');

-- =============================================================== settings: many at once, copy to a new domain
select throws_ok(format($$ select public.set_setting_at('Domain', %L, 'outreach_days', '45') $$, :'dom'), '22023', null,
  'one value at a time still checks the rules between settings');
select lives_ok(format($$ select public.set_settings_at('Domain', %L, '{"outreach_days": 45, "readiness_days": 55}') $$, :'dom'),
  'saving several values together checks the rules once all are in place');
select throws_ok(format($$ select public.set_settings_at('Domain', %L, '{"outreach_days": 50, "readiness_days": 52}') $$, :'dom'), '22023', null,
  'and still refuses values that break them');
select tests.make_domain('PG Copy', 'Draft') as dom2 \gset
select public.copy_domain_settings(:'dom', :'dom2');
select is(private.setting_int(:'dom2', 'readiness_days'), 55, 'a new domain can copy settings from another domain');

-- =============================================================== setup checklist and modules overview
select ok((select bool_and((x ->> 'done')::boolean) from jsonb_array_elements(public.domain_setup_status(:'dom')) x),
  'a domain that is fully set up has every checklist item done');
select ok((select not (x ->> 'done')::boolean from jsonb_array_elements(public.domain_setup_status(:'dom2')) x where x ->> 'key' = 'modules'),
  'a new domain shows what is missing');
select is((public.module_overview(:'dom') -> :'mod' ->> 'class_times')::int, 2, 'the modules overview counts class times');

-- =============================================================== practice class
select tests.make_instructor('PG Tester A', true, true), tests.make_instructor('PG Tester B', true, true);
select tests.login_as('ops@example.com');
select public.run_practice_class(:'dom') as practice \gset
select tests.as_postgres();
select is((select count(*)::int from jsonb_array_elements(:'practice'::jsonb -> 'steps') s where not (s ->> 'passed')::boolean), 0,
  'a practice class passes every stage: ' || (select string_agg(s ->> 'step', ', ') from jsonb_array_elements(:'practice'::jsonb -> 'steps') s where not (s ->> 'passed')::boolean));
select ok(not exists (select 1 from public.cohort where name like 'Practice class%'), 'and leaves nothing behind');

select * from finish();
rollback;
