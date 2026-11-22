-- Release 3, M10 (decision 303): one class shared by several cohorts.
begin;
\ir ../helpers/helpers.psql
select plan(20);

select tests.scenario('SH', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2 \gset
select tests.make_module(:'dom', 'SH Two', 2) as m2 \gset
select tests.rank(:'m2', :'i1', :'i2');
select (public.save_standard_schedule(null, :'dom', 'SH track', array[:'m1']::uuid[]) ->> 'id') as sid \gset
select public.create_standard_cohorts(:'sid', '[{"name": "SH A", "start_date": "2027-03-07"}, {"name": "SH B", "start_date": "2027-03-07"},
  {"name": "SH C", "start_date": "2027-03-07"}, {"name": "SH E", "start_date": "2027-03-07", "region": "India"}]', true, 'Four cohorts on purpose');
select (public.save_standard_schedule(null, :'dom', 'SH other', array[:'m2']::uuid[]) ->> 'id') as sid2 \gset
select public.create_standard_cohorts(:'sid2', '[{"name": "SH D", "start_date": "2027-03-07"}]', true, 'Same times on purpose');

create or replace function tests.wk(p_cohort text) returns uuid language sql as $$
  select w.id from public.module_week w join public.cohort c on c.id = w.cohort_id where c.name = p_cohort;
$$;
create or replace function tests.live(p_cohort text) returns uuid language sql as $$
  select k.id from public.class_session k where k.module_week_id = tests.wk(p_cohort) and k.class_type = 'Live class';
$$;
create or replace function tests.at(p_class uuid) returns text language sql as $$
  select to_char(starts_at at time zone 'America/Los_Angeles', 'Dy HH24:MI') from public.class_session where id = p_class;
$$;
select public.assign_manually(tests.wk('SH A'), :'i1');
select public.assign_manually(tests.wk('SH B'), :'i2');

-- =============================================================== 1. the preview and its rules
select public.share_class_weeks(tests.wk('SH A'), array[tests.wk('SH B')]) as pv \gset
select ok(exists (select 1 from jsonb_array_elements_text(:'pv'::jsonb -> 'blocks') b
                   where b like 'SH Instr2 is confirmed for %Choose whose instructor stays%'),
  '1. a guest with another confirmed instructor blocks until Ops chooses');
select ok(exists (select 1 from jsonb_array_elements_text(:'pv'::jsonb -> 'effects') e
                   where e = 'The other class weeks are not asked while they share this class.'), '2. the preview says what happens');
select ok(exists (select 1 from jsonb_array_elements_text(public.share_class_weeks(tests.wk('SH A'), array[tests.wk('SH A')]) -> 'blocks') b
                   where b like '%is in the same cohort.%'), '3. a cohort can''t share with itself');
select is(tests.booked(tests.wk('SH B')), 'SH Instr2', '4. the preview changes nothing');

-- =============================================================== 2. sharing
select is((public.share_class_weeks(tests.wk('SH A'), array[tests.wk('SH B')], null, true, true) ->> 'saved')::int, 1,
  '5. releasing the guest''s instructor lets it save');
select is((select (shared_with = tests.wk('SH A'))::text || ' ' || paused::text from public.module_week where id = tests.wk('SH B')),
  'true true', '6. the guest class week points to the host and is not asked');
select is(coalesce(tests.booked(tests.wk('SH B')), 'nobody') || ' ' || (tests.msgs(tests.wk('SH B'), 'M16') > 0)::text, 'nobody true',
  '7. its instructor is released with the release note');
select is((select count(*)::int from public.class_session g join public.class_session h on h.id = g.shared_class_id
            where g.module_week_id = tests.wk('SH B') and h.module_week_id = tests.wk('SH A') and g.starts_at = h.starts_at), 2,
  '8. each guest class points to its host class, at the same time');
select is((select count(*)::int from public.booking_slot s join public.class_session c on c.id = s.class_id
            where s.active and c.module_week_id in (tests.wk('SH A'), tests.wk('SH B'))), 2,
  '9. the instructor is booked once, for the host''s classes');

-- =============================================================== 3. a shared class stays one class
select public.change_class_time(tests.live('SH A'), '2027-03-07', '10:00', '14:00');
select is(tests.at(tests.live('SH B')), 'Sun 10:00', '10. the guest class follows the host''s new time');
select throws_like(format($$ select public.change_class_time(%L, '2027-03-07', '12:00', '16:00') $$, tests.live('SH B')),
  '%is shared with another cohort''s class.%', '11. a guest class''s time is changed only on the host');
select throws_like(format($$ update public.class_session set status = 'Cancelled' where id = %L $$, tests.live('SH A')),
  '%is shared with other cohorts. Stop sharing it first.', '12. the host class is not cancelled while it is shared');
select throws_like(format($$ select public.pause_outreach(%L, false) $$, tests.wk('SH B')),
  'This class week is taught in another cohort''s class.%', '13. the guest is not resumed while it is shared');
select ok(exists (select 1 from jsonb_array_elements(private.week_problems(tests.wk('SH B'))) x where x ->> 'text' like 'Taught together with %')
          and exists (select 1 from jsonb_array_elements(private.week_problems(tests.wk('SH A'))) x where x ->> 'text' = 'Shared with SH B.'),
  '14. both class weeks say they are shared');

-- =============================================================== 4. different times, modules and regions
select ok(exists (select 1 from jsonb_array_elements_text(public.share_class_weeks(tests.wk('SH A'), array[tests.wk('SH C')]) -> 'blocks') b
                   where b = 'The class weeks have different times. Choose whose times the shared class keeps.'),
  '15. different times need a choice');
select public.share_class_weeks(tests.wk('SH A'), array[tests.wk('SH C')], tests.wk('SH C'), false, true, true, 'Their time suits both');
select is(tests.at(tests.live('SH A')) || ' ' || tests.at(tests.live('SH B')) || ' ' || tests.at(tests.live('SH C')), 'Sun 09:00 Sun 09:00 Sun 09:00',
  '16. taking a guest''s times moves the host, and every guest follows');
select ok(exists (select 1 from public.request where module_week_id = tests.wk('SH A') and kind = 'TimeChange' and status = 'Sent'),
  '17. and the host''s instructor is asked about the new time');
select is((public.share_class_weeks(tests.wk('SH A'), array[tests.wk('SH D')], null, false, true) ->> 'needs_confirmation')::boolean, true,
  '18. another module needs a reason');
select ok(exists (select 1 from jsonb_array_elements(public.share_class_weeks(tests.wk('SH A'), array[tests.wk('SH E')], tests.wk('SH A')) -> 'warnings') x
                   where x ->> 'code' = 'unusual_hours' and x ->> 'text' like '%India time.'),
  '19. the chosen time is checked for odd hours in each cohort''s time zone');

-- =============================================================== 5. stopping
select public.stop_sharing(tests.wk('SH B'));
select is((select coalesce(shared_with::text, 'none') || ' ' || paused::text from public.module_week where id = tests.wk('SH B'))
            || ' ' || (select count(*) from public.class_session where module_week_id = tests.wk('SH B') and shared_class_id is not null)::text
            || ' ' || tests.at(tests.live('SH B')),
  'none false 0 Sun 09:00', '20. stopping gives the cohort its own class week back, at the shared time');

select * from finish();
rollback;
