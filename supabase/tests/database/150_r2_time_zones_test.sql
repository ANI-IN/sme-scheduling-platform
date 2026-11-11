-- Release 2: US and India time zones. Classes are stored in UTC and planned in their region:
-- US = America/Los_Angeles (PST or PDT), India = Asia/Kolkata (IST, no daylight saving).
-- US clocks move forward on Sun Mar 14, 2027 and back on Sun Nov 7, 2027.
begin;
\ir ../helpers/helpers.psql
select plan(29);

select tests.scenario('TZ', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'i1') as i1 \gset
insert into public.cohort (domain_id, name, region) values (:'dom', 'TZ US', 'US') returning id as us \gset
insert into public.cohort (domain_id, name, region) values (:'dom', 'TZ India', 'India') returning id as ind \gset

create or replace function tests.add(p_mod uuid, p_coh uuid, p_date date, p_start time, p_end time, p_region text default null, p_fold int default null)
returns jsonb language sql as $$
  select public.add_one_class(null, p_mod, p_coh, p_date, p_start, p_end, 'Live class', null, true, null, p_region, p_fold);
$$;
create or replace function tests.cls(p jsonb) returns public.class_session language sql as $$
  select * from public.class_session where id = (p ->> 'class_id')::uuid;
$$;

-- =============================================================== 1 to 4: US classes across the 2027 clock changes
select is((tests.cls(tests.add(:'mod', :'us', '2027-03-07', '09:00', '13:00'))).starts_at, '2027-03-07 17:00+00'::timestamptz,
  '1. Sun Mar 7, 9:00 AM PST is 17:00 UTC');
select is((tests.cls(tests.add(:'mod', :'us', '2027-03-14', '09:00', '13:00'))).starts_at, '2027-03-14 16:00+00'::timestamptz,
  '2. Sun Mar 14, 9:00 AM PDT is 16:00 UTC: the class stays at 9:00 AM after the clocks move forward');
select is((tests.cls(tests.add(:'mod', :'us', '2027-10-31', '09:00', '13:00'))).starts_at, '2027-10-31 16:00+00'::timestamptz,
  '3. Sun Oct 31, 9:00 AM PDT is 16:00 UTC');
select is((tests.cls(tests.add(:'mod', :'us', '2027-11-07', '09:00', '13:00'))).starts_at, '2027-11-07 17:00+00'::timestamptz,
  '4. Sun Nov 7, 9:00 AM PST is 17:00 UTC: the class stays at 9:00 AM after the clocks move back');

-- =============================================================== 5 to 6: India classes on the same dates (no daylight saving)
select is((tests.cls(tests.add(:'mod', :'ind', '2027-03-14', '09:00', '13:00'))).starts_at, '2027-03-14 03:30+00'::timestamptz,
  '5. India: Sun Mar 14, 9:00 AM IST is 03:30 UTC');
select is((tests.cls(tests.add(:'mod', :'ind', '2027-11-07', '09:00', '13:00'))).starts_at, '2027-11-07 03:30+00'::timestamptz,
  '6. India: Sun Nov 7, 9:00 AM IST is also 03:30 UTC');

-- =============================================================== 7: a time that does not exist
select throws_like($$ select tests.add((select id from public.module where name = 'Concurrency TZ'), (select id from public.cohort where name = 'TZ US'),
  '2027-03-14', '02:30', '03:30') $$, '%does not exist in US Pacific time%', '7. 2:30 AM on Mar 14, 2027 does not exist: it is refused with a clear message');
select lives_ok($$ select tests.add((select id from public.module where name = 'Concurrency TZ'), (select id from public.cohort where name = 'TZ India'),
  '2027-03-14', '02:30', '03:30') $$, '7. the same time in India is fine');

-- =============================================================== 8 to 9: a time that happens twice
select tests.add(:'mod', :'us', '2027-11-07', '01:30', '02:00') as amb \gset
select is((:'amb'::jsonb ->> 'needs_choice')::boolean, true, '8. 1:30 AM on Nov 7, 2027 happens twice: the app must ask which one');
select is(jsonb_array_length(:'amb'::jsonb -> 'warnings' -> 0 -> 'options'), 2, '8. two choices are offered');
select ok((:'amb'::jsonb -> 'warnings' -> 0 -> 'options' -> 0 ->> 'label') like '%PDT%'
      and (:'amb'::jsonb -> 'warnings' -> 0 -> 'options' -> 1 ->> 'label') like '%PST%', '8. the first is PDT, the second PST');
select is((tests.cls(tests.add(:'mod', :'us', '2027-11-07', '01:30', '02:00', null, 1))).starts_at, '2027-11-07 08:30+00'::timestamptz,
  '9. the first 1:30 AM (PDT) is 08:30 UTC');
select is((tests.cls(tests.add(:'mod', :'us', '2027-11-07', '01:30', '02:00', null, 2))).starts_at, '2027-11-07 09:30+00'::timestamptz,
  '9. the second 1:30 AM (PST) is 09:30 UTC');

