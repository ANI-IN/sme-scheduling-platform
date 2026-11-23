-- Release 3, M9 (decision 302): an instructor proposes another time; Ops accepts or rejects.
begin;
\ir ../helpers/helpers.psql
select plan(26);

select tests.scenario('TP', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'mw') as w1,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
select id as live1 from public.class_session where module_week_id = :'w1' and class_type = 'Live class' \gset
select id as rev1 from public.class_session where module_week_id = :'w1' and class_type = 'Assignment review' \gset

create or replace function tests.form(p_token text, variadic p_rows text[]) returns jsonb language sql as $$
  -- p_rows: class id, date, start, end, for each class in order.
  select jsonb_build_object('t', p_token) || coalesce((select jsonb_object_agg(k, v) from (
    select x.k, x.v from generate_series(0, cardinality(p_rows) / 4 - 1) g,
      lateral (values ('c_' || (g + 1), p_rows[g * 4 + 1]), ('d_' || (g + 1), p_rows[g * 4 + 2]),
                      ('s_' || (g + 1), p_rows[g * 4 + 3]), ('e_' || (g + 1), p_rows[g * 4 + 4])) x(k, v)) s), '{}');
$$;
create or replace function tests.local(p_class uuid) returns text language sql as $$
  select to_char(starts_at at time zone 'America/Los_Angeles', 'Dy Mon DD HH24:MI') from public.class_session where id = p_class;
$$;

-- =============================================================== 1. the answer
insert into public.request (module_week_id, instructor_id, kind, status, time_version, sent_at, deadline_at)
values (:'w1', :'i1', 'Outreach', 'Sent', (select time_version from public.module_week where id = :'w1'), now(), now() + interval '1 day')
returning id as q1 \gset
select is((select string_agg(b ->> 'label', ' | ') from jsonb_array_elements(private.buttons(:'q1', array['Yes', 'No'])) b),
  '✅ Yes, I can teach | ❌ No, I can''t | 🕒 Propose another time', '1. the request to teach offers Propose another time');
select is(jsonb_array_length(private.buttons(:'q1', array['AllSet', 'NeedHelp'])), 2, '2. other messages keep their buttons');
select tests.token(:'w1', :'i1', 'ProposeTime') as tok1 \gset
select ok(public.response_page_text(:'tok1') like '%<h1>Propose another time</h1>%name="d_1"%US Pacific time%name="note"%',
  '3. the page shows each class with its date and times in its time zone, and a note');

-- =============================================================== 2. sending a proposal
select alike(public.submit_response_page_text(:'tok1', tests.form(:'tok1', :'live1', '2027-01-31', '09:00', '13:00', :'rev1', '2027-02-04', '18:00', '20:00')),
  '%These are the same times.%', '4. the same times are not a proposal');
select alike(public.submit_response_page_text(:'tok1', tests.form(:'tok1', :'live1', '2027-03-14', '02:30', '06:00', :'rev1', '2027-02-04', '18:00', '20:00')),
  '%does not exist in US Pacific time%', '5. a time that does not exist is refused');
select alike(public.submit_response_page_text(:'tok1', tests.form(:'tok1', :'live1', '2027-01-31', '10:00', '14:00', :'rev1', '2027-02-04', '18:00', '20:00')),
  '%<h1>Thanks!</h1><p>The team checks your proposed time with the cohort and replies to you soon.%', '6. a new time is sent');
select id as p1 from public.time_proposal where module_week_id = :'w1' \gset
select is((select status || ' ' || jsonb_array_length(proposed) || ' ' || (select count(*) from jsonb_array_elements(proposed) x where (x ->> 'changed')::boolean)
             from public.time_proposal where id = :'p1'), 'Pending 2 1', '7. the proposal keeps each class, as it is and as proposed');
select is(tests.open_items(:'dom', 'TimeProposal'), 1, '8. a task goes to the operations team');
select ok(tests.msgs(:'w1', 'M18') > 0, '9. the instructor is told the team will reply');
select is((select status from public.request where id = :'q1') || ' ' || tests.local(:'live1'), 'Sent Sun Jan 31 09:00',
  '10. nothing changes yet: the request stays open and the class keeps its time');
select ok(exists (select 1 from jsonb_array_elements(private.week_problems(:'w1')) x where x ->> 'code' = 'proposed_time' and x -> 'fixes' ? 'accept_proposal'),
  '11. the class week shows the proposed time to decide');
select alike(public.response_page_text(:'tok1'), '%Already%', '12. the link does not take a second proposal');

-- =============================================================== 3. accepting a proposal on a request to teach
select is(jsonb_array_length(public.time_proposal_preview(:'p1') -> 'blocks'), 0, '13. nothing blocks it');
select is((public.decide_time_proposal(:'p1', true) ->> 'confirmed')::boolean, true, '14. accepting confirms the instructor');
select is(tests.booked(:'w1') || ' ' || tests.local(:'live1') || ' ' || (select answer from public.request where id = :'q1'),
  'TP Instr1 Sun Jan 31 10:00 ProposeTime', '15. at the proposed time');
