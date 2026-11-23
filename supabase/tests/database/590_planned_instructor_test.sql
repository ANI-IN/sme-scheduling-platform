-- Release 3, batch 4, item B12: the planned instructor of a class week before anyone is asked, and from when asking
-- starts. The person is the database's own next person to ask (private.build_line, as preview_next and the engine).
begin;
\ir ../helpers/helpers.psql
select plan(18);

select tests.scenario('PI', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
select tests.at('2026-12-01 12:00+00');

create temp table p as select x from jsonb_array_elements(public.planned_instructors(array[:'mw']::uuid[])) x;

-- =============================================================== before anyone is asked
select is((select count(*)::int from p), 1, '1. one answer for one class week');
select is((select x -> 'planned' ->> 'name' from p), 'PI Instr1', '2. the planned instructor is the first of the order');
select is((select (x -> 'planned' ->> 'rank')::int from p), 1, '3. with rank 1, the Primary instructor');
select is((select x -> 'planned' ->> 'name' from p), public.preview_next(:'mw') ->> 'next',
  '4. the same person preview_next names as asked next');
select is((select (x ->> 'asking_starts_at')::timestamptz from p),
  (select first_class_at - interval '30 days' from public.module_week where id = :'mw'),
  '5. asking starts outreach_days (30) before the first class');
select is((select (x ->> 'paused')::boolean from p), false, '6. not paused');
select is((select x ->> 'asking' from p), null, '7. nobody is being asked');

-- The domain's own number of days counts.
select public.set_settings_at('Domain', :'dom', '{"outreach_days": 45, "readiness_days": 55}');
select is((public.planned_instructors(array[:'mw']::uuid[]) -> 0 ->> 'asking_starts_at')::timestamptz,
  (select first_class_at - interval '45 days' from public.module_week where id = :'mw'),
  '8. a changed setting moves the day asking starts');

-- Someone who cannot be asked is skipped, as the engine would.
update public.instructor set status = 'Inactive' where id = :'i1';
select is(public.planned_instructors(array[:'mw']::uuid[]) -> 0 -> 'planned' ->> 'name', 'PI Instr2',
  '9. an instructor not in use is skipped: the next one is planned');
select is((public.planned_instructors(array[:'mw']::uuid[]) -> 0 -> 'planned' ->> 'rank')::int, 2, '10. rank 2, Backup 1');

update public.module_week set paused = true where id = :'mw';
select is((public.planned_instructors(array[:'mw']::uuid[]) -> 0 ->> 'paused')::boolean, true,
  '11. a paused class week says so');

-- =============================================================== a chosen list
select tests.make_week(:'mod', '2027-02-07') as mw2 \gset
select public.set_outreach_queue(:'mw2', 'Manual', array[:'i3']::uuid[], 'Stop', null, false);
select is(public.planned_instructors(array[:'mw2']::uuid[]) -> 0 -> 'planned',
  jsonb_build_object('instructor_id', :'i3'::uuid, 'name', 'PI Instr3', 'source', 'Manual', 'rank', null),
  '12. a chosen list: the person comes from the list, with no rank');

-- =============================================================== once asked, then confirmed
update public.module_week set paused = false where id = :'mw';
select tests.at('2026-12-20 12:00+00');
select public.start_asking_now(:'mw');
select is(public.planned_instructors(array[:'mw']::uuid[]) -> 0 ->> 'asking', 'PI Instr2',
  '13. after Start asking now: who is being asked');
select tests.raw_book(:'mw2', :'i3');
select is(public.planned_instructors(array[:'mw2']::uuid[]) -> 0 ->> 'confirmed', 'PI Instr3', '14. confirmed: who is confirmed');
select is(public.planned_instructors(array[:'mw2']::uuid[]) -> 0 -> 'planned', 'null'::jsonb,
  '15. and nobody is planned any more');

-- =============================================================== who may read it
select tests.login_as('someone@elsewhere.org');
select throws_ok(format('select public.planned_instructors(array[%L]::uuid[])', :'mw'), '42501', null,
  '16. only a signed in team member can read it');
select tests.as_postgres();
select ok(not has_function_privilege('authenticated', 'private.planned_instructor(uuid, timestamptz)', 'execute')
          and not has_function_privilege('anon', 'public.planned_instructors(uuid[])', 'execute'),
  '17. the private function and anonymous callers have no access');
select throws_ok(format('select public.planned_instructors(array(select gen_random_uuid() from generate_series(1, 1001)))'),
  '22023', null, '18. at most 1,000 class weeks at a time');

select * from finish();
rollback;
