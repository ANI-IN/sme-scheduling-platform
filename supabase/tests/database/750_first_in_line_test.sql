-- Leftover work of 24 November 2026 (decision 342): private.first_in_line gives exactly the first person of
-- private.build_line who can be asked, on every kind of line: the instructor order, someone unavailable, someone being
-- asked now, a chosen list that stops, a chosen list that continues with the order, a sooner class, nobody left.
begin;
\ir ../helpers/helpers.psql
select plan(11);

select tests.scenario('FL', 'Live', '2027-01-31', 4) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as w1,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3, (:'j'::jsonb ->> 'i4') as i4,
       (:'j'::jsonb ->> 'ops') as ops \gset
select email as ops_email from public.team_member where id = :'ops' \gset

select tests.make_week(:'mod', '2027-02-07') as w2 \gset
select tests.make_week(:'mod', '2027-02-14') as w3 \gset
select tests.make_week(:'mod', '2027-02-21') as w4 \gset
select tests.make_week(:'mod', '2027-02-28') as w5 \gset
select tests.make_week(:'mod', '2027-03-07') as w6 \gset

-- w1: someone is being asked now (the Primary).
select tests.tick(:'dom', '2027-01-01 18:00+00');
-- w2: the Primary is away that week.
insert into public.instructor_unavailability (instructor_id, from_date, to_date, reason) values (:'i1', '2027-02-06', '2027-02-14', 'Away');
-- w4: a chosen list that stops (Instr4, then Instr1, who is away for w2 only); w5: a chosen list of someone away that
-- continues with the order.
select tests.login_member(:'ops_email');
select public.set_outreach_queue(:'w4', 'Manual', array[:'i4', :'i1']::uuid[], 'Stop', null, false);
insert into public.instructor_unavailability (instructor_id, from_date, to_date, reason) values (:'i3', '2027-02-27', '2027-03-01', 'Away');
select public.set_outreach_queue(:'w5', 'Manual', array[:'i3']::uuid[], 'ContinueWithRanking', null, false);
select tests.as_postgres();
-- w6: everybody away.
insert into public.instructor_unavailability (instructor_id, from_date, to_date, reason)
select x, '2027-03-06', '2027-03-13', 'Away' from unnest(array[:'i1', :'i2', :'i3', :'i4']::uuid[]) x;

create temp table cmp as
select w.id, w.week_start_date,
       (select l.full_name from private.build_line(w.id) l where l.reason is null order by l.pos limit 1) as full_line,
       (select l.full_name from private.first_in_line(w.id) l) as first_only
  from public.module_week w where w.domain_id = :'dom';
grant select on cmp to authenticated;

select is((select count(*)::int from cmp), 6, '1. six class weeks compared');
select is((select count(*)::int from cmp where full_line is distinct from first_only), 0,
  '2. on every one, the first person who can be asked is the same as the whole line''s');
select is((select first_only from cmp where id = :'w1'), 'FL Instr2', '3. someone being asked now is skipped');
select is((select first_only from cmp where id = :'w2'), 'FL Instr2', '4. someone away is skipped');
select is((select first_only from cmp where id = :'w4'), 'FL Instr4', '5. a chosen list comes first');
select is((select first_only from cmp where id = :'w5'), 'FL Instr1', '6. a chosen list of someone away continues with the order');
select is((select first_only from cmp where id = :'w6'), null, '7. nobody left when everyone is away');

-- The board and Instructor requests give the same answers as before.
select tests.login_member(:'ops_email');
select is((select count(*)::int from jsonb_array_elements(public.planned_instructors(array(select id from cmp))) p
            where p -> 'planned' ->> 'name' is distinct from (select full_line from cmp where id = (p ->> 'module_week_id')::uuid)),
  0, '8. planned instructors name the same people');
select is((select count(*)::int from cmp c
            where (public.next_in_line_many(array[c.id]) -> c.id::text ->> 'next') is distinct from (public.preview_next(c.id) ->> 'next')),
  0, '9. Instructor requests shows the same next person as the whole line');
-- The domain's planned instructors in one call: every coming class week nobody is confirmed for, same answers.
select is((select count(*)::int from jsonb_array_elements(public.planned_instructors_for_domain(:'dom'))), 6,
  '10. the domain call covers every coming class week nobody is confirmed for');
select is((select count(*)::int from jsonb_array_elements(public.planned_instructors_for_domain(:'dom')) d
            join jsonb_array_elements(public.planned_instructors(array(select id from cmp))) p
              on p ->> 'module_week_id' = d ->> 'module_week_id'
           where p is distinct from d), 0, '11. with the same answer for each as planned_instructors');
select tests.as_postgres();

select * from finish();
rollback;
