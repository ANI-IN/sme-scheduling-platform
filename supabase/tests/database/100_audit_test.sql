-- Release Milestone 4: Activity history and audit trail.
begin;
\ir ../helpers/helpers.psql
select plan(19);

select tests.scenario('AU', 'Test', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1 \gset
select (select cohort_id from public.module_week where id = :'mw') as coh \gset

-- =============================================================== who, what and related records
select tests.login_as('ops@example.com');
select public.set_setting_at('Cohort', :'coh', 'window_long_move_h', '72', 'Weekend cohort needs longer');
select is((select note from public.history_event where entity_table = 'setting' order by id desc limit 1), 'Weekend cohort needs longer',
  'the reason for an override is recorded');
select is((select entity_label from public.history_event where entity_table = 'setting' order by id desc limit 1),
  (select label from public.setting_definition where key = 'window_long_move_h'), 'with the setting''s readable name');
select is((select cohort_id from public.history_event where entity_table = 'setting' order by id desc limit 1), :'coh'::uuid,
  'and the cohort it applies to');
select is((select domain_id from public.history_event where entity_table = 'setting' order by id desc limit 1), :'dom'::uuid,
  'and its domain');
select public.pause_outreach(:'mw', true);
select is((select cohort_id from public.history_event where action = 'Outreach paused' order by id desc limit 1), :'coh'::uuid,
  'class week actions carry the cohort');
select is((select actor_label from public.history_event where action = 'Outreach paused' order by id desc limit 1), 'ops@example.com',
  'and who did it');
select tests.as_postgres();

update public.module set rotation_order = 7 where id = :'mod';
select is((select actor_label from public.history_event where entity_table = 'module' order by id desc limit 1), 'Database admin',
  'a change made directly in the database is labelled "Database admin", not "System"');

-- A deleted record keeps its name in history.
insert into public.instructor (full_name, primary_email) values ('Temporary Person', 'temp.person@example.org') returning id as tmp \gset
delete from public.instructor where id = :'tmp';
select is((select entity_label from public.history_event where entity_table = 'instructor' and action = 'instructor removed' order by id desc limit 1),
  'Temporary Person', 'a removed instructor is still named in Activity history');

-- =============================================================== undo only where it is safe
select ok((select not public.undoable(e) from public.history_event e where entity_table = 'domain' and action = 'domain added' and entity_id = :'dom'::uuid),
  'creating a domain cannot be undone');
select ok((select not public.undoable(e) from public.history_event e where entity_table = 'module' and action = 'module added' and entity_id = :'mod'::uuid),
  'creating a module cannot be undone');
select tests.login_as('ops@example.com');
select ok((select public.undoable(e) from public.history_event e where entity_table = 'module' and action = 'module changed' order by id desc limit 1),
  'editing a module can be undone');
select ok((select not public.undoable(e) from public.history_event e where action = 'Outreach paused' order by id desc limit 1),
  'manual and automatic actions are not offered for undo');
select throws_ok(format('select public.undo_history_event(%s)',
  (select id from public.history_event where entity_table = 'module' and action = 'module added' and entity_id = :'mod'::uuid)),
  '22023', null, 'and the database refuses to undo the creation of a module');
select tests.as_postgres();

-- =============================================================== events that must be recorded
select tests.login_as('ops@example.com');
select public.set_domain_status(:'dom', 'Live');
select ok(exists (select 1 from public.history_event where action = 'Went live' and domain_id = :'dom'::uuid), 'going live is recorded');
select public.set_kill_switch(false);
select ok(exists (select 1 from public.history_event where action = 'All messages to instructors paused'), 'pausing all messages is recorded');
select public.set_kill_switch(true);
select public.log_export('Upcoming classes', 12, '{"module": "Concurrency"}', :'dom');
select ok(exists (select 1 from public.history_event where action = 'Downloaded Upcoming classes' and (after ->> 'rows')::int = 12),
  'downloads are recorded with the number of rows');

-- =============================================================== private error log
select public.log_app_error('Cannot read properties of undefined', 'stack line', '/classes', 'Chrome');
select public.log_app_error('Cannot read properties of undefined', 'stack line', '/classes', 'Chrome');
select is((select count from public.app_error where message = 'Cannot read properties of undefined'), 2,
  'repeated app errors are counted, not stored again');
select tests.as_postgres();
select tests.login_anon();
select throws_ok($$ select public.log_app_error('x') $$, '42501', null, 'signed out visitors cannot write to the error log');
select tests.as_postgres();
select ok(not has_table_privilege('authenticated', 'public.app_error', 'INSERT'), 'the error log is written only through the function');

select * from finish();
rollback;
