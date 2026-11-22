-- Release 3, M8 (decision 301): cohort breaks, program breaks and cohort holidays.
begin;
\ir ../helpers/helpers.psql
select plan(30);

select tests.scenario('BR', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select tests.make_module(:'dom', 'BR Two', 2) as m2 \gset
select tests.rank(:'m2', :'i1', :'i2', :'i3');
select tests.make_module(:'dom', 'BR Three', 3) as m3 \gset
select tests.rank(:'m3', :'i1', :'i2', :'i3');
select (public.save_standard_schedule(null, :'dom', 'BR track', array[:'m1', :'m2', :'m3']::uuid[]) ->> 'id') as sid \gset
select public.create_standard_cohorts(:'sid', '[{"name": "BR A", "start_date": "2027-03-07"}, {"name": "BR B", "start_date": "2027-03-07"}]',
  true, 'Two cohorts on purpose at the same times');
select id as ca from public.cohort where name = 'BR A' \gset
select id as cb from public.cohort where name = 'BR B' \gset

create or replace function tests.wk(p_cohort text, p_pos int) returns uuid language sql as $$
  select w.id from public.module_week w join public.cohort c on c.id = w.cohort_id where c.name = p_cohort and w.standard_position = p_pos;
$$;
create or replace function tests.starts(p_cohort text) returns text language sql as $$
  select string_agg(w.week_start_date::text, ',' order by w.standard_position) from public.module_week w
    join public.cohort c on c.id = w.cohort_id where c.name = p_cohort and w.standard_position is not null;
$$;

-- BR A: the first and third class weeks are taught by Instr3, the second by Instr1. Instr1 also teaches another
-- cohort on Sun, Mar 21 at 9:00, where BR A's second class week lands after a one week break.
select public.assign_manually(tests.wk('BR A', 1), :'i3');
select public.assign_manually(tests.wk('BR A', 2), :'i1');
select public.assign_manually(tests.wk('BR A', 3), :'i3');
insert into public.cohort (domain_id, name, region) values (:'dom', 'BR Other', 'US') returning id as co \gset
select (public.add_one_class(null, :'m1', :'co', '2027-03-21', '09:00', '13:00', 'Live class', null, true, 'Test class: the time is chosen on purpose')
        ->> 'module_week_id') as ow \gset
select tests.raw_book(:'ow', :'i1');

-- =============================================================== 1. the preview
select public.add_break(:'dom', array[:'ca']::uuid[], '2027-03-07', 1, 'Spring break') as pv \gset
select is((select string_agg((w ->> 'from') || '>' || (w ->> 'to'), ',' order by w ->> 'from')
             from jsonb_array_elements(:'pv'::jsonb -> 'cohorts' -> 0 -> 'weeks') w),
  '2027-03-07>2027-03-14,2027-03-14>2027-03-21,2027-03-21>2027-03-28', '1. every class week from the first day moves back by the break');
select ok(exists (select 1 from jsonb_array_elements(:'pv'::jsonb -> 'cohorts' -> 0 -> 'weeks') w, jsonb_array_elements(w -> 'classes') k
                   where k ->> 'from' like 'Sun, Mar 7 · 9:00 AM%' and k ->> 'to' like 'Sun, Mar 14 · 9:00 AM%'),
  '2. each class keeps its clock time, shown before and after');
select is((:'pv'::jsonb ->> 'confirmed_instructors')::int, 2, '3. the instructors affected are counted');
select ok(exists (select 1 from jsonb_array_elements(:'pv'::jsonb -> 'blocks') b
                   where b ->> 'code' = 'clash' and b ->> 'module_week_id' = tests.wk('BR A', 2)::text and b -> 'fixes' ? 'ask_next'),
  '4. the clash the move creates for Instr1 blocks, with its fixes');
select is(tests.starts('BR A') || ' ' || (select count(*) from public.cohort_break)::text, '2027-03-07,2027-03-14,2027-03-21 0',
  '5. the preview saves nothing');

-- =============================================================== 2. saving
select is((public.add_break(:'dom', array[:'ca']::uuid[], '2027-03-07', 1, 'Spring break', false, true) ->> 'ok')::boolean, false,
  '6. saving past a Block is refused');
select is((public.add_break(:'dom', array[:'ca']::uuid[], '2027-03-07', 1, 'Spring break', false, true, true, 'Agreed with the team',
           array[tests.wk('BR A', 2)]) ->> 'saved')::int, 3, '7. releasing Instr1 for that class week lets it save');
select is(tests.starts('BR A'), '2027-03-14,2027-03-21,2027-03-28', '8. the class weeks moved');
select is((select to_char(k.starts_at at time zone 'America/Los_Angeles', 'Dy Mon DD HH24:MI') from public.class_session k
            where k.module_week_id = tests.wk('BR A', 1) and k.class_type = 'Live class'), 'Sun Mar 14 09:00', '9. at the same clock time');
select alike((select label || ' / ' || status from public.cohort_break where cohort_id = :'ca'),
  'BR A: break, Spring break, Sun, Mar 7 to Sat, Mar 13 (1 week) / Active', '10. the break is kept, with a label for Activity history');
select is(coalesce(tests.booked(tests.wk('BR A', 2)), 'nobody') || ' ' || (tests.msgs(tests.wk('BR A', 2), 'M16') > 0)::text, 'nobody true',
  '11. Instr1 is released with the release note');
select is(tests.starts('BR B'), '2027-03-07,2027-03-14,2027-03-21', '12. the other cohort is not touched');

-- =============================================================== 3. one message per confirmed instructor
select is((select count(*)::int from public.message where instructor_id = :'i3' and template_id = 'M17' and channel = 'Email'), 1,
  '13. Instr3 gets one message for both moved class weeks');
select alike((select (jsonb_array_length(buttons))::text || ' ' || (buttons -> 0 ->> 'label') from public.message
               where instructor_id = :'i3' and template_id = 'M17' and channel = 'Email'),
  '6 % Still works: Concurrency BR, Mar 14', '14. with Still works, Doesn''t work and Propose another time for each class week');
select is((select count(*)::int from public.request where instructor_id = :'i3' and kind = 'TimeChange' and status = 'Sent'), 2,
  '15. each class week has its own time change request');
select alike((select body_text from public.message where instructor_id = :'i3' and template_id = 'M17' and channel = 'Email'),
  '%Your classes moved to new dates for a break (Spring break, Sun, Mar 7 to Sat, Mar 13 (1 week)):%BR Three%',
  '16. the message says why and lists every class week');
select is(tests.msgs(tests.wk('BR A', 1), 'M5') + tests.msgs(tests.wk('BR A', 3), 'M5'), 0, '17. no separate time change message per class week');
select tests.click(tests.wk('BR A', 1), :'i3', 'StillWorks');
select is((select b.time_version_confirmed = w.time_version from public.booking b join public.module_week w on w.id = b.module_week_id
            where b.module_week_id = tests.wk('BR A', 1) and b.status = 'Active'), true, '18. Still works for one class week confirms that week');
select private.step_time_changes(:'dom', now());
select is(tests.msgs(tests.wk('BR A', 3), 'M5'), 0, '19. the hourly run does not ask again about the other class week');

-- =============================================================== 4. the rules
select ok(exists (select 1 from jsonb_array_elements(public.add_break(:'dom', array[:'ca']::uuid[], '2027-03-10', 1, 'Exams') -> 'blocks') b
                   where b #>> '{}' like 'It overlaps the break Spring break%'), '20. two breaks of one cohort cannot overlap');
select ok(exists (select 1 from jsonb_array_elements(public.add_break(:'dom', array[:'cb']::uuid[], '2026-01-04', 1, 'Old') -> 'blocks') b
                   where b #>> '{}' = 'A break can''t start in the past.'), '21. a break cannot start in the past');
select ok(exists (select 1 from jsonb_array_elements(public.add_break(:'dom', array[:'cb']::uuid[], '2027-03-10', 1, 'Midweek') -> 'blocks') b
                   where b #>> '{}' like '%starts before the break and has classes inside it.%'),
  '22. a class week with classes on both sides of the first day blocks');

-- =============================================================== 5. a later break moves with its classes; removing a break
select public.add_break(:'dom', array[:'ca']::uuid[], '2027-03-21', 1, 'Exams', false, true, true, 'Agreed with the team');
select public.remove_break((select id from public.cohort_break where reason = 'Spring break'), null, true, true, 'Back to the plan');
select is(tests.starts('BR A') || ' ' || (select starts_on::text from public.cohort_break where reason = 'Exams' and status = 'Active')
            || ' ' || (select status from public.cohort_break where reason = 'Spring break'),
  '2027-03-07,2027-03-21,2027-03-28 2027-03-14 Removed', '23. removing a break moves the classes back, and the later break with them');
select ok(exists (select 1 from public.history_event where action = 'Break added: Spring break')
          and exists (select 1 from public.history_event where action = 'Break removed: Spring break'), '24. Activity history has both');
select ok(exists (select 1 from jsonb_array_elements(public.add_one_class(null, :'m3', :'ca', '2027-03-16', '10:00', '11:00', 'Live class', null)
                                                       -> 'warnings') x where x ->> 'code' = 'in_break'),
  '25. planning a class inside a break warns');

-- =============================================================== 6. a program break
select (public.add_break(:'dom', null, '2027-05-02', 1, 'Program week off', true, true) ->> 'program_break_id') as pb \gset
select is((select count(*)::int from public.cohort_break where program_break_id = :'pb' and status = 'Active'),
  (select count(*)::int from public.cohort where domain_id = :'dom' and archived_at is null), '26. a program break is one break for every cohort');
select public.remove_break(null, :'pb', true);
select is((select string_agg(distinct status, ',') from public.cohort_break where program_break_id = :'pb')
            || ' ' || (select status from public.program_break where id = :'pb'), 'Removed Removed', '27. and is removed as one');

-- =============================================================== 7. cohort holidays
select public.add_cohort_holiday(:'cb', '2027-03-11', 'Founders day') as hol \gset
select is((select string_agg(k ->> 'title', ',') from jsonb_array_elements(:'hol'::jsonb -> 'classes') k), 'Concurrency BR: Assignment review',
  '28. adding a cohort holiday lists the classes on it');
select ok(exists (select 1 from jsonb_array_elements(private.week_problems(tests.wk('BR B', 1))) x
                   where x ->> 'code' = 'cohort_holiday' and x ->> 'level' = 'Warning' and x -> 'fixes' ? 'keep_with_reason'),
  '29. the class is a problem to fix: move, cancel, or keep with a reason');
select public.keep_class_on_holiday((select id from public.class_session where module_week_id = tests.wk('BR B', 1)
  and class_type = 'Assignment review'), 'The review is fixed by the client');
select alike((select x ->> 'level' || ' ' || (x ->> 'text') from jsonb_array_elements(private.week_problems(tests.wk('BR B', 1))) x
               where x ->> 'code' = 'cohort_holiday'), 'Information % Kept: The review is fixed by the client.',
  '30. kept with a reason, it is information');

select * from finish();
rollback;
