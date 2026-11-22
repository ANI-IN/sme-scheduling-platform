-- Release 3, M7b part 1 (decision 298): standard schedules, cohorts planned from them, Standard and Custom.
begin;
\ir ../helpers/helpers.psql
select plan(22);

select tests.scenario('ST', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2 \gset
select tests.make_module(:'dom', 'ST Two', 2) as m2 \gset
select tests.rank(:'m2', :'i1', :'i2');
select tests.scenario('SU', 'Live', '2027-01-31', 1) as k \gset
select (:'k'::jsonb ->> 'module') as other_mod \gset

-- =============================================================== 1. a standard schedule and its rules
select (public.save_standard_schedule(null, :'dom', 'SWEs | DEs', array[:'m1', :'m2']::uuid[],
        '[{"after_position": 1, "weeks": 1}]') ->> 'id') as sid \gset
select is((select string_agg(label, ' / ' order by position) from public.standard_schedule_module where schedule_id = :'sid'),
  'SWEs | DEs: 1. Concurrency ST / SWEs | DEs: 2. ST Two', '1. the module order is saved, with labels for Activity history');
select throws_like(format($$ select public.save_standard_schedule(null, %L, 'swes | des', array[%L]::uuid[]) $$, :'dom', :'m1'),
  'This domain already has a standard schedule named%', '2. two standards of one domain cannot share a name');
select throws_like(format($$ select public.save_standard_schedule(%L, null, 'SWEs | DEs', array[%L, %L]::uuid[], '[{"after_position": 2, "weeks": 1}]') $$,
  :'sid', :'m1', :'m2'), 'A break goes between two modules%', '3. a break goes between two modules');
select throws_like(format($$ select public.save_standard_schedule(%L, null, 'SWEs | DEs', array[%L]::uuid[]) $$, :'sid', :'other_mod'),
  'Only active modules of this domain%', '4. a module of another domain cannot be in it');
select throws_like(format($$ select public.save_standard_schedule(%L, null, 'SWEs | DEs', array[%L, %L]::uuid[]) $$, :'sid', :'m1', :'m1'),
  'Each module can be in a standard schedule once.', '5. each module once');
-- The standard's own class time for its second module; the first uses the module's own class times.
insert into public.standard_schedule_class (schedule_id, module_id, class_type, title_template, day_offset, start_time, duration_minutes)
values (:'sid', :'m2', 'Live class', '{module}: Live class', 0, '10:00', 120);
select is((select domain_id::text || ' ' || label from public.standard_schedule_class where schedule_id = :'sid'),
  :'dom' || ' SWEs | DEs: ST Two, Live class', '6. a class time of the standard belongs to its domain');

-- =============================================================== 2. the preview of several cohorts at once
select public.preview_standard_cohorts(:'sid',
  '[{"name": "ST A", "start_date": "2027-03-07", "region": "US"}, {"name": "ST B", "start_date": "2027-03-14", "region": "India"}]') as pv \gset
select is((select string_agg((c ->> 'name') || ' ' || (w ->> 'week_start_date') || ' ' || (w ->> 'standard_position'), ', ')
             from jsonb_array_elements(:'pv'::jsonb -> 'cohorts') c, jsonb_array_elements(c -> 'weeks') w),
  'ST A 2027-03-07 1, ST A 2027-03-21 2, ST B 2027-03-14 1, ST B 2027-03-28 2',
  '7. one week per module, and the break week moves the second module back a week');
select is((select string_agg(k ->> 'start_time', ',') from jsonb_array_elements(:'pv'::jsonb -> 'cohorts' -> 0 -> 'weeks' -> 1 -> 'classes') k),
  '10:00', '8. the second module uses the standard''s own class time');
select is((select string_agg(k ->> 'start_time', ',' order by k ->> 'date') from jsonb_array_elements(:'pv'::jsonb -> 'cohorts' -> 0 -> 'weeks' -> 0 -> 'classes') k),
  '09:00,18:00', '9. the first module uses the module''s own class times');
select is(jsonb_array_length(:'pv'::jsonb -> 'blocks'), 0, '10. nothing blocks this plan');
insert into public.cohort (domain_id, name, region) values (:'dom', 'ST Old', 'US');
select is((select string_agg(x #>> '{}', ' | ') from jsonb_array_elements(public.preview_standard_cohorts(:'sid',
  '[{"name": "ST Old", "start_date": "2027-03-07"}, {"name": "ST New", "start_date": "2027-03-07"}, {"name": "st new", "start_date": "2027-03-14"}]') -> 'blocks') x),
  'A cohort named ST Old already exists in this domain. | Two new cohorts are both named st new.',
  '11. a name in use, or used twice in one plan, blocks it');

