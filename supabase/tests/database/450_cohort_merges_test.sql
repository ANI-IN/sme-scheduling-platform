-- Release 3, M11 (decision 304): cohorts merge into one combined cohort from a date.
begin;
\ir ../helpers/helpers.psql
select plan(18);

select tests.scenario('CM', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select tests.make_module(:'dom', 'CM Two', 2) as m2 \gset
select tests.rank(:'m2', :'i1', :'i2', :'i3');
select tests.make_module(:'dom', 'CM Three', 3) as m3 \gset
select tests.rank(:'m3', :'i1', :'i2', :'i3');
-- CM A takes One, Two, Three from Mar 7; CM B takes Two, One, Three from Feb 28.
select (public.save_standard_schedule(null, :'dom', 'CM track', array[:'m1', :'m2', :'m3']::uuid[]) ->> 'id') as sa \gset
select (public.save_standard_schedule(null, :'dom', 'CM other', array[:'m2', :'m1', :'m3']::uuid[]) ->> 'id') as sb \gset
select public.create_standard_cohorts(:'sa', '[{"name": "CM A", "start_date": "2027-03-07"}]', true, 'Test cohorts');
select public.create_standard_cohorts(:'sb', '[{"name": "CM B", "start_date": "2027-02-28"}]', true, 'Test cohorts');
select id as ca from public.cohort where name = 'CM A' \gset
select id as cb from public.cohort where name = 'CM B' \gset

create or replace function tests.wk(p_cohort text, p_mod text) returns uuid language sql as $$
  select w.id from public.module_week w join public.cohort c on c.id = w.cohort_id join public.module m on m.id = w.module_id
   where c.name = p_cohort and m.name = p_mod;
$$;
create or replace function tests.weeks(p_cohort text) returns text language sql as $$
  select coalesce(string_agg(m.name || ' ' || to_char(w.week_start_date, 'Mon DD') || case when w.status = 'Cancelled' then ' cancelled' else '' end,
                             ', ' order by w.week_start_date), '')
    from public.module_week w join public.cohort c on c.id = w.cohort_id join public.module m on m.id = w.module_id where c.name = p_cohort;
$$;
select public.assign_manually(tests.wk('CM A', 'CM Three'), :'i1');
select public.assign_manually(tests.wk('CM B', 'CM Three'), :'i2');
-- CM B has its own instructor order for CM Two.
insert into public.module_ranking (module_id, instructor_id, rank, cohort_id) values (:'m2', :'i3', 1, :'cb');

-- =============================================================== 1. the rules
select ok(exists (select 1 from jsonb_array_elements_text(public.merge_cohorts(array[:'ca', :'cb']::uuid[], '2027-03-07', :'ca', :'ca', 'CM AB', 'US') -> 'blocks') b
                   where b = 'CM A has not started before the merge date. Merge from a later class week.'), '1. never before both cohorts started');
select ok(exists (select 1 from jsonb_array_elements_text(public.merge_cohorts(array[:'ca', :'cb']::uuid[], '2027-03-10', :'ca', :'ca', 'CM AB', 'US') -> 'blocks') b
                   where b like 'A merge starts at the start of a class week%'), '2. only at the start of a class week');
select ok(exists (select 1 from jsonb_array_elements_text(public.merge_cohorts(array[:'ca', :'cb']::uuid[], '2027-03-14', :'ca', :'ca', 'cm a', 'US') -> 'blocks') b
                   where b = 'A cohort named cm a already exists in this domain.'), '3. the name must be new');

-- =============================================================== 2. the preview
select public.merge_cohorts(array[:'ca', :'cb']::uuid[], '2027-03-14', :'ca', :'cb', 'CM AB', 'US') as pv \gset
select is((select string_agg((x ->> 'cohort') || ' ' || split_part(x ->> 'label', ' (', 1) || ' ' || (x ->> 'action'), ', ' order by x ->> 'cohort', x ->> 'label')
             from jsonb_array_elements(:'pv'::jsonb -> 'weeks') x),
  'CM A CM Three move, CM A CM Two move, CM B CM Three cancel', '4. from the merge date: the chosen sequence moves, the other cohort''s duplicate is cancelled');
select ok(exists (select 1 from jsonb_array_elements(:'pv'::jsonb -> 'warnings') x
                   where x ->> 'code' = 'merge_check' and x ->> 'text' like 'Merge check: CM Three is module 1 of CM B from the merge date but module 2 of the chosen sequence.'),
  '5. the merge check says which modules do not line up');
select ok(exists (select 1 from jsonb_array_elements(:'pv'::jsonb -> 'warnings') x
                   where x ->> 'text' = 'CM Instr1 and CM Instr2 are both confirmed for CM Three. CM Instr1 stays and CM Instr2 gets the release note.'),
  '6. two confirmed instructors: the chosen cohort''s stays, the other gets the release note');
select ok(exists (select 1 from jsonb_array_elements(public.merge_cohorts(array[:'ca', :'cb']::uuid[], '2027-03-14', :'ca', :'cb', 'CM AB', 'US',
                     array[tests.wk('CM B', 'CM Three')]) -> 'warnings') x
                   where x ->> 'text' like '%CM Instr2 stays and CM Instr1 gets the release note.'), '7. Ops can keep the other instructor instead');
select is(tests.weeks('CM A'), 'Concurrency CM Mar 07, CM Two Mar 14, CM Three Mar 21', '8. the preview changes nothing');

-- =============================================================== 3. merging
select is((public.merge_cohorts(array[:'ca', :'cb']::uuid[], '2027-03-14', :'ca', :'cb', 'CM AB', 'US', '{}', '{}', true) ->> 'needs_confirmation')::boolean,
  true, '9. a merge with warnings needs a reason');
select public.merge_cohorts(array[:'ca', :'cb']::uuid[], '2027-03-14', :'ca', :'cb', 'CM AB', 'US', '{}', '{}', true, true, 'Small cohorts') as done \gset
select is((:'done'::jsonb ->> 'moved')::int || ' ' || (:'done'::jsonb ->> 'cancelled'), '2 1', '10. two class weeks move and one is cancelled');
select is(tests.weeks('CM AB'), 'CM Two Mar 14, CM Three Mar 21', '11. the combined cohort follows the chosen sequence');
select is(tests.weeks('CM A') || ' / ' || tests.weeks('CM B'), 'Concurrency CM Mar 07 / CM Two Feb 28, Concurrency CM Mar 07, CM Three Mar 14 cancelled',
  '12. the cohorts keep their class weeks before the merge date');
select is(coalesce(tests.booked(tests.wk('CM B', 'CM Three')), 'nobody') || ' ' || (tests.msgs(tests.wk('CM B', 'CM Three'), 'M16') > 0)::text
            || ' ' || tests.booked(tests.wk('CM AB', 'CM Three')), 'nobody true CM Instr1',
  '13. the other instructor gets the release note; the chosen one stays');
select is((select string_agg(c.name || ' ' || (c.merged_into = (:'done'::jsonb ->> 'cohort_id')::uuid)::text || ' ' || c.merged_from, ', ' order by c.name)
             from public.cohort c where c.id in (:'ca', :'cb')), 'CM A true 2027-03-14, CM B true 2027-03-14',
  '14. each cohort says it merged into the combined cohort from the date');
select is((select string_agg(i.full_name, ',') from public.module_ranking k join public.instructor i on i.id = k.instructor_id
            where k.cohort_id = (:'done'::jsonb ->> 'cohort_id')::uuid), 'CM Instr3', '15. with the chosen cohort''s instructor order');

-- =============================================================== 4. undo until the merge date
select public.undo_cohort_merge((:'done'::jsonb ->> 'merge_id')::uuid);
select is(tests.weeks('CM A') || ' / ' || tests.weeks('CM B'),
  'Concurrency CM Mar 07, CM Two Mar 14, CM Three Mar 21 / CM Two Feb 28, Concurrency CM Mar 07, CM Three Mar 14',
  '16. undo moves the class weeks back and plans the cancelled one again');
select is((select count(*)::int from public.cohort where id in (:'ca', :'cb') and merged_into is null)
            || ' ' || (select (archived_at is not null)::text from public.cohort where id = (:'done'::jsonb ->> 'cohort_id')::uuid),
  '2 true', '17. the cohorts are on their own again and the combined cohort is archived');
select ok(exists (select 1 from public.history_event where action = 'Cohorts merged into CM AB')
          and exists (select 1 from public.history_event where action = 'Cohort merge undone'), '18. Activity history has both');

select * from finish();
rollback;
