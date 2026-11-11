-- Final round before the demo (decisions 271 and 272): one open task per class week, the same plain words
-- everywhere, and one "Setup check passed" per module per run.
begin;
\ir ../helpers/helpers.psql
select plan(8);

select tests.scenario('FR', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'module') as mod,
       (:'j'::jsonb ->> 'i1') as i1 \gset

-- A class at risk task is open for the week, then nobody is left to ask.
insert into public.attention_item (domain_id, type, severity, title, detail, module_week_id, module_id, dedupe_key)
values (:'dom', 'ClassAtRisk', 'Urgent', 'At risk: FR week', 'We''ve started asking the next instructor.', :'mw', :'mod', 'atrisk:' || :'mw');
update public.instructor set status = 'Inactive', version = version where id = :'i1';
select private.ask_next(:'mw', '2027-01-02 18:00+00');

select is((select status from public.attention_item where module_week_id = :'mw' and type = 'ClassAtRisk'), 'Done',
  'one 1. the class at risk task is marked done when nobody is left to ask');
select is((select count(*)::int from public.attention_item where module_week_id = :'mw' and status <> 'Done'), 1,
  'one 2. the class week has one open task');
select ok(exists (select 1 from public.history_event where action = 'Class at risk task closed' and module_week_id = :'mw'),
  'one 3. closing it is in Activity history');
select ok((select detail like '%Assign someone manually or add instructors to the instructor order.%'
             from public.attention_item where module_week_id = :'mw' and type = 'RankingExhausted'),
  'words 1. nobody left: "Assign someone manually or add instructors to the instructor order."');
select ok(exists (select 1 from public.history_event where action = 'Nobody left to ask' and module_week_id = :'mw'),
  'words 2. Activity history says "Nobody left to ask"');
select ok((select prosrc like '%We''''ve started asking the next instructor.%' and prosrc not like '%Outreach has restarted%'
             from pg_proc where proname = 'release_booking_flow'),
  'words 3. a class at risk says "We''ve started asking the next instructor."');

-- Two cohorts of one module pass the setup check at the same moment: one entry.
update public.instructor set status = 'Active', version = version where id = :'i1';
select tests.make_week(:'mod', '2027-02-14', 'US cohort') as w2 \gset
select tests.make_week(:'mod', '2027-02-14', 'India cohort') as w3 \gset
select private.step_readiness(:'dom', '2027-01-20 18:00+00');
select is((select count(*)::int from public.history_event where action = 'Readiness check passed' and module_id = :'mod'), 1,
  'setup 1. "Setup check passed" is logged once for the module, not once per class week');
select ok((select count(*) from public.module_week where id in (:'w2', :'w3') and status = 'Ready') = 2,
  'setup 2. both class weeks still pass the check');

select * from finish();
rollback;
