-- Leftover work of 24 November (decision 340): the clock's request step acts on each request as it is now, never on
-- the copy taken when its loop started. Asking for a sooner class can withdraw a later week's request ("Sooner
-- class") and ask someone else there in the same run; the old copy then still read "Sent", and the step reopened the
-- withdrawn request as Reminded next to its replacement. The database refused (one open request per class week) and
-- the whole clock run of the domain failed. Found by the practice class on the merged branch.
begin;
\ir ../helpers/helpers.psql
select plan(9);

select tests.scenario('RL', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
insert into public.cohort (domain_id, name, region, start_date) values (:'dom', 'RL Early', 'US', '2027-01-02') returning id as ca \gset
insert into public.cohort (domain_id, name, region, start_date) values (:'dom', 'RL Late', 'US', '2027-01-09') returning id as cb \gset

create or replace function tests.week(p_mod uuid, p_coh uuid, p_date date, p_start time, p_end time)
returns uuid language sql as $$
  select (public.add_one_class(null, p_mod, p_coh, p_date, p_start, p_end, 'Live class', null, true, 'Test class: the time is chosen on purpose', null, 1) ->> 'module_week_id')::uuid;
$$;
create or replace function tests.open_req(p_mw uuid)
returns public.request language sql as $$
  select * from public.request where module_week_id = p_mw and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded');
$$;

-- The sooner class week asks the Primary first.
select tests.week(:'mod', :'ca', '2027-02-06', '09:00', '13:00') as wa \gset
select tests.tick(:'dom', '2027-01-08 18:00+00');
select (tests.open_req(:'wa')).id as a_req, (tests.open_req(:'wa')).deadline_at as a_deadline \gset
-- An hour later a later, overlapping class week appears; the Primary is busy, so it asks Backup 1.
select tests.week(:'mod', :'cb', '2027-02-06', '10:00', '12:00') as wb \gset
select tests.tick(:'dom', '2027-01-08 19:00+00');
select (tests.open_req(:'wb')).id as b_req \gset
select is(tests.asking(:'wa') || ' / ' || tests.asking(:'wb'), 'RL Instr1 / RL Instr2',
  '1. the sooner week asks the Primary, the later one Backup 1');

-- The run after the sooner week's reply time: the later week's request is due its reminder, not yet past its time.
select (:'a_deadline'::timestamptz + interval '1 minute') as t3 \gset
select ok((select reminder_at <= :'t3'::timestamptz and deadline_at > :'t3'::timestamptz from public.request where id = :'b_req'),
  '2. set up: in that run the later week''s request is due its reminder');

select lives_ok($$ select tests.tick('$$ || :'dom' || $$', '$$ || :'t3' || $$') $$,
  '3. the clock run finishes (it failed with "one open request per class week")');
select is((select status || ' / ' || close_reason from public.request where id = :'a_req'), 'Expired / No reply',
  '4. the sooner week''s request ran out');
select is(tests.asking(:'wa'), 'RL Instr2', '5. the sooner week now asks Backup 1');
select is((select status || ' / ' || close_reason from public.request where id = :'b_req'), 'Withdrawn / Sooner class',
  '6. the later week''s request stays withdrawn: it is not reopened as Reminded');
-- The Primary is free again (their request for the sooner week ran out), so the later week asks them.
select is(tests.asking(:'wb'), 'RL Instr1', '7. the later week asks its next free instructor, the Primary');
select is((select count(*)::int from public.request where module_week_id = :'wb' and kind = 'Outreach'
             and status in ('Queued', 'Sent', 'Reminded')), 1, '8. the later week has exactly one open request');
select is((select count(*)::int from public.message where request_id = :'b_req' and template_id in ('M2', 'M3')), 0,
  '9. Backup 1 gets no reminder and no "no reply" message for the withdrawn request');

select * from finish();
rollback;