select is(to_char((select previous_starts_at from public.class_session where id = :'live1') at time zone 'America/Los_Angeles', 'HH24:MI'), '09:00',
  '16. the class keeps its previous time, for the Moved badge');
select ok(tests.msgs(:'w1', 'M4') > 0 and tests.open_items(:'dom', 'TimeProposal') = 0, '17. the confirmation is sent and the task is done');

-- =============================================================== 4. a confirmed instructor proposes after a time change
select tests.make_week(:'m1', '2027-02-14') as w2 \gset
select tests.raw_book(:'w2', :'i2');
update public.booking set time_version_confirmed = (select time_version from public.module_week where id = :'w2') where module_week_id = :'w2';
select id as live2 from public.class_session where module_week_id = :'w2' and class_type = 'Live class' \gset
select id as rev2 from public.class_session where module_week_id = :'w2' and class_type = 'Assignment review' \gset
select public.change_class_time(:'live2', '2027-02-14', '14:00', '18:00');
select ok(exists (select 1 from jsonb_array_elements(private.week_problems(:'w2')) x where x ->> 'code' = 'waiting_new_time'),
  '18. after a time change the class week waits for the instructor to confirm the new time');
select is((select jsonb_array_length(buttons) from public.message where module_week_id = :'w2' and template_id = 'M5' and channel = 'Email'), 3,
  '19. the time change message offers Propose another time too');
-- Instr2 also teaches another module from 9:00 to 13:00 that Sunday.
select tests.make_module(:'dom', 'TP Other', 2) as m2 \gset
select tests.make_week(:'m2', '2027-02-14') as ow \gset
delete from public.class_session where module_week_id = :'ow' and class_type = 'Assignment review';
select tests.raw_book(:'ow', :'i2');
select tests.token(:'w2', :'i2', 'ProposeTime') as tok2 \gset
select public.submit_response_page_text(:'tok2', tests.form(:'tok2', :'live2', '2027-02-14', '12:00', '16:00', :'rev2', '2027-02-18', '18:00', '20:00'));
select id as p2 from public.time_proposal where module_week_id = :'w2' and status = 'Pending' \gset
select ok(exists (select 1 from jsonb_array_elements_text(public.time_proposal_preview(:'p2') -> 'blocks') b where b like 'TP Instr2 is in two classes at once.%'),
  '20. a proposal that clashes with the instructor''s other class blocks');
select is((public.decide_time_proposal(:'p2', true) ->> 'ok')::boolean, false, '21. so it can''t be accepted');
select public.decide_time_proposal(:'p2', false, 'We need the morning for the cohort.');
select alike((select (jsonb_array_length(buttons))::text || ' ' || body_text from public.message
               where module_week_id = :'w2' and template_id = 'M20' and channel = 'Email'),
  '3 %We need the morning for the cohort.%', '22. rejecting tells them, with their answers again');
select public.submit_response_page_text(:'tok2', tests.form(:'tok2', :'live2', '2027-02-14', '15:00', '19:00', :'rev2', '2027-02-18', '18:00', '20:00'));
select id as p3 from public.time_proposal where module_week_id = :'w2' and status = 'Pending' \gset
select tests.msgs(:'w2', 'M5') as m5_before \gset
select public.decide_time_proposal(:'p3', true);
select is((select (b.time_version_confirmed = w.time_version)::text || ' ' || tests.local(:'live2') from public.booking b join public.module_week w on w.id = b.module_week_id
            where b.module_week_id = :'w2' and b.status = 'Active'), 'true Sun Feb 14 15:00',
  '23. accepting keeps them confirmed at their proposed time');
select is(tests.msgs(:'w2', 'M5') - :m5_before, 0, '24. without asking them again about the time they proposed');

-- =============================================================== 5. a proposal made before the times changed again
select public.change_class_time(:'live2', '2027-02-14', '16:00', '20:00');
select public.submit_response_page_text(tests.token(:'w2', :'i2', 'ProposeTime'),
  tests.form(tests.token(:'w2', :'i2', 'ProposeTime'), :'live2', '2027-02-14', '17:00', '21:00', :'rev2', '2027-02-18', '18:00', '20:00'));
select id as p4 from public.time_proposal where module_week_id = :'w2' and status = 'Pending' \gset
select public.change_class_time(:'live2', '2027-02-14', '13:30', '17:30');
select ok(exists (select 1 from jsonb_array_elements_text(public.time_proposal_preview(:'p4') -> 'blocks') b where b like 'The class times changed after this proposal was made%'),
  '25. a proposal made before the times changed again can''t be accepted');
select ok(exists (select 1 from public.history_event where action = 'Proposed time accepted: TP Instr1')
          and exists (select 1 from public.history_event where action = 'Proposed time rejected: TP Instr2'), '26. Activity history has the decisions');

select * from finish();
rollback;
