-- Release 3, owner's item 1: the database writes a class week's status in the same words as the board
-- (Confirmed, Waiting for an answer, Needs instructor, Proposed time, Not asked yet, Setup incomplete, Paused,
-- Cancelled, Completed), never "Asking" or a status code such as NotReady (docs/GLOSSARY.md).
begin;
\ir ../helpers/helpers.psql
select plan(14);

-- =============================================================== the practice class
select tests.scenario('SZ', 'Test', '2027-01-31', 2) as m \gset
select (:'m'::jsonb ->> 'domain') as dom4 \gset
select tests.make_instructor('SZ Tester A', true, true), tests.make_instructor('SZ Tester B', true, true);
select tests.login_as('ops@example.com');
select public.run_practice_class(:'dom4') as practice \gset
select tests.as_postgres();
select is((select s ->> 'detail' from jsonb_array_elements(:'practice'::jsonb -> 'steps') s where s ->> 'step' = 'Setup check passes'),
  'Status: Not asked yet', '1. the practice class names the status in the board''s words');
select is((select count(*)::int from jsonb_array_elements(:'practice'::jsonb -> 'steps') s where not (s ->> 'passed')::boolean), 0,
  '2. and still passes every stage');

-- =============================================================== the words, one status at a time
select tests.scenario('SW', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'mw') as w1,
       (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.make_week(:'m1', '2027-02-07') as w2 \gset
select tests.make_week(:'m1', '2027-02-14') as w3 \gset
select tests.at('2027-01-10 12:00+00');

select is(private.week_status_text(:'w1', now()), 'Not asked yet', '3. nobody asked yet: Not asked yet');
update public.module_week set status = 'NotReady' where id = :'w2';
select is(private.week_status_text(:'w2', now()), 'Setup incomplete', '4. NotReady: Setup incomplete');
update public.module_week set paused = true where id = :'w3';
select is(private.week_status_text(:'w3', now()), 'Paused', '5. paused: Paused');
update public.module_week set paused = false, status = 'NeedsInstructor' where id = :'w3';
select is(private.week_status_text(:'w3', now()), 'Needs instructor', '6. NeedsInstructor: Needs instructor');
update public.module_week set at_risk = true, at_risk_reason = 'SW test' where id = :'w2';
select is(private.week_status_text(:'w2', now()), 'Needs instructor', '7. at risk with nobody asked: Needs instructor');
insert into public.request (module_week_id, instructor_id, kind, status, time_version, sent_at, deadline_at)
values (:'w1', :'i1', 'Outreach', 'Sent', 1, '2027-01-10 06:00+00', '2027-01-12 06:00+00');
update public.module_week set status = 'Asking' where id = :'w1';
select is(private.week_status_text(:'w1', now()), 'Waiting for an answer: SW Instr1',
  '8. Asking: Waiting for an answer, with who is asked');
update public.module_week set status = 'Cancelled' where id = :'w3';
select is(private.week_status_text(:'w3', now()), 'Cancelled', '9. Cancelled: Cancelled');
select is((select count(*)::int from public.module_week w cross join lateral (select private.board_status(w.id, now()) as b) x
            where w.domain_id = :'dom' and private.week_status_text(w.id, now()) not like
              (case x.b ->> 'status' when 'Waiting' then 'Waiting for an answer' else x.b ->> 'status' end) || '%'), 0,
  '10. the same status as the board for every class week');

-- =============================================================== the owner check in (T11)
select tests.scenario('SX', 'Live', '2027-01-31', 3) as k \gset
select (:'k'::jsonb ->> 'domain') as dom2, (:'k'::jsonb ->> 'mw') as x1, (:'k'::jsonb ->> 'i1') as x_i1,
       (:'k'::jsonb ->> 'owner') as owner2 \gset
select tests.tick(:'dom2', '2027-01-01 18:00+00');
select tests.click(:'x1', :'x_i1', 'Yes');
select tests.tick(:'dom2', '2027-01-17 18:00+00');   -- 14 days before
select ok((select body_text from public.message where template_id = 'T11' and team_member_id = :'owner2' and domain_id = :'dom2') like '%Confirmed: SX Instr1%',
  '11. a confirmed class week: Confirmed with the instructor');

select tests.scenario('SY', 'Live', '2027-01-31', 3) as l \gset
select (:'l'::jsonb ->> 'domain') as dom3, (:'l'::jsonb ->> 'owner') as owner3 \gset
select tests.tick(:'dom3', '2027-01-17 18:00+00');   -- 14 days before, not confirmed
select ok((select body_text from public.message where template_id = 'T11' and team_member_id = :'owner3' and domain_id = :'dom3')
            ~ '(Not asked yet|Waiting for an answer: SY Instr1)',
  '12. a class week not confirmed yet: Not asked yet or Waiting for an answer');
select ok(not exists (select 1 from public.message where template_id = 'T11' and domain_id in (:'dom2', :'dom3')
                       and body_text ~ '\m(Asking|Planned|NotReady|Ready|NeedsInstructor)\M'),
  '13. no owner check in says Asking or a status code');
select ok((select prosrc from pg_proc where oid = 'private.step_owner_checkins(uuid, timestamptz)'::regprocedure)
            !~ '''Asking ''', '14. the owner check in no longer writes "Asking"');

select * from finish();
rollback;
