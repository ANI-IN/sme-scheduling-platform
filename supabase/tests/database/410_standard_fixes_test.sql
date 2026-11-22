-- Release 3, M7b part 2b (decision 300): fixes found while building the standard schedule screens.
begin;
\ir ../helpers/helpers.psql
select plan(6);

select tests.scenario('SF', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1 \gset
select tests.make_module(:'dom', 'SF Two', 2) as m2 \gset

-- 1. A time that happens twice is information once chosen (1:30 AM on Nov 7, 2027 happens twice in US Pacific time).
select is(private.ambiguous_warning('2027-11-07', '01:30', 'US') ->> 'level', 'Information',
  '1. a time that happens twice needs a choice, not a reason');

-- 2. A new module order is a new version; an editor with the old version is told.
select public.save_standard_schedule(null, :'dom', 'SF track', array[:'m1', :'m2']::uuid[]) as s \gset
select (:'s'::jsonb ->> 'id') as sid, (:'s'::jsonb ->> 'version')::int as v1 \gset
insert into public.standard_schedule_class (schedule_id, module_id, class_type, day_offset, start_time, duration_minutes)
values (:'sid', :'m2', 'Live class', 9, '10:00', 700);
select is((public.save_standard_schedule(:'sid', null, 'SF track', array[:'m1']::uuid[], '[]', null, :v1) ->> 'version')::int, :v1 + 1,
  '2. changing only the module order makes a new version');
select throws_like(format($$ select public.save_standard_schedule(%L, null, 'SF track', array[%L, %L]::uuid[], '[]', null, %s) $$,
  :'sid', :'m1', :'m2', :v1), 'Someone else saved this standard schedule after you opened it%', '3. so a second editor is told');
select is((select count(*)::int from public.standard_schedule_class where schedule_id = :'sid'), 0,
  '4. a module taken out takes its class times with it (and they allow the same days and lengths as a module''s)');

-- 3. Changed by hand and changed back.
select public.save_standard_schedule(:'sid', null, 'SF track', array[:'m1', :'m2']::uuid[]);
select public.create_standard_cohorts(:'sid', '[{"name": "SF A", "start_date": "2027-03-07"}]');
select w.id as wa, k.id as ka from public.module_week w join public.cohort c on c.id = w.cohort_id
  join public.class_session k on k.module_week_id = w.id where c.name = 'SF A' and w.standard_position = 1 and k.class_type = 'Live class' \gset
select public.change_class_time(:'ka', '2027-03-07', '11:00', '15:00');
select public.change_class_time(:'ka', '2027-03-07', '09:00', '13:00');
select is((select string_agg(a #>> '{}', ' ') from jsonb_array_elements(public.reset_to_standard(array[:'wa']::uuid[]) -> 'changes') c,
            jsonb_array_elements(c -> 'actions') a),
  'It matches the standard again, so it is marked as following it.', '5. Reset offers to mark it as following its standard');
select public.reset_to_standard(array[:'wa']::uuid[], null, true);
select is((select customized_at from public.module_week where id = :'wa'), null, '6. and then it does');

select * from finish();
rollback;
