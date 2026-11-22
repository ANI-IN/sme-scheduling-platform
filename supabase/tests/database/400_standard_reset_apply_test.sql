-- Release 3, M7b part 2 (decision 299): Reset to standard, and updating cohorts when their standard changes.
begin;
\ir ../helpers/helpers.psql
select plan(20);

select tests.scenario('SR', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select tests.make_module(:'dom', 'SR Two', 2) as m2 \gset
select tests.rank(:'m2', :'i1', :'i2');
select tests.make_module(:'dom', 'SR Three', 3) as m3 \gset
select tests.rank(:'m3', :'i1', :'i2');
select (public.save_standard_schedule(null, :'dom', 'SR track', array[:'m1', :'m2']::uuid[]) ->> 'id') as sid \gset
select public.create_standard_cohorts(:'sid', '[{"name": "SR A", "start_date": "2027-03-07"}, {"name": "SR B", "start_date": "2027-03-07"},
  {"name": "SR C", "start_date": "2027-03-07"}]', true, 'Three cohorts on purpose at the same times');

create or replace function tests.wk(p_cohort text, p_pos int) returns uuid language sql as $$
  select w.id from public.module_week w join public.cohort c on c.id = w.cohort_id where c.name = p_cohort and w.standard_position = p_pos;
$$;
create or replace function tests.live(p_cohort text, p_pos int) returns text language sql as $$
  select to_char(k.starts_at at time zone 'America/Los_Angeles', 'HH24:MI') from public.class_session k
   where k.module_week_id = tests.wk(p_cohort, p_pos) and k.status = 'Planned' and k.class_type = 'Live class';
$$;
create or replace function tests.status(p_name text) returns text language sql as $$
  select x ->> 'mode' || ' ' || (x ->> 'changes') from jsonb_array_elements(public.cohort_schedule_status(
    (select domain_id from public.cohort where name = p_name))) x
   where x ->> 'cohort_id' = (select id::text from public.cohort where name = p_name);
$$;

-- SR A changes its own first class; SR C has a confirmed instructor; someone is being asked for SR B.
select public.change_class_time((select id from public.class_session where module_week_id = tests.wk('SR A', 1) and class_type = 'Live class'),
  '2027-03-07', '11:00', '15:00');
select public.assign_manually(tests.wk('SR C', 1), :'i1');
insert into public.request (module_week_id, instructor_id, kind, status, time_version) values (tests.wk('SR B', 1), :'i2', 'Outreach', 'Sent', 1);
-- A fully custom cohort where the person being asked for SR B already teaches at 10:00.
insert into public.cohort (domain_id, name, region) values (:'dom', 'SR Free', 'US') returning id as free \gset
select (public.add_one_class(null, :'m3', :'free', '2027-03-07', '10:00', '11:00', 'Live class', null, true, 'Test class: the time is chosen on purpose')
        ->> 'module_week_id') as fw \gset
select tests.raw_book(:'fw', :'i2');

-- =============================================================== 1. the standard changes: its live class moves to 10:00
insert into public.standard_schedule_class (schedule_id, module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
values (:'sid', :'m1', 'Live class', '{module}: Live class', 0, '10:00', 240, 1),
       (:'sid', :'m1', 'Assignment review', '{module}: Assignment review', 4, '18:00', 120, 2);
select public.apply_standard(:'sid') as pv \gset
select is((select string_agg(c ->> 'label', ' | ') from jsonb_array_elements(:'pv'::jsonb -> 'changes') c),
  private.mw_label(tests.wk('SR B', 1)), '1. only the class week that follows the standard and has no instructor is updated');
select alike((select x ->> 'reason' from jsonb_array_elements(:'pv'::jsonb -> 'not_updated') x where x ->> 'module_week_id' = tests.wk('SR A', 1)::text),
  'Changed for this cohort on %. Use Reset to standard on the class week to bring it back.', '2. a customized week is not updated, with the reason');
select is((select x ->> 'reason' from jsonb_array_elements(:'pv'::jsonb -> 'not_updated') x where x ->> 'module_week_id' = tests.wk('SR C', 1)::text),
  'An instructor is confirmed. Change the time on the class week, so they are asked about the new time.',
  '3. a confirmed week is not updated, with the reason');
select alike((select string_agg(a #>> '{}', ' ') from jsonb_array_elements(:'pv'::jsonb -> 'changes') c, jsonb_array_elements(c -> 'actions') a),
  'Move Concurrency SR: Live class from Sun, Mar 7 · 9:00 AM%to Sun, Mar 7 · 10:00 AM%', '4. the preview says what moves');
select ok(exists (select 1 from jsonb_array_elements(:'pv'::jsonb -> 'warnings') x where x ->> 'code' = 'asked_clash' and x ->> 'level' = 'Warning'),
  '5. the clash it would create for the person being asked is shown before saving');
select is((public.apply_standard(:'sid', null, true) ->> 'needs_confirmation')::boolean, true, '6. saving past it needs a decision');
select is(tests.live('SR B', 1), '09:00', '7. nothing moved yet');
select is((public.apply_standard(:'sid', null, true, true, 'They can change the other class') ->> 'saved')::int, 1, '8. with a reason it is saved');
select is(tests.live('SR A', 1) || ' ' || tests.live('SR B', 1) || ' ' || tests.live('SR C', 1), '11:00 10:00 09:00',
  '9. SR B moved; the customized and the confirmed weeks did not');
select is(tests.status('SR B'), 'Standard 0', '10. following the standard is not a change of the cohort''s own');
select ok(exists (select 1 from public.history_event where action = 'Standard applied: SR track'), '11. Activity history has it');

-- =============================================================== 2. Reset to standard
select public.reset_to_standard(array[tests.wk('SR A', 1)], null, true);
select is(tests.live('SR A', 1) || ' ' || tests.status('SR A'), '10:00 Standard 0', '12. one class week back to the standard, and the cohort is Standard again');
select time_version as tv_before from public.module_week where id = tests.wk('SR C', 1) \gset
select is((public.reset_to_standard(null, (select id from public.cohort where name = 'SR C'), true) ->> 'saved')::int, 1,
  '13. a whole cohort can be reset');
select is(tests.live('SR C', 1) || ' ' || tests.booked(tests.wk('SR C', 1)), '10:00 SR Instr1',
  '14. a confirmed week moves through the time change flow and keeps its instructor');
select ok((select time_version from public.module_week where id = tests.wk('SR C', 1)) > :tv_before, '15. the instructor is asked about the new time');

select public.assign_manually(tests.wk('SR C', 2), :'i2');
insert into public.standard_schedule_class (schedule_id, module_id, class_type, title_template, day_offset, start_time, duration_minutes)
values (:'sid', :'m2', 'Live class', '{module}: Live class', 0, '09:00', 240);
select is((select x ->> 'reason' from jsonb_array_elements(public.reset_to_standard(array[tests.wk('SR C', 2)]) -> 'not_updated') x),
  'The standard has a different number of classes and an instructor is confirmed. Add or cancel the class on the class week itself.',
  '16. a confirmed week never gains or loses a class through a reset');
select alike((select string_agg(a #>> '{}', ' ') from jsonb_array_elements(public.reset_to_standard(array[tests.wk('SR B', 2)]) -> 'changes') c,
            jsonb_array_elements(c -> 'actions') a),
  'Cancel SR Two: Assignment review (Thu, Mar 18%).',
  '17. without an instructor, a class the standard no longer has is cancelled');

-- =============================================================== 3. a module added to the standard, and cohorts left alone
select public.save_standard_schedule(:'sid', null, 'SR track', array[:'m1', :'m2', :'m3']::uuid[]);
select is((select count(*)::int from jsonb_array_elements(public.apply_standard(:'sid') -> 'new_class_weeks')), 3,
  '18. each cohort gets the new module''s class week');
select public.apply_standard(:'sid', null, true, true, 'New module for the track');
select is((select string_agg(c.name, ',' order by c.name) from public.module_week w join public.cohort c on c.id = w.cohort_id
            where w.standard_position = 3 and w.module_id = :'m3'), 'SR A,SR B,SR C', '19. it is created for the cohorts on the standard');
select is((select count(*)::int from public.module_week where cohort_id = :'free'), 1, '20. a fully custom cohort is never touched');

select * from finish();
rollback;