-- =============================================================== 3. creating them
select public.create_standard_cohorts(:'sid',
  '[{"name": "ST A", "start_date": "2027-03-07", "region": "US"}, {"name": "ST B", "start_date": "2027-03-14", "region": "India"}]') as made \gset
select is((:'made'::jsonb ->> 'class_weeks')::int, 4, '12. both cohorts are created with their 4 class weeks');
select is((select string_agg(c.name || ' ' || c.region || ' ' || w.standard_position || ' ' || w.week_start_date, ', ' order by c.name, w.standard_position)
             from public.cohort c join public.module_week w on w.cohort_id = c.id where c.standard_schedule_id = :'sid'),
  'ST A US 1 2027-03-07, ST A US 2 2027-03-21, ST B India 1 2027-03-14, ST B India 2 2027-03-28',
  '13. each class week knows its place in the standard');
select is((select string_agg(to_char(k.starts_at at time zone 'Asia/Kolkata', 'Dy HH24:MI'), ',' order by k.starts_at)
             from public.class_session k join public.module_week w on w.id = k.module_week_id
             join public.cohort c on c.id = w.cohort_id where c.name = 'ST B' and w.standard_position = 2),
  'Sun 10:00', '14. an India cohort''s classes are at India time');
create or replace function tests.status(p_name text) returns text language sql as $$
  select x ->> 'mode' || ' ' || (x ->> 'changes') from jsonb_array_elements(public.cohort_schedule_status(
    (select domain_id from public.cohort where name = p_name))) x
   where x ->> 'cohort_id' = (select id::text from public.cohort where name = p_name);
$$;
select is(tests.status('ST A') || ' / ' || tests.status('ST B'), 'Standard 0 / Standard 0', '15. both follow the standard');

-- =============================================================== 4. one cohort changes; the other does not
select k.id as a_class from public.class_session k join public.module_week w on w.id = k.module_week_id
  join public.cohort c on c.id = w.cohort_id where c.name = 'ST A' and w.standard_position = 1 order by k.starts_at limit 1 \gset
select public.change_class_time(:'a_class', '2027-03-07', '11:00', '15:00');
select is(tests.status('ST A') || ' / ' || tests.status('ST B'), 'Custom 1 / Standard 0',
  '16. moving a class makes that cohort Custom (1 change) without touching the other cohort on the standard');
select is((select count(*)::int from public.module_week where customized_at is not null), 1, '17. only that class week is marked');
update public.class_session k set status = 'Completed' from public.module_week w, public.cohort c
 where w.id = k.module_week_id and c.id = w.cohort_id and c.name = 'ST B';
select is(tests.status('ST B'), 'Standard 0', '18. a class that took place is not a change');
select public.add_one_class(null, :'m1', (select id from public.cohort where name = 'ST B'), '2027-04-04', '09:00', '10:00', 'Live class',
  'Extra class', true, 'Test class: the time is chosen on purpose');
select is(tests.status('ST B'), 'Custom 1', '19. an extra class week outside the standard counts as a change');
select is(tests.status('ST Old'), 'Fully custom 0', '20. a cohort without a standard is fully custom');

-- =============================================================== 5. the Primary already teaches then
select w.id as a2 from public.module_week w join public.cohort c on c.id = w.cohort_id where c.name = 'ST A' and w.standard_position = 2 \gset
select tests.raw_book(:'a2', :'i1');
select ok(exists (select 1 from jsonb_array_elements(public.preview_standard_cohorts(:'sid',
  '[{"name": "ST C", "start_date": "2027-03-07"}]') -> 'warnings') x where x ->> 'code' = 'primary_busy' and x ->> 'level' = 'Information'),
  '21. the preview says when the Primary already teaches at that time');

select public.archive_standard_schedule(:'sid', true);
select throws_like(format($$ select public.preview_standard_cohorts(%L, '[{"name": "ST D", "start_date": "2027-03-07"}]') $$, :'sid'),
  'This standard schedule is archived%', '22. an archived standard cannot be used for new cohorts');

select * from finish();
rollback;
