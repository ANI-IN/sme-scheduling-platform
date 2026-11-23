-- Release 3, M12a (decision 305): the Schedule board's data.
begin;
\ir ../helpers/helpers.psql
select plan(12);

select tests.scenario('SB', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'mw') as w1,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
select tests.make_week(:'m1', '2027-02-07') as w2 \gset
select tests.make_week(:'m1', '2027-02-14') as w3 \gset
select tests.make_week(:'m1', '2027-02-21') as w4 \gset
select tests.make_week(:'m1', '2027-02-28') as w5 \gset
select tests.make_week(:'m1', '2027-03-07') as w6 \gset
select tests.raw_book(:'w1', :'i1');
insert into public.request (module_week_id, instructor_id, kind, status, time_version, sent_at, deadline_at)
values (:'w2', :'i2', 'Outreach', 'Sent', 1, now(), now() + interval '6 hours');
update public.module_week set status = 'NeedsInstructor', at_risk = true where id = :'w3';
update public.module_week set paused = true where id = :'w4';
select public.cancel_module_week(:'w5');
-- Instr1 also teaches the sixth week's time elsewhere: a clash to decide.
select tests.make_module(:'dom', 'SB Other', 2) as m2 \gset
select tests.make_week(:'m2', '2027-03-07') as ow \gset
select tests.raw_book(:'ow', :'i1');
insert into public.request (module_week_id, instructor_id, kind, status, time_version, sent_at, deadline_at)
values (:'w6', :'i1', 'Outreach', 'Sent', 1, now(), now() + interval '5 days');

select public.schedule_board(:'dom', '2027-01-31', '2027-03-07') as b \gset
create or replace function tests.cell(p_board jsonb, p_mw uuid) returns jsonb language sql as $$
  select x from jsonb_array_elements(p_board -> 'weeks') x where x ->> 'id' = p_mw::text;
$$;

select is(tests.cell(:'b', :'w1') ->> 'status' || ' ' || (tests.cell(:'b', :'w1') ->> 'instructor'), 'Confirmed SB Instr1', '1. a confirmed class week');
select is(tests.cell(:'b', :'w2') ->> 'status' || ' ' || (tests.cell(:'b', :'w2') ->> 'instructor'), 'Waiting SB Instr2', '2. waiting for an answer, with who');
select ok(tests.cell(:'b', :'w2') -> 'badges' ? 'answer_due_soon', '3. under 12 hours left to answer is a badge');
select is(tests.cell(:'b', :'w3') ->> 'status', 'Needs instructor', '4. needs an instructor');
select is(tests.cell(:'b', :'w4') ->> 'status', 'Paused', '5. paused');
select is(tests.cell(:'b', :'w5') ->> 'status', 'Cancelled', '6. cancelled');
select is(tests.cell(:'b', :'w6') ->> 'status' || ' ' || (tests.cell(:'b', :'w6') -> 'badges' ? 'clash')::text, 'Waiting true',
  '7. a clash is a badge on the cell');
select is((:'b'::jsonb -> 'decisions' ->> 'clash')::int || ' ' || (:'b'::jsonb -> 'decisions' ->> 'needs_instructor'), '1 1',
  '8. Needs a decision counts each problem');
select is((select string_agg(x ->> 'name' || ' ' || (x ->> 'mode'), ', ') from jsonb_array_elements(:'b'::jsonb -> 'cohorts') x),
  'Main cohort Fully custom', '9. each cohort has its column, with Standard or Custom');
select ok(tests.cell(:'b', :'ow') is not null, '10. every module of the domain is on the board');

-- Past class weeks are read only: their status, no problems.
select tests.at('2027-04-01 00:00+00');
select is(jsonb_array_length(tests.cell(public.schedule_board(:'dom', '2027-01-31', '2027-03-07'), :'w6') -> 'problems'), 0,
  '11. a past class week has no problems to decide');
select throws_like(format($$ select public.schedule_board(%L, '2027-01-01', '2027-12-31') $$, :'dom'),
  'Show at most 27 weeks at a time.', '12. the board reads at most 27 weeks at a time');

select * from finish();
rollback;
