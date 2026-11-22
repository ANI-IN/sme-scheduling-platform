-- Release 3, M7 part 2a (decision 297): the schedule checks. Block, Warning with a reason, Information; the limits are
-- settings; assigning, moving and adding a class check the instructor's day; every problem of a class week is listed
-- with its suggested fixes.
begin;
\ir ../helpers/helpers.psql
select plan(18);

select tests.scenario('CK', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
insert into public.cohort (domain_id, name, region, start_date) values (:'dom', 'CK One', 'US', '2027-01-02') returning id as c1 \gset
insert into public.cohort (domain_id, name, region, start_date) values (:'dom', 'CK Two', 'US', '2027-01-02') returning id as c2 \gset
insert into public.cohort (domain_id, name, region, start_date) values (:'dom', 'CK Three', 'US', '2027-01-02') returning id as c3 \gset

create or replace function tests.week(p_mod uuid, p_coh uuid, p_date date, p_start time, p_end time)
returns uuid language sql as $$
  select (public.add_one_class(null, p_mod, p_coh, p_date, p_start, p_end, 'Live class', null, true,
          'Test class: the time is chosen on purpose', null, 1) ->> 'module_week_id')::uuid;
$$;
create or replace function tests.codes(p jsonb)
returns text language sql as $$
  select coalesce(string_agg(x ->> 'code', ',' order by x ->> 'code'), '') from jsonb_array_elements(p -> 'warnings') x;
$$;

-- =============================================================== 1. the limits are settings with the owner's numbers
select is(private.setting_text(:'dom', 'odd_hours_start') || ' ' || private.setting_text(:'dom', 'odd_hours_end') || ' '
          || private.setting_int(:'dom', 'tight_gap_minutes') || ' ' || private.setting_int(:'dom', 'max_classes_per_day'),
  '06:00 22:00 30 2', '1. unusual before 6 AM or after 10 PM, 30 minutes, 2 classes a day');
insert into public.setting (scope, domain_id, key, value) values ('Domain', :'dom', 'odd_hours_start', '"08:00"');
select alike((select x ->> 'text' from jsonb_array_elements(private.class_warnings(:'dom', null, '2027-02-06 15:00+00',
                '2027-02-06 16:00+00', null, 'A class', 'US')) x where x ->> 'code' = 'unusual_hours'),
  '%outside 8 AM to 10 PM US Pacific time.', '2. a domain can change the hours, and the warning says so');
delete from public.setting where domain_id = :'dom' and key = 'odd_hours_start';

-- =============================================================== 2. assigning checks the instructor's day
select tests.week(:'mod', :'c1', '2027-02-06', '09:00', '10:00') as wa \gset
select public.assign_manually(:'wa', :'i1');
select tests.week(:'mod', :'c2', '2027-02-06', '10:15', '11:00') as wb \gset
select public.assign_manually(:'wb', :'i1') as res \gset
select is(tests.codes(:'res'::jsonb), 'tight_gap', '3. 15 minutes after another class is a tight gap: asked first, not saved');
select is(tests.booked(:'wb'), null, '4. nothing is booked until the warning is accepted');
select throws_like(format($$ select public.assign_manually(%L, %L, null, true) $$, :'wb', :'i1'),
  'Say why you are going ahead despite the warning:%', '5. going ahead needs a reason');
select public.assign_manually(:'wb', :'i1', null, true, 'They asked for back to back classes');
select is(tests.booked(:'wb'), 'CK Instr1', '6. with a reason it is saved');
select is((select note from public.history_event where module_week_id = :'wb' and action = 'Warnings accepted' order by at desc limit 1),
  'They asked for back to back classes', '7. the reason is kept in Activity history');
select tests.week(:'mod', :'c3', '2027-02-06', '13:00', '14:00') as wc \gset
select is(tests.codes(public.assign_manually(:'wc', :'i1')), 'busy_day', '8. a third class on one day is a full day');

-- =============================================================== 3. unavailable dates block
insert into public.instructor_unavailability (instructor_id, from_date, to_date, reason) values (:'i2', '2027-02-13', '2027-02-13', 'Travel');
select tests.week(:'mod', :'c1', '2027-02-13', '09:00', '10:00') as wd \gset
select throws_like(format($$ select public.assign_manually(%L, %L, null, true, 'any reason') $$, :'wd', :'i2'),
  'Can''t book: %Unavailable Feb 13 to Feb 13 (Travel).', '9. an unavailable instructor cannot be assigned, even with a reason');

-- =============================================================== 4. moving a class checks the confirmed instructor's day
select tests.week(:'mod', :'c1', '2027-02-20', '09:00', '10:00') as we \gset
select public.assign_manually(:'we', :'i2');
select tests.week(:'mod', :'c2', '2027-02-20', '12:00', '13:00') as wf \gset
select public.assign_manually(:'wf', :'i2');
select id as wf_class from public.class_session where module_week_id = :'wf' \gset
select is(tests.codes(public.change_class_time(:'wf_class', '2027-02-20', '10:10', '11:00')), 'tight_gap',
  '10. moving a class 10 minutes after the instructor''s other class asks first');
select throws_like(format($$ select public.change_class_time(%L, '2027-02-13', '12:00', '13:00', null, null, null, true, 'any reason') $$, :'wf_class'),
  '%Unavailable Feb 13 to Feb 13%', '11. moving a class onto the instructor''s unavailable date is refused');

-- =============================================================== 5. the monthly limit
update public.instructor set monthly_class_limit = 1 where id = :'i3';
select tests.week(:'mod', :'c1', '2027-02-27', '09:00', '10:00') as wg \gset
select public.assign_manually(:'wg', :'i3');
select tests.week(:'mod', :'c2', '2027-02-27', '15:00', '16:00') as wh \gset
select is(tests.codes(public.assign_manually(:'wh', :'i3')), 'monthly_limit', '12. over the monthly limit is a warning');

-- =============================================================== 6. every problem of a class week, with its fixes
select tests.week(:'mod', :'c3', '2027-02-27', '05:00', '06:00') as wi \gset
select is((select string_agg((x ->> 'level') || ' ' || (x ->> 'code') || ' ' || (x -> 'fixes')::text, '; ')
             from jsonb_array_elements(private.week_problems(:'wi')) x),
  'Warning unusual_hours ["move_class", "keep"]', '13. a class at 5 AM is listed with its level and fixes');
update public.instructor set status = 'Inactive' where id = :'i3';
select ok(exists (select 1 from jsonb_array_elements(private.week_problems(:'wg')) x
                   where x ->> 'code' = 'not_in_use' and x -> 'fixes' = '["release_and_ask_next", "keep"]'),
  '14. an instructor no longer in use but still confirmed is listed');
select ok(exists (select 1 from jsonb_array_elements(private.week_problems(:'wg')) x
                   where x ->> 'code' = 'monthly_limit' and x ->> 'level' = 'Warning') = false,
  '15. a confirmed instructor at their limit (not over it) is fine');
update public.instructor set status = 'Active' where id = :'i3';
insert into public.request (module_week_id, instructor_id, kind, status, close_reason, time_version)
values (:'wd', :'i1', 'Outreach', 'Withdrawn', 'Sooner class', 1);
insert into public.request (module_week_id, instructor_id, kind, status, time_version) values (:'wd', :'i3', 'Outreach', 'Sent', 1);
select is((select (x ->> 'level') || ': ' || (x ->> 'text') from jsonb_array_elements(private.week_problems(:'wd')) x
            where x ->> 'code' = 'sooner_class_first'),
  'Information: CK Instr1 is busy with a sooner class at the same time, so CK Instr3 is asked instead.',
  '16. a class week that gave way to a sooner class says so');

-- =============================================================== 7. the screens ask for many class weeks at once
select is((select count(*)::int from jsonb_object_keys(public.schedule_problems(array[:'wi', :'wg', :'wd']::uuid[]))), 3,
  '17. problems for several class weeks in one call');
select tests.login_anon();
select throws_like(format($$ select public.schedule_problems(array[%L]::uuid[]) $$, :'wi'), '%',
  '18. only the team can read them');

select * from finish();
rollback;
