-- Core readiness step 6: several cohorts at once, with US and India classes.
begin;
\ir ../helpers/helpers.psql
select plan(12);

select tests.scenario('CR', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset

-- Three cohorts running at the same time: a US weekend, a US weekday and an India weekday cohort.
select public.create_module_weeks(:'dom', jsonb_build_array(
  jsonb_build_object('module_id', :'mod', 'cohort', 'CR US weekend', 'region', 'US',
    'classes', jsonb_build_array(jsonb_build_object('date', '2027-03-06', 'start_time', '09:00', 'end_time', '13:00', 'title', 'CR US weekend class'))),
  jsonb_build_object('module_id', :'mod', 'cohort', 'CR US weekday', 'region', 'US',
    'classes', jsonb_build_array(jsonb_build_object('date', '2027-03-09', 'start_time', '18:00', 'end_time', '20:00', 'title', 'CR US weekday class'))),
  jsonb_build_object('module_id', :'mod', 'cohort', 'CR India weekday', 'region', 'India',
    'classes', jsonb_build_array(jsonb_build_object('date', '2027-03-09', 'start_time', '19:30', 'end_time', '21:30', 'title', 'CR India weekday class')))),
  true);
select is((select count(*)::int from public.cohort where domain_id = :'dom' and name like 'CR %'), 3,
  'cohorts 1. three cohorts of one domain run at the same time');
select is((select string_agg(name || ' ' || region, ', ' order by name) from public.cohort where domain_id = :'dom' and name like 'CR %'),
  'CR India weekday India, CR US weekday US, CR US weekend US', 'cohorts 2. each cohort keeps its own region');
select is((select count(distinct module_week_id)::int from public.class_session where title like 'CR % class'), 3,
  'cohorts 3. the same module in the same week gives one class week per cohort');
select is((select to_char(starts_at at time zone 'UTC', 'Dy HH24:MI') from public.class_session where title = 'CR US weekend class'),
  'Sat 17:00', 'cohorts 4. a US class at 9:00 AM Pacific is 17:00 UTC');
select is((select to_char(starts_at at time zone 'UTC', 'Dy HH24:MI') from public.class_session where title = 'CR India weekday class'),
  'Tue 14:00', 'cohorts 5. an India class at 7:30 PM India time is 14:00 UTC');
select is((select string_agg(region, ',' order by title) from public.class_session where title like 'CR % class'),
  'India,US,US', 'cohorts 6. every class carries the region of its cohort');
select ok(private.class_lines((select module_week_id from public.class_session where title = 'CR India weekday class')) like '%IST%',
  'cohorts 7. messages about the India class show India time');

-- One instructor can teach both weekday cohorts: 6:00 PM Pacific and 7:30 PM India time never overlap.
select tests.raw_book((select module_week_id from public.class_session where title = 'CR US weekday class'), :'i1') as b1 \gset
select lives_ok(format($$ select tests.raw_book(%L, %L) $$,
  (select module_week_id from public.class_session where title = 'CR India weekday class'), :'i1'),
  'cohorts 8. the same instructor can be booked for a US and an India class that do not overlap');

-- Each cohort can have its own instructor order.
insert into public.module_ranking (module_id, cohort_id, instructor_id, rank)
select :'mod', id, :'i2', 1 from public.cohort where name = 'CR India weekday';
select is((select count(*)::int from public.module_ranking where cohort_id is not null and module_id = :'mod'), 1,
  'cohorts 9. the India cohort has its own instructor order');

-- Archiving one cohort stops only its classes.
select id as india from public.cohort where name = 'CR India weekday' \gset
select public.set_archived('cohort', :'india', true);
select is((select string_agg(c.name || '=' || w.paused, ', ' order by c.name) from public.module_week w join public.cohort c on c.id = w.cohort_id
            where c.name like 'CR %'), 'CR India weekday=true, CR US weekday=false, CR US weekend=false',
  'cohorts 10. archiving the India cohort pauses only its class week');
select public.set_archived('cohort', :'india', false);
-- Deleting one cohort leaves the others.
select public.delete_item('cohort', (select id::text from public.cohort where name = 'CR US weekend'), 'CR US weekend');
select is((select string_agg(name, ', ' order by name) from public.cohort where domain_id = :'dom' and name like 'CR %'),
  'CR India weekday, CR US weekday', 'cohorts 11. deleting one cohort leaves the other two');
select is((select count(*)::int from public.class_session where title like 'CR % class'), 2,
  'cohorts 12. and their classes');

select * from finish();
rollback;
