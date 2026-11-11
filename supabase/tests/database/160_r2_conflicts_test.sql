-- Release 2: an instructor can never teach two classes at the same real time, across cohorts,
-- domains and the US and India regions. Clashes are found on UTC and explained in full.
begin;
\ir ../helpers/helpers.psql
select plan(16);

select tests.scenario('CF', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
insert into public.cohort (domain_id, name, region) values (:'dom', 'CF Weekend', 'US') returning id as we \gset
insert into public.cohort (domain_id, name, region) values (:'dom', 'CF Weekday', 'US') returning id as wd \gset
insert into public.cohort (domain_id, name, region) values (:'dom', 'CF India', 'India') returning id as ind \gset
select tests.scenario('CG', 'Live', '2027-01-31', 1) as j2 \gset
select (:'j2'::jsonb ->> 'domain') as dom2, (:'j2'::jsonb ->> 'module') as mod2 \gset

create or replace function tests.week(p_mod uuid, p_coh uuid, p_date date, p_start time, p_end time, p_region text default null)
returns uuid language sql as $$
  select (public.add_one_class(null, p_mod, p_coh, p_date, p_start, p_end, 'Live class', null, true, null, p_region, 1) ->> 'module_week_id')::uuid;
$$;

-- =============================================================== 1. same instructor, two cohorts, same time
select tests.week(:'mod', :'we', '2027-02-06', '09:00', '13:00') as a \gset
select tests.week(:'mod', :'wd', '2027-02-06', '10:00', '12:00') as b \gset
select public.assign_manually(:'a', :'i1');
select throws_like(format($$ select public.assign_manually(%L, %L) $$, :'b', :'i1'),
  '%Teaching Concurrency CF (CF Weekend, CF) on Sat, Feb 6 · 9:00 AM to 1:00 PM PST, the same time as this class (Sat, Feb 6 · 10:00 AM to 12:00 PM PST)%',
  '1. a second class at an overlapping time is refused, naming the other class, its cohort and both times');

-- =============================================================== 2. same instructor, two cohorts, different times
select tests.week(:'mod', :'wd', '2027-02-06', '14:00', '16:00') as c \gset
select lives_ok(format($$ select public.assign_manually(%L, %L) $$, :'c', :'i1'), '2. the same instructor teaches two cohorts at different times');

-- =============================================================== 3. across domains
select tests.week(:'mod2', (select id from public.cohort where domain_id = :'dom2' limit 1), '2027-02-06', '12:00', '13:30') as d \gset
select throws_like(format($$ select public.assign_manually(%L, %L) $$, :'d', :'i1'), '%Teaching Concurrency CF (CF Weekend, CF)%',
  '3. a clash with a class in another domain is refused too');

-- =============================================================== 4. US and India: different local dates, same real time
-- Sat Feb 13, 7:30 PM PST = Sun Feb 14, 9:00 AM IST = 03:30 UTC.
select tests.week(:'mod', :'we', '2027-02-13', '19:30', '21:30') as e \gset
select tests.week(:'mod', :'ind', '2027-02-14', '09:00', '11:00') as f \gset
select public.assign_manually(:'e', :'i2');
select throws_like(format($$ select public.assign_manually(%L, %L) $$, :'f', :'i2'),
  '%on Sat, Feb 13 · 7:30 PM to 9:30 PM PST, the same time as this class (Sun, Feb 14 · 9:00 AM to 11:00 AM IST)%',
  '4. a Sunday 9:00 AM IST class and a Saturday 7:30 PM PST class are the same moment: refused');

-- =============================================================== 5. a clash created by moving a class
select tests.week(:'mod', :'wd', '2027-02-20', '09:00', '10:00') as g \gset
select tests.week(:'mod', :'we', '2027-02-20', '12:00', '13:00') as h \gset
select public.assign_manually(:'g', :'i3');
select public.assign_manually(:'h', :'i3');
select throws_like(format($$ select public.change_class_time(%L, '2027-02-20', '09:30', '10:30') $$,
  (select id from public.class_session where module_week_id = :'h')), '%cannot teach at the new time: Teaching%',
  '5. moving a class onto another class of the same instructor is blocked with a clear message');
select is((select to_char(starts_at at time zone 'America/Los_Angeles', 'HH24:MI') from public.class_session where module_week_id = :'h'), '12:00',
  '5. and the class keeps its time');

-- =============================================================== 6. a clash created by adding a class to a confirmed week
select throws_like(format($$ select public.add_one_class(%L, null, null, '2027-02-20', '09:15', '09:45', 'Office hours', null, true) $$, :'h'),
  '%cannot teach this class: Teaching%', '6. adding a class at a busy time to a confirmed class week is blocked');

-- =============================================================== 7. daylight saving changes the overlap
-- India class 9:30 to 10:30 PM IST. US class 9:00 to 10:00 AM Pacific on the same Sunday.
-- Mar 7 (PST): the US class is 10:30 to 11:30 PM IST, no clash. Mar 14 (PDT): 9:30 to 10:30 PM IST, a clash.
select tests.week(:'mod', :'ind', '2027-03-07', '21:30', '22:30') as k1 \gset
select tests.week(:'mod', :'we', '2027-03-07', '09:00', '10:00') as k2 \gset
select tests.week(:'mod', :'ind', '2027-03-14', '21:30', '22:30') as k3 \gset
select tests.week(:'mod', :'we', '2027-03-14', '09:00', '10:00') as k4 \gset
select public.assign_manually(:'k1', :'i1');
select lives_ok(format($$ select public.assign_manually(%L, %L) $$, :'k2', :'i1'), '7. before the clock change the two classes do not overlap');
select public.assign_manually(:'k3', :'i1');
select throws_like(format($$ select public.assign_manually(%L, %L) $$, :'k4', :'i1'), '%Teaching%',
  '7. after the clock change the same local times overlap, and the clash is found');

-- =============================================================== 8. the instructor order skips a clashing instructor and says why
select tests.week(:'mod', :'wd', '2027-02-06', '11:00', '12:00') as m \gset
select ok((select x ->> 'reason' from jsonb_array_elements(public.preview_next(:'m') -> 'line') x
            where x ->> 'name' = 'CF Instr1') like 'Teaching Concurrency CF (CF Weekend, CF)%',
  '8. in the instructor order, an instructor with a clash is skipped with the reason');

-- =============================================================== 9. a cancelled class frees the time
select public.cancel_class((select id from public.class_session where module_week_id = :'a'));
select lives_ok(format($$ select public.assign_manually(%L, %L) $$, :'b', :'i1'), '9. once the other class is cancelled, the time is free');

-- =============================================================== 10. a released instructor is free again
select public.release_booking(:'e', 'Test', false);
select lives_ok(format($$ select public.assign_manually(%L, %L) $$, :'f', :'i2'), '10. once released, the instructor can take the other class');

-- =============================================================== 11. "Yes" from an instructor who is busy is turned down politely
select tests.week(:'mod', :'wd', '2027-02-27', '09:00', '10:00') as n1 \gset
select tests.week(:'mod', :'we', '2027-02-27', '09:00', '10:00') as n2 \gset
select public.assign_manually(:'n1', :'i3');
update public.module_week set outreach_mode = 'Manual' where id = :'n2';
insert into public.request (module_week_id, instructor_id, kind, status, sent_at) values (:'n2', :'i3', 'Outreach', 'Sent', now()) returning id as rq \gset
insert into public.response_link (token, request_id, answer) values ('cf-yes-token', :'rq', 'Yes');
select is(public.record_response('cf-yes-token') ->> 'result', 'not_booked', '11. a Yes for a clashing class is not booked');
select is((select close_reason from public.request where id = :'rq'), 'Clash', '11. the request is closed as a clash');
select is(tests.booked(:'n2'), null, '11. and no second booking is made');

-- =============================================================== 12. the database rule is the final protection
select throws_ok(format($$ insert into public.booking_slot (booking_id, class_id, instructor_id, time_range)
  select b.id, c.id, %L, tstzrange(c.starts_at, c.ends_at, '[)') from public.booking b, public.class_session c
   where b.module_week_id = %L and c.module_week_id = %L $$, :'i3', :'n1', :'n2'), '23P01', null,
  '12. even a direct write can never give an instructor two classes at the same time');

select * from finish();
rollback;
