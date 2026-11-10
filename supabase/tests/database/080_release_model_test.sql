-- Release Milestone 2: people and ownership, cohorts, flexible classes, settings layers, warnings.
begin;
\ir ../helpers/helpers.psql
select plan(45);

select tests.scenario('RM', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3,
       (:'j'::jsonb ->> 'ops') as ops, (:'j'::jsonb ->> 'lead') as lead, (:'j'::jsonb ->> 'owner') as owner \gset

-- =============================================================== cohorts
select is((select cohort from public.module_week where id = :'mw'), 'Main cohort', 'a class week without a cohort name joins the Main cohort');
select ok((select cohort_id is not null from public.module_week where id = :'mw'), 'every class week belongs to a cohort');

-- Two cohorts of the same module in the same week.
select tests.make_week(:'mod', '2027-01-31', 'Weekday') as mw_b \gset
select (select cohort_id from public.module_week where id = :'mw_b') as coh_b \gset
select is((select count(*)::int from public.module_week where module_id = :'mod' and week_start_date = '2027-01-31'), 2,
  'two cohorts of the same module run in the same week');
select lives_ok(format('select tests.raw_book(%L, %L)', :'mw', :'i1'), 'instructor 1 is confirmed for the main cohort');
select throws_ok(format('select tests.raw_book(%L, %L)', :'mw_b', :'i1'), '23P01', null,
  'the same instructor can never be confirmed for overlapping classes in another cohort');
select ok(private.eligibility(:'i1', :'mw_b') is not null, 'and the automation skips them for the overlapping cohort');
select lives_ok(format('select tests.raw_book(%L, %L)', :'mw_b', :'i2'), 'another instructor teaches the other cohort at the same time');

-- The same instructor in two cohorts at times that do not overlap.
select (public.create_module_weeks(:'dom', jsonb_build_array(jsonb_build_object('module_id', :'mod', 'cohort', 'Evening',
  'classes', jsonb_build_array(jsonb_build_object('class_type', 'Live class', 'title', 'Evening live', 'date', '2027-01-31',
                                                   'start_time', '18:00', 'end_time', '20:00')))), true) -> 'module_week_ids' ->> 0) as mw_eve \gset
select lives_ok(format('select tests.raw_book(%L, %L)', :'mw_eve', :'i1'), 'the same instructor teaches two cohorts when the times do not overlap');

-- =============================================================== class patterns per cohort, any weekday
insert into public.class_pattern_item (module_id, cohort_id, class_type, title_template, day_offset, start_time_pt, duration_minutes, sort_order)
values (:'mod', :'coh_b', 'Live class', '{module}: Weekday live', 0, '19:00', 120, 1),
       (:'mod', :'coh_b', 'Assignment review', '{module}: Weekday review', 2, '19:00', 90, 2);
select is((select string_agg(x ->> 'date', ',' order by x ->> 'date')
             from jsonb_array_elements(public.generate_classes(:'dom', :'mod', array['2027-02-08']::date[], 'Weekday') -> 0 -> 'classes') x),
  '2027-02-08,2027-02-10', 'a weekday cohort uses its own pattern: Monday and Wednesday');
select is((select string_agg(x ->> 'date', ',' order by x ->> 'date')
             from jsonb_array_elements(public.generate_classes(:'dom', :'mod', array['2027-02-07']::date[], 'Main cohort') -> 0 -> 'classes') x),
  '2027-02-07,2027-02-11', 'the main cohort keeps the module default: Sunday and Thursday');
select tests.make_week(:'mod', '2027-02-27', 'Mixed') as mw_mix_seed \gset
insert into public.class_pattern_item (module_id, cohort_id, class_type, title_template, day_offset, start_time_pt, duration_minutes, sort_order)
values (:'mod', (select cohort_id from public.module_week where id = :'mw_mix_seed'), 'Live class', '{module}: Saturday live', 0, '10:00', 180, 1),
       (:'mod', (select cohort_id from public.module_week where id = :'mw_mix_seed'), 'Assignment review', '{module}: Tuesday review', 3, '18:00', 60, 2);
select is((select string_agg(to_char((x ->> 'date')::date, 'Dy'), ',' order by x ->> 'date')
             from jsonb_array_elements(public.generate_classes(:'dom', :'mod', array['2027-03-13']::date[], 'Mixed') -> 0 -> 'classes') x),
  'Sat,Tue', 'a mixed cohort: a weekend class and a weekday class in one class week');

-- A module without class times cannot be planned.
insert into public.module (domain_id, name, rotation_order) values (:'dom', 'No times yet', 9) returning id as mod_empty \gset
select ok((public.generate_classes(:'dom', :'mod_empty', array['2027-02-07']::date[], 'Main cohort') -> 0 ->> 'problem') like '%has no class times yet%',
  'planning shows why a module without class times cannot be planned');
select throws_ok(format($$ select public.create_module_weeks(%L, jsonb_build_array(jsonb_build_object('module_id', %L, 'cohort', 'Main cohort', 'classes', '[]'::jsonb))) $$,
  :'dom', :'mod_empty'), '23505', null, 'and saving it is blocked');

-- =============================================================== moving a confirmed class to another weekday
select public.change_class_time((select id from public.class_session where module_week_id = :'mw' and class_type = 'Live class'),
  '2027-02-03', '09:00', '13:00');
select ok(exists (select 1 from public.request where module_week_id = :'mw' and kind = 'TimeChange'),
  'a confirmed class moved from Sunday to Wednesday asks the instructor to confirm the new time');
select is((select week_start_date from public.module_week where id = :'mw'), '2027-02-03'::date,
  'the class week now starts on its first class (Wednesday)');

-- =============================================================== Add one class
select (public.add_one_class(null, :'mod', :'coh_b', '2027-02-20', '10:00', '11:00', 'Office hours', 'Extra help') ->> 'new_class_week')::boolean as v \gset
select ok(:'v'::boolean, 'a one off class can be its own class week in a cohort');
select public.add_one_class(:'mw', null, null, '2027-02-05', '10:00', '11:00', 'Office hours');
select is((select count(*)::int from public.booking_slot s join public.booking b on b.id = s.booking_id
            where b.module_week_id = :'mw' and b.status = 'Active'), 3,
  'a class added to a confirmed class week is booked for the same instructor');
insert into public.holiday (date, name) values ('2027-03-03', 'Release test holiday') on conflict do nothing;
select is((public.add_one_class(null, :'mod', :'coh_b', '2027-03-03', '10:00', '11:00', 'Office hours') ->> 'needs_confirmation')::boolean, true,
  'a class on a holiday needs the warning to be accepted');
select is((public.add_one_class(null, :'mod', :'coh_b', '2027-03-04', '05:00', '06:00', 'Office hours') -> 'warnings' -> 0 ->> 'code'),
  'unusual_hours', 'a class before 6 AM Pacific is a warning');
select is((public.add_one_class(null, :'mod', :'coh_b', '2027-03-03', '10:00', '11:00', 'Office hours', null, true, 'Only day the room is free') ->> 'ok')::boolean,
  true, 'accepting the warning saves the class');
select is((select note from public.history_event where action = 'Warnings accepted' order by id desc limit 1), 'Only day the room is free',
  'the reason for accepting a warning goes into Activity history');
select is((public.create_module_weeks(:'dom', jsonb_build_array(jsonb_build_object('module_id', :'mod', 'cohort', 'Weekday',
  'classes', jsonb_build_array(jsonb_build_object('class_type', 'Live class', 'title', 'Clash', 'date', '2027-02-04',
                                                   'start_time', '18:30', 'end_time', '19:30'))))) -> 'warnings' -> 0 ->> 'code'),
  'cohort_overlap', 'overlapping classes in the same cohort are a warning, not a block');

-- =============================================================== same instructor for the whole class week
select tests.make_week(:'mod', '2027-03-07') as mw_s \gset
select public.set_week_same_instructor(:'mw_s', false, 'Different people for the live class and the review');
select is((select count(*)::int from public.module_week where split_group = :'mw_s'), 2,
  'turning "same instructor" off makes each class its own class week');
select is((select count(*)::int from public.class_session c join public.module_week w on w.id = c.module_week_id where w.split_group = :'mw_s'), 2,
  'with one class each');
-- Each class week counts from its own first class: Sunday's requests start 30 days before, Thursday's 4 days later.
select tests.tick(:'dom', '2027-02-10 18:00+00');
select is((select count(*)::int from public.request r join public.module_week w on w.id = r.module_week_id
            where w.split_group = :'mw_s' and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')), 2,
  'each class gets its own request');
select throws_ok(format('select public.set_week_same_instructor(%L, true)', :'mw_s'), '22023', null,
  'they can only be merged back while nobody is being asked');
select tests.make_module(:'dom', 'Split by default', 3) as mod_split \gset
update public.module set same_instructor_for_module_week = false where id = :'mod_split';
select is((public.create_module_weeks(:'dom', jsonb_build_array(jsonb_build_object('module_id', :'mod_split', 'cohort', 'Main cohort',
  'classes', public.generate_classes(:'dom', :'mod_split', array['2027-04-04']::date[], 'Main cohort') -> 0 -> 'classes')), true) ->> 'created')::int, 2,
  'planning a module with "same instructor" off creates one class week per class');

-- =============================================================== settings layers
select public.set_setting_at('Domain', :'dom', 'window_long_move_h', '60');
select public.set_setting_at('Cohort', :'coh_b', 'window_long_move_h', '70');
select public.set_setting_at('Module', :'mod', 'window_long_move_h', '80');
select public.set_setting_at('ModuleWeek', :'mw_b', 'window_long_move_h', '90', 'Instructor needs longer to decide');
select is(private.setting_int(:'mw_b', 'window_long_move_h'), 90, 'a single class week override wins');
select is((select x ->> 'source' from jsonb_array_elements(public.effective_settings_for('ModuleWeek', :'mw_b')) x where x ->> 'key' = 'window_long_move_h'),
  'ModuleWeek', 'and the app can show where the value comes from');
select is((private.window_hours(:'mw_b', '2026-12-01 18:00+00')).move_h, 90, 'the automation uses the class week value');
select public.reset_setting_at('ModuleWeek', :'mw_b', 'window_long_move_h');
select is(private.setting_int(:'mw_b', 'window_long_move_h'), 80, 'then the module value');
select public.reset_setting_at('Module', :'mod', 'window_long_move_h');
select is(private.setting_int(:'mw_b', 'window_long_move_h'), 70, 'then the cohort value');
select public.reset_setting_at('Cohort', :'coh_b', 'window_long_move_h');
select is(private.setting_int(:'mw_b', 'window_long_move_h'), 60, 'then the domain value');
select public.reset_setting_at('Domain', :'dom', 'window_long_move_h');
select is(private.setting_int(:'mw_b', 'window_long_move_h'), 48, 'then the default');

-- =============================================================== two people editing the same module
select (select version from public.module where id = :'mod') as ver \gset
select lives_ok(format('update public.module set name = %L, version = %s where id = %L', 'Concurrency RM renamed', :'ver', :'mod'),
  'the first person saves');
select throws_ok(format('update public.module set name = %L, version = %s where id = %L', 'Concurrency RM other', :'ver', :'mod'),
  '40001', null, 'the second person, who opened the old version, is told to reload');

-- =============================================================== instructor order: one Primary, then Backups
set constraints all immediate;
select throws_ok(format('insert into public.module_ranking (module_id, instructor_id, rank) values (%L, %L, 2)', :'mod_empty', :'i1'),
  '23514', null, 'an instructor order must start with a Primary instructor');
set constraints all deferred;
select public.save_ranking(:'mod', array[:'i3', :'i2']::uuid[], null, :'coh_b');
select is((select l.instructor_id from private.build_line(:'mw_b') l order by l.pos limit 1), :'i3'::uuid,
  'a cohort can have its own instructor order');
select is((select l.instructor_id from private.build_line(:'mw') l order by l.pos limit 1), :'i1'::uuid,
  'other cohorts keep the module order');

-- =============================================================== people: operations team and escalation contacts
select tests.make_team_member('Weekday Ops') as wops \gset
insert into public.module_operations (module_id, cohort_id, team_member_id) values (:'mod', :'coh_b', :'wops');
select is(private.ops_for_week(:'mw_b'), array[:'wops']::uuid[], 'a cohort can have its own operations team for a module');
select is(private.ops_for_week(:'mw'), array[:'ops']::uuid[], 'otherwise the domain default operations team is used');
select is(private.domain_role_ids(:'dom', 'Escalation'), array[:'lead']::uuid[], 'escalation contacts replace domain leads');
select ok((public.team_assignments() -> :'owner') ? ('Owner of Concurrency RM renamed (RM)'), 'Team shows where each person helps');

-- =============================================================== test instructors may share a Discord user ID
select tests.make_instructor('RM Tester One', true, true) as t1 \gset
select lives_ok(format('insert into public.instructor (full_name, primary_email, discord_user_id, is_test) select %L, %L, discord_user_id, true from public.instructor where id = %L',
  'RM Tester Two', 'me+two@example.org', :'t1'), 'one person can test as several test instructors with one Discord account');
select throws_ok(format('insert into public.instructor (full_name, primary_email, discord_user_id) select %L, %L, discord_user_id from public.instructor where id = %L',
  'RM Real Copy', 'real.copy@example.org', :'i1'), '23505', null, 'real instructors keep a unique Discord user ID');

select * from finish();
rollback;
