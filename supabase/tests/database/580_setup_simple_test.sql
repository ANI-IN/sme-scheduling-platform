-- Release 3, owner's items B6 to B9 (migration 20261123000032_setup_simple.sql): the contact check is optional, a
-- welcome message (M22) for new instructors, a module is ready with at least 1 instructor in its order, and modules
-- are Draft, Live or Archived.
begin;
\ir ../helpers/helpers.psql
select plan(40);

select tests.company();
select tests.scenario('SS', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset

-- =============================================================== B6. the contact check is optional
update public.instructor set verified_at = null, version = version where id in (:'i1', :'i2');
select is(private.eligibility(:'i1', :'mw'), null, '1. an instructor without a contact check can be asked in a live domain');
select is(private.readiness_problems(:'mw'), '[]'::jsonb, '2. the setup check passes with instructors who were not checked');
select public.start_asking_now(:'mw');
select is((select instructor_id from public.request where module_week_id = :'mw' and kind = 'Outreach' and status = 'Sent'),
  :'i1'::uuid, '3. and the first of them is asked');
select ok((select verified_at is null from public.instructor where id = :'i1'), '4. the check stays as information: still not checked');

-- No task about the contact check any more, and one from before closes by itself.
insert into public.attention_item (domain_id, type, severity, title, dedupe_key, status)
values (:'dom', 'UnverifiedInRanking', 'Normal', 'Not verified: SS Instr2', 'unverified:' || :'dom' || ':' || :'i2', 'Open');
select private.step_health(:'dom', now() + interval '10 days');
select is((select status || ': ' || done_note from public.attention_item where dedupe_key = 'unverified:' || :'dom' || ':' || :'i2'),
  'Done: The contact check is optional', '5. an open contact check task closes by itself');
select is((select count(*)::int from public.attention_item where domain_id = :'dom' and type = 'UnverifiedInRanking' and status <> 'Done'),
  0, '6. and no new one is raised for instructors who were not checked');

-- Nobody left in line: the setup check words no longer name a contact check.
update public.instructor set status = 'Inactive', version = version where id in (:'i1', :'i2');
select is((select p ->> 'text' from jsonb_array_elements(private.readiness_problems(:'mw')) p where p ->> 'code' = 'no_instructor'),
  'Nobody in line is in use, available and free at that time', '7. the setup check says who can be asked, without "verified"');
update public.instructor set status = 'Active', version = version where id in (:'i1', :'i2');

-- The practice class needs two test instructors, checked or not.
select tests.scenario('SP', 'Test', '2027-01-31', 1) as p \gset
select (:'p'::jsonb ->> 'domain') as pdom \gset
select throws_ok(format('select public.run_practice_class(%L)', :'pdom'), '22023', 'Add at least two test instructors first.',
  '8. without test instructors the practice class says what to add');
select tests.make_instructor('SP Tester A', false, true), tests.make_instructor('SP Tester B', false, true);
select public.run_practice_class(:'pdom') as practice \gset
select is((select count(*)::int from jsonb_array_elements(:'practice'::jsonb -> 'steps') s where not (s ->> 'passed')::boolean), 0,
  '9. two test instructors without a contact check run a whole practice class');

-- =============================================================== B7. the welcome message
select is(private.template_defaults() -> 'M22' ->> 'body',
  E'You are set up to receive class requests from SME Scheduling.\n\nWhen we ask you to teach, answer with the buttons in the message.',
  '10. the welcome text says they are set up and how answers work');
select ok(exists (select 1 from jsonb_array_elements(public.message_templates(:'dom')) x where x ->> 'template_id' = 'M22'
                   and x ->> 'name' = 'Welcome'), '11. it is on Settings, Message templates like the others');
select is((select default_value::text || ' ' || group_name || ' ' || value_type from public.setting_definition where key = 'welcome_message'),
  'true Outreach bool', '12. a setting for it, on by default, with the other asking settings');

insert into public.discord_channel (id, server_id, name) values
  ('999000000000058001', '999000000000000001', 'ss-one'), ('999000000000058002', '999000000000000001', 'ss-one-new'),
  ('999000000000058003', '999000000000000001', 'ss-two'), ('999000000000058004', '999000000000000001', 'ss-two-b');
select public.set_instructor_channel(:'i1', :'dom', '999000000000058001');
select is((select count(*)::int from public.message where template_id = 'M22' and instructor_id = :'i1'), 1,
  '13. choosing an instructor''s channel queues one welcome message');
select is((select channel || ' ' || discord_channel_id || ' ' || domain_id || ' ' || (status in ('Pending', 'Scheduled')) from public.message
            where template_id = 'M22' and instructor_id = :'i1'),
  'Discord 999000000000058001 ' || :'dom' || ' true', '14. on Discord, in their channel of that domain, through the normal queue');
select ok((select body_text like '%You are set up to receive class requests from SME Scheduling.%answer with the buttons in the message.'
             and subject = 'Welcome to SME Scheduling' from public.message where template_id = 'M22' and instructor_id = :'i1'),
  '15. with the welcome text');
select ok((select note like 'On Discord%' from public.history_event where action = 'Welcome message sent to SS Instr1'),
  '16. Activity history says it was sent');
select public.set_instructor_channel(:'i1', :'dom', '999000000000058002');
select is((select count(*)::int from public.message where template_id = 'M22' and instructor_id = :'i1'), 1,
  '17. a new channel in the same domain does not send it twice');

-- Another domain has its own welcome; a changed text there is used.
select tests.make_domain('SS Two', 'Live') as dom2 \gset
select tests.approve_test_channels();
select public.save_message_template(:'dom2', 'M22', 'Hello from {domain}', 'You are set up for {domain}. Answer with the buttons.');
select public.set_instructor_channel(:'i1', :'dom2', '999000000000058003');
select is((select subject from public.message where template_id = 'M22' and instructor_id = :'i1' and domain_id = :'dom2'),
  'Hello from SS Two', '18. a second domain sends its own welcome, with its own text');
select is((select count(*)::int from public.message where template_id = 'M22' and instructor_id = :'i1'), 2,
  '19. one per domain');

-- By email when they are added.
select is(public.send_welcome_message(:'i2', :'dom'), 'sent', '20. adding an instructor sends the welcome by email');
select is((select channel || ' ' || to_address from public.message where template_id = 'M22' and instructor_id = :'i2'),
  'Email ss.instr2@example.org', '21. to their email');
select is(public.send_welcome_message(:'i2', :'dom'), 'already sent', '22. never twice by email');
select is(public.send_welcome_message(:'i2', :'dom2'), 'already sent', '23. not even from another domain');
select is((select count(*)::int from public.message where template_id = 'M22' and instructor_id = :'i2'), 1, '24. still one');

-- The setting switches it off for a domain, and the change is logged.
select public.set_settings_at('Domain', :'dom2', '{"welcome_message": false}');
select ok(exists (select 1 from public.history_event where entity_table = 'setting' and (after ->> 'key') = 'welcome_message'
                   and after ->> 'value' = 'false'), '25. switching it off is logged in Activity history');
select public.set_instructor_channel(:'i2', :'dom2', '999000000000058004');
select is((select count(*)::int from public.message where template_id = 'M22' and instructor_id = :'i2' and channel = 'Discord'), 0,
  '26. with the setting off, choosing a channel sends no welcome');

-- Blocked by the beta rules: logged with the reason, and it may go once the reason is gone.
select public.set_recipient_rules('{}', 'Test instructors and signed in colleagues');
select tests.make_instructor('SS Real') as i3 \gset
select is(public.send_welcome_message(:'i3', :'dom'),
  'blocked: During the beta, only test instructors are contacted. Mark SS Real as a test instructor to try this.',
  '27. the beta rules apply to the welcome');
select is((select note from public.history_event where action = 'Welcome message to SS Real blocked'),
  'During the beta, only test instructors are contacted. Mark SS Real as a test instructor to try this.',
  '28. Activity history says it was blocked, and why');
update public.instructor set is_test = true, version = version where id = :'i3';
select is(public.send_welcome_message(:'i3', :'dom'), 'sent', '29. once the reason is gone it is sent');
select is((select count(*)::int from public.message where template_id = 'M22' and instructor_id = :'i3' and status <> 'Cancelled'), 1,
  '30. once');
select public.set_recipient_rules('{}', 'Anyone');

-- In a domain in testing it goes to the testing channel, like every message.
select public.set_instructor_channel(:'i3', :'pdom', '999000000000058002');
select ok((select discord_channel_id = (select test_discord_channel_id from public.domain where id = :'pdom')
             and body_text like '[TEST → would go to SS Real]%' from public.message
            where template_id = 'M22' and instructor_id = :'i3' and domain_id = :'pdom'), '31. testing sends it to the testing channel');

-- =============================================================== B8. ready with at least 1 instructor in the order
select is((select default_value::text from public.setting_definition where key = 'min_active_instructors'), '1',
  '32. a module needs 1 instructor in its order by default');
update public.instructor set status = 'Inactive', version = version where id = :'i2';
select is((select x ->> 'label' || ': ' || (x ->> 'done') from jsonb_array_elements(public.domain_setup_status(:'dom')) x
            where x ->> 'key' = 'instructors'),
  'Put at least 1 instructor in the instructor order of every module: true', '33. the setup step is done with 1 instructor in use');
select is((select (public.module_overview(:'dom') -> :'mod' ->> 'needed')::int), 1, '34. the Modules list needs 1');
update public.instructor set status = 'Inactive', version = version where id = :'i1';
select is((select (x ->> 'done')::boolean from jsonb_array_elements(public.domain_setup_status(:'dom')) x where x ->> 'key' = 'instructors'),
  false, '35. and not done with nobody in use in the order');
update public.instructor set status = 'Active', version = version where id in (:'i1', :'i2');
select public.set_settings_at('Domain', :'dom', '{"min_active_instructors": 3}');
select is((select x ->> 'label' || ': ' || (x ->> 'done') from jsonb_array_elements(public.domain_setup_status(:'dom')) x
            where x ->> 'key' = 'instructors'),
  'Put at least 3 instructors in the instructor order of every module: false', '36. the number comes from the setting');

-- =============================================================== B9. Draft, Live and Archived
select is((select label from public.setting_definition where key = 'min_active_instructors'),
  'A module is ready with at least this many instructors in its instructor order', '37. the setting says what it is for');
update public.module set status = 'Inactive', version = version where id = :'mod';
select is((select p ->> 'text' from jsonb_array_elements(private.readiness_problems(:'mw')) p where p ->> 'code' = 'module_inactive'),
  'The module is a draft, so nobody is asked', '38. the setup check calls a module that is not live a draft');
select throws_ok(format('select public.save_standard_schedule(null, %L, %L, array[%L]::uuid[])', :'dom', 'SS standard', :'mod'),
  '22023', 'Only live modules of this domain can be in its standard schedules.', '39. a standard schedule takes live modules');
select is((select status from public.module where id = :'mod'), 'Inactive', '40. the stored value is unchanged: no data moves');

select * from finish();
rollback;