-- =============================================================== 10: labels
select is(private.fmt_class_range('2027-01-24 17:00+00', '2027-01-24 21:00+00', 'US'), 'Sun, Jan 24 · 9:00 AM to 1:00 PM PST', '10. a US winter class shows PST');
select is(private.fmt_class_range('2027-07-04 16:00+00', '2027-07-04 20:00+00', 'US'), 'Sun, Jul 4 · 9:00 AM to 1:00 PM PDT', '10. a US summer class shows PDT');
select is(private.fmt_class_range('2027-01-24 03:30+00', '2027-01-24 07:30+00', 'India'), 'Sun, Jan 24 · 9:00 AM to 1:00 PM IST', '10. an India class shows IST');
select is(private.fmt_class_both('2027-01-24 03:30+00', '2027-01-24 05:30+00', 'US'),
  'Sat, Jan 23 · 7:30 PM to 9:30 PM PST (Sun, Jan 24 · 9:00 AM to 11:00 AM IST)', '10. the team sees both local times, even when the dates differ');

-- =============================================================== 11: a US cohort and an India cohort in the same week
select public.create_module_weeks(:'dom', jsonb_build_array(
  jsonb_build_object('module_id', :'mod', 'cohort', 'TZ Weekend US', 'region', 'US',
    'classes', jsonb_build_array(jsonb_build_object('date', '2027-02-06', 'start_time', '09:00', 'end_time', '13:00', 'title', 'US Sat class'))),
  jsonb_build_object('module_id', :'mod', 'cohort', 'TZ Weekend India', 'region', 'India',
    'classes', jsonb_build_array(jsonb_build_object('date', '2027-02-07', 'start_time', '09:00', 'end_time', '13:00', 'title', 'India Sun class')))),
  true);
select is((select region from public.cohort where name = 'TZ Weekend India'), 'India', '11. a new cohort gets the region chosen for it');
select is((select string_agg(region || ' ' || to_char(starts_at at time zone 'UTC', 'Dy HH24:MI'), ', ' order by starts_at) from public.class_session
            where title in ('US Sat class', 'India Sun class')), 'US Sat 17:00, India Sun 03:30', '11. both cohorts are planned in the same week, each in its own time zone');
select ok(private.class_lines((select module_week_id from public.class_session where title = 'India Sun class')) like '%IST%',
  '11. messages for the India class show IST');

select is((select count(*)::int from jsonb_array_elements(public.generate_classes(:'dom', :'mod', array['2027-02-07'::date], 'TZ US')) w,
                 jsonb_array_elements(w -> 'warnings') x where x = 'null'::jsonb), 0,
  '11. the plan preview lists only real warnings (no empty ones)');

-- =============================================================== 12: a single class switched to the other region
select is((tests.cls(tests.add(:'mod', :'us', '2027-02-20', '09:00', '10:00', 'India'))).region, 'India', '12. one class in a US cohort can be an India class');
select is((tests.cls(tests.add(:'mod', :'us', '2027-02-21', '09:00', '10:00', 'India'))).starts_at, '2027-02-21 03:30+00'::timestamptz,
  '12. and its time is read as India time');

-- =============================================================== 13: moving a class across the clock change keeps the local time
select (tests.add(:'mod', :'us', '2027-03-07', '09:00', '10:00') ->> 'class_id') as mv \gset
select public.change_class_time(:'mv', '2027-03-14', '09:00', '10:00');
select is((select starts_at from public.class_session where id = :'mv'), '2027-03-14 16:00+00'::timestamptz, '13. moved to Mar 14 at 9:00 AM: now PDT (16:00 UTC)');

-- =============================================================== 14: quiet hours follow the class's region
select is(private.instructor_send_time(:'dom', '2027-02-01 17:30+00', false, 'India'), '2027-02-02 02:30+00'::timestamptz,
  '14. 11:00 PM India time is quiet for an India class: sent at 8:00 AM India time');
select is(private.instructor_send_time(:'dom', '2027-02-01 17:30+00', false, 'US'), '2027-02-01 17:30+00'::timestamptz,
  '14. the same moment is 9:30 AM Pacific, fine for a US class');

-- =============================================================== 15: holidays per region
insert into public.holiday (date, name, region) values ('2027-07-04', 'Independence Day', 'US'), ('2027-08-15', 'Independence Day (India)', 'India')
  on conflict do nothing;
select ok(private.class_warnings(:'dom', null, '2027-07-04 16:00+00', '2027-07-04 17:00+00', null, null, 'US') @> '[{"code": "holiday"}]',
  '15. a US class on a US holiday is warned about');
select ok(not (private.class_warnings(:'dom', null, '2027-07-04 03:30+00', '2027-07-04 04:30+00', null, null, 'India') @> '[{"code": "holiday"}]'),
  '15. an India class on a US holiday is not');
select ok(private.class_warnings(:'dom', null, '2027-08-15 03:30+00', '2027-08-15 04:30+00', null, null, 'India') @> '[{"code": "holiday"}]',
  '15. an India class on an India holiday is warned about');

select * from finish();
rollback;
