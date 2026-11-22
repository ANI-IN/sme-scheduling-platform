-- Release 3, M12b (decision 314): bulk move and bulk cancel from the Schedule board, with one combined preview.
begin;
\ir ../helpers/helpers.psql
select plan(14);

select tests.scenario('BK', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select tests.make_module(:'dom', 'BK Two', 2) as m2 \gset
select tests.rank(:'m2', :'i1', :'i2', :'i3');
select tests.make_module(:'dom', 'BK Three', 3) as m3 \gset
select tests.rank(:'m3', :'i1', :'i2', :'i3');
select (public.save_standard_schedule(null, :'dom', 'BK track', array[:'m1', :'m2', :'m3']::uuid[]) ->> 'id') as sid \gset
select public.create_standard_cohorts(:'sid', '[{"name": "BK A", "start_date": "2027-03-07"}, {"name": "BK B", "start_date": "2027-03-07"}]',
  true, 'Two cohorts on purpose at the same times');
create or replace function tests.wk(p_cohort text, p_pos int) returns uuid language sql as $$
  select w.id from public.module_week w join public.cohort c on c.id = w.cohort_id where c.name = p_cohort and w.standard_position = p_pos;
$$;
select public.assign_manually(tests.wk('BK A', 3), :'i3');

-- =============================================================== bulk move
select public.bulk_change_weeks('move', array[tests.wk('BK A', 3), tests.wk('BK B', 3)], 2) as pv \gset
select ok((:'pv'::jsonb ->> 'ok')::boolean and (:'pv'::jsonb ->> 'preview')::boolean
          and jsonb_array_length(:'pv'::jsonb -> 'weeks') = 2, '1. one combined preview for both class weeks');
select is((select x ->> 'told' from jsonb_array_elements(:'pv'::jsonb -> 'weeks') x where x -> 'instructor' ->> 'id' = :'i3'),
  'BK Instr3 is asked whether the new time still works.', '2. it says who is asked about the new time');
select is((select week_start_date from public.module_week where id = tests.wk('BK A', 3)), '2027-03-21'::date,
  '3. the preview changed nothing');
-- BK Instr3 also teaches BK B's first class week; two weeks later it lands on their class in BK A.
select public.assign_manually(tests.wk('BK B', 1), :'i3');
select public.bulk_change_weeks('move', array[tests.wk('BK B', 1)], 2) as pv \gset
select ok(jsonb_array_length(:'pv'::jsonb -> 'blocks') >= 1 and not (:'pv'::jsonb ->> 'ok')::boolean
          and (:'pv'::jsonb -> 'blocks')::text like '%BK Instr3%',
  '4. a move that makes the confirmed instructor teach twice at once is a Block, naming them');
select is(public.bulk_change_weeks('move', array[tests.wk('BK B', 1)], 2, null, true) ->> 'ok', 'false',
  '5. and nothing is saved while there is a Block');
select is(public.bulk_change_weeks('move', array[tests.wk('BK A', 3), tests.wk('BK B', 3)], 2, null, true) ->> 'saved', '2',
  '6. saving moves both');
select is((select string_agg(week_start_date::text, ',' order by c.name) from public.module_week w join public.cohort c on c.id = w.cohort_id
            where w.id in (tests.wk('BK A', 3), tests.wk('BK B', 3))), '2027-04-04,2027-04-04', '7. both two weeks later');
select ok(exists (select 1 from public.history_event where action = 'Class weeks moved from the Schedule board: 2'),
  '8. in Activity history');

-- =============================================================== bulk cancel
select public.bulk_change_weeks('cancel', array[tests.wk('BK A', 3), tests.wk('BK B', 2)]) as pv \gset
select is((select x ->> 'told' from jsonb_array_elements(:'pv'::jsonb -> 'weeks') x where x -> 'instructor' ->> 'id' = :'i3'),
  'BK Instr3 is told the class week is cancelled.', '9. the cancel preview says who is told');
select throws_ok(format($$ select public.bulk_change_weeks('cancel', array[%L, %L]::uuid[], null, null, true) $$,
  tests.wk('BK A', 3), tests.wk('BK B', 2)), '22023',
  'Say why these class weeks are cancelled. The reason is kept in Activity history.', '10. cancelling needs a reason');
select is(public.bulk_change_weeks('cancel', array[tests.wk('BK A', 3), tests.wk('BK B', 2)], null, 'Room closed', true) ->> 'saved', '2',
  '11. saving cancels both');
select is((select string_agg(status, ',') from public.module_week where id in (tests.wk('BK A', 3), tests.wk('BK B', 2))),
  'Cancelled,Cancelled', '12. both are cancelled');
select ok((select jsonb_array_length(public.bulk_change_weeks('cancel', array[tests.wk('BK A', 3)]) -> 'blocks') = 1),
  '13. a class week cancelled already is a Block');

select throws_ok(format($$ select public.bulk_change_weeks('cancel', array[%L, %L]::uuid[]) $$,
  tests.wk('BK A', 1), (select (tests.scenario('BK2', 'Live', '2027-01-31', 1)) ->> 'mw')), '22023',
  'Select class weeks of one domain at a time.', '14. one domain at a time');

select * from finish();
rollback;
