-- Leftover work of 24 November 2026: the reliability items the owner asked to see proven that had no direct test.
-- (1) Two people acting on the same class week: the second is refused with a clear message, never applied on top.
-- (2) Both times across the clock changes of March and November (US Pacific changes, India does not).
-- (3) A class week that is cancelled (for example for a holiday) or paused gets no message.
begin;
\ir ../helpers/helpers.psql
select plan(15);

select tests.scenario('RY', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'ops') as ops \gset
select email as ops_email from public.team_member where id = :'ops' \gset

-- =============================================================== 1. two people on the same class week
select tests.login_member(:'ops_email');
select lives_ok($$ select public.assign_manually('$$ || :'mw' || $$', '$$ || :'i1' || $$') $$,
  '1. the first person assigns an instructor');
select throws_like($$ select public.assign_manually('$$ || :'mw' || $$', '$$ || :'i2' || $$') $$,
  '%already%', '2. the second person, assigning someone else, is refused with a reason');
select tests.as_postgres();
select is(tests.booked(:'mw'), 'RY Instr1', '3. the first choice stands: nothing was overwritten');
-- Rows the app may edit directly carry a version: a save made from an old copy is refused (decision of M2).
select (select version from public.module where id = :'mod') as ver \gset
update public.module set name = 'RY first save', version = :'ver' where id = :'mod';
select throws_ok(format('update public.module set name = %L, version = %s where id = %L', 'RY second save', :'ver', :'mod'),
  '40001', null, '4. a second save from the same old copy is told to reload');
select is((select name from public.module where id = :'mod'), 'RY first save', '5. and the first save stays');

-- =============================================================== 2. both times across the clock changes
select is(private.fmt_local_both('2027-03-07 17:00+00', 'US'), 'Sun, Mar 7 · 9:00 AM PST / 10:30 PM IST',
  '6. the Sunday before the March change: PST, India 13 hours 30 minutes ahead');
select is(private.fmt_local_both('2027-03-14 16:00+00', 'US'), 'Sun, Mar 14 · 9:00 AM PDT / 9:30 PM IST',
  '7. the first Sunday after it: PDT, India 12 hours 30 minutes ahead');
select is(private.fmt_local_both('2027-10-31 16:00+00', 'US'), 'Sun, Oct 31 · 9:00 AM PDT / 9:30 PM IST',
  '8. the Sunday before the November change: still PDT');
select is(private.fmt_local_both('2027-11-07 17:00+00', 'US'), 'Sun, Nov 7 · 9:00 AM PST / 10:30 PM IST',
  '9. the first Sunday after it: back to PST');
select is(private.fmt_local_both('2027-03-14 13:30+00', 'India'), 'Sun, Mar 14 · 7:00 PM IST / 6:30 AM PDT',
  '10. an India class keeps its India time, and its Pacific time follows the change');
select is(public.pt_to_utc('2027-03-14', '09:00') - public.pt_to_utc('2027-03-07', '09:00'), interval '6 days 23 hours',
  '11. a weekly US class keeps 9:00 AM Pacific across the change (the week is an hour shorter)');

-- =============================================================== 3. cancelled or paused: no message
select tests.make_week(:'mod', '2027-02-07') as mw_c \gset
select tests.make_week(:'mod', '2027-02-14') as mw_p \gset
select tests.login_member(:'ops_email');
select public.cancel_module_week(:'mw_c', 'Holiday: no class this week');
select public.pause_outreach(:'mw_p', true);
select tests.as_postgres();
select tests.tick(:'dom', '2027-01-15 18:00+00');
select is((select count(*)::int from public.message where module_week_id = :'mw_c' and template_id in ('M1', 'M2')), 0,
  '12. a class week cancelled for a holiday gets no request');
select is((select count(*)::int from public.message where module_week_id = :'mw_p' and template_id in ('M1', 'M2')), 0,
  '13. a paused class week gets no request');
select is((select count(*)::int from public.request where module_week_id in (:'mw_c', :'mw_p') and kind = 'Outreach'), 0,
  '14. and nobody is asked for either');
-- Control: the same run time does ask for a class week that is neither cancelled nor paused.
select tests.login_member(:'ops_email');
select public.pause_outreach(:'mw_p', false);
select tests.as_postgres();
select tests.tick(:'dom', '2027-01-15 19:00+00');
select ok(tests.asking(:'mw_p') is not null, '15. once resumed, the same class week is asked at the next run');

select * from finish();
rollback;
