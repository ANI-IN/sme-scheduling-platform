-- Release 3 review: previews in date order, earliest first, and the checks of a plan before it is saved.
begin;
\ir ../helpers/helpers.psql
select plan(10);

select tests.scenario('DO', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.make_module(:'dom', 'DO Two', 2) as m2 \gset
select tests.make_module(:'dom', 'DO Three', 3) as m3 \gset
select (public.save_standard_schedule(null, :'dom', 'DO track', array[:'m1', :'m2', :'m3']::uuid[]) ->> 'id') as sid \gset
select public.create_standard_cohorts(:'sid', '[{"name": "DO A", "start_date": "2027-03-07"}, {"name": "DO B", "start_date": "2027-03-07"},
  {"name": "DO C", "start_date": "2027-03-07"}]', true, 'Three cohorts on purpose at the same times');
select id as ca from public.cohort where name = 'DO A' \gset
create or replace function tests.wk(p_cohort text, p_pos int) returns uuid language sql as $$
  select w.id from public.module_week w join public.cohort c on c.id = w.cohort_id where c.name = p_cohort and w.standard_position = p_pos;
$$;
-- Each class week has a Live class on Sunday and an Assignment review on Thursday.

-- =============================================================== Add a break
select public.add_break(:'dom', array[:'ca']::uuid[], '2027-03-07', 1, 'Spring break') as pv \gset
select is((select string_agg(w ->> 'from', ',') from jsonb_array_elements(:'pv'::jsonb -> 'cohorts' -> 0 -> 'weeks') w),
  '2027-03-07,2027-03-14,2027-03-21', '1. the class weeks that move are in date order, earliest first');
select is((select string_agg(k ->> 'title', ' | ') from jsonb_array_elements(:'pv'::jsonb -> 'cohorts' -> 0 -> 'weeks' -> 0 -> 'classes') k),
  'Concurrency DO: Live class | Concurrency DO: Assignment review', '2. and the classes of each class week too');

-- =============================================================== Reset to standard, chosen in another order
select public.change_class_time((select id from public.class_session where module_week_id = tests.wk('DO A', n) and class_type = 'Live class'),
  '2027-03-07'::date + 7 * (n - 1), '11:00'::time, '15:00'::time)
  from generate_series(1, 3) n;
select public.reset_to_standard(array[tests.wk('DO A', 3), tests.wk('DO A', 1), tests.wk('DO A', 2)]) as rs \gset
select is((select string_agg(c ->> 'module_week_id', ',') from jsonb_array_elements(:'rs'::jsonb -> 'changes') c),
  concat_ws(',', tests.wk('DO A', 1), tests.wk('DO A', 2), tests.wk('DO A', 3)), '3. Reset to standard lists the class weeks in date order');

-- =============================================================== Update cohorts from the standard
insert into public.standard_schedule_class (schedule_id, module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
select :'sid', m, 'Live class', '{module}: Live class', 0, '10:00', 240, 1 from unnest(array[:'m1', :'m2', :'m3']::uuid[]) m;
select public.apply_standard(:'sid') as ap \gset
select is((select count(*)::int from jsonb_array_elements(:'ap'::jsonb -> 'changes')), 6, '4. both cohorts that follow the standard change');
select ok((select bool_and(d >= coalesce(p, d)) from (
             select w.first_class_at d, lag(w.first_class_at) over (order by c.n) p
               from jsonb_array_elements(:'ap'::jsonb -> 'changes') with ordinality c (x, n)
               join public.module_week w on w.id = (c.x ->> 'module_week_id')::uuid) t),
  '5. Update cohorts lists every cohort''s class weeks together, in date order');

-- =============================================================== A proposed time
insert into public.request (module_week_id, instructor_id, kind, status, time_version, sent_at)
values (tests.wk('DO B', 1), :'i1', 'Outreach', 'Sent', (select time_version from public.module_week where id = tests.wk('DO B', 1)), now())
returning id as rq \gset
insert into public.time_proposal (request_id, module_week_id, domain_id, instructor_id, proposed, time_version)
select :'rq', w.id, w.domain_id, :'i1', jsonb_agg(jsonb_build_object('class_id', k.id, 'title', k.title, 'from', '', 'to', '',
         'starts_at', k.starts_at + interval '1 hour', 'ends_at', k.ends_at + interval '1 hour', 'changed', true) order by k.starts_at desc),
       w.time_version
  from public.module_week w join public.class_session k on k.module_week_id = w.id
 where w.id = tests.wk('DO B', 1) group by w.id
returning id as tp \gset
select is((select string_agg(x ->> 'title', ' | ') from jsonb_array_elements(public.time_proposal_preview(:'tp') -> 'proposed') x),
  'Concurrency DO: Live class | Concurrency DO: Assignment review', '6. a proposed time lists its classes in time order');

-- =============================================================== The checks of a plan before it is saved
insert into public.holiday (date, name, domain_id) values ('2027-05-02', 'DO holiday', :'dom');
select count(*) as before from public.module_week \gset
select public.check_plan(:'dom', jsonb_build_array(
  jsonb_build_object('module_id', :'m1', 'cohort', 'DO New', 'region', 'US', 'classes', jsonb_build_array(
    jsonb_build_object('class_type', 'Live class', 'title', 'DO plan 1', 'date', '2027-05-02', 'start_time', '09:00', 'end_time', '10:00'))),
  jsonb_build_object('module_id', :'m1', 'cohort', 'DO New', 'region', 'US', 'classes', jsonb_build_array(
    jsonb_build_object('class_type', 'Live class', 'title', 'DO plan 2', 'date', '2027-05-09', 'start_time', '09:00', 'end_time', '09:00'))),
  jsonb_build_object('module_id', :'m1', 'cohort', 'DO New', 'region', 'US', 'classes', jsonb_build_array(
    jsonb_build_object('class_type', 'Live class', 'title', 'DO plan 3', 'date', '2027-05-16', 'start_time', '09:00', 'end_time', '10:00')))
  )) as ck \gset
select is(jsonb_array_length(:'ck'::jsonb -> 'rows'), 3, '7. one result for each class week of the plan');
select ok(exists (select 1 from jsonb_array_elements(:'ck'::jsonb -> 'rows' -> 0 -> 'warnings') x where x ->> 'code' = 'holiday'),
  '8. a class on a holiday is a warning');
select ok((:'ck'::jsonb -> 'rows' -> 1 -> 'blocks')::text like '%must end after it starts%', '9. a class that ends when it starts is a block');
select is((select count(*) from public.module_week) || ' ' || (select count(*) from public.cohort where name = 'DO New'),
  :'before' || ' 0', '10. nothing is saved, not even the new cohort');

select * from finish();
rollback;
