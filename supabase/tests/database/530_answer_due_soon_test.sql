-- Release 3 review: "Answer due soon" only when the answer is due within a setting's hours (default 12).
begin;
\ir ../helpers/helpers.psql
select plan(9);

select tests.scenario('DS', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as m1, (:'j'::jsonb ->> 'mw') as w1,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
select tests.make_week(:'m1', '2027-02-07') as w2 \gset
select tests.make_week(:'m1', '2027-02-14') as w3 \gset
select tests.at('2027-01-10 12:00+00');
-- Waiting for an answer: due in 6 hours, in 24 hours, and no answer asked at all.
insert into public.request (module_week_id, instructor_id, kind, status, time_version, sent_at, deadline_at)
values (:'w1', :'i1', 'Outreach', 'Sent', 1, '2027-01-10 06:00+00', '2027-01-10 18:00+00'),
       (:'w2', :'i2', 'Outreach', 'Sent', 1, '2027-01-10 06:00+00', '2027-01-11 12:00+00');
create or replace function tests.badges(p_dom uuid, p_mw uuid) returns jsonb language sql as $$
  select x -> 'badges' from jsonb_array_elements(public.schedule_board(p_dom, '2027-01-31', '2027-02-14') -> 'weeks') x
   where x ->> 'id' = p_mw::text;
$$;

select is((select default_value from public.setting_definition where key = 'answer_due_soon_h'), '12'::jsonb,
  '1. the setting is 12 hours by default');
select ok(tests.badges(:'dom', :'w1') ? 'answer_due_soon', '2. an answer due in 6 hours is due soon');
select ok(not tests.badges(:'dom', :'w2') ? 'answer_due_soon', '3. an answer due in 24 hours is not due soon');
select ok(not tests.badges(:'dom', :'w3') ? 'answer_due_soon', '4. a class week nobody is asked about has no badge');

-- The domain changes it: 48 hours.
select public.set_setting_at('Domain', :'dom', 'answer_due_soon_h', '48');
select ok(tests.badges(:'dom', :'w2') ? 'answer_due_soon', '5. with 48 hours, an answer due in 24 hours is due soon');
-- A cohort can change it for its own classes.
select public.set_setting_at('Cohort', (select cohort_id from public.module_week where id = :'w2'), 'answer_due_soon_h', '3');
select ok(not tests.badges(:'dom', :'w2') ? 'answer_due_soon', '6. the cohort''s own number wins');

select throws_ok(format($$ select public.set_setting_at('Domain', %L, 'answer_due_soon_h', '0') $$, :'dom'), null, null,
  '7. less than 1 hour is refused');
select throws_ok(format($$ select public.set_setting_at('Domain', %L, 'answer_due_soon_h', '169') $$, :'dom'), null, null,
  '8. more than 168 hours (a week) is refused');
select ok(exists (select 1 from jsonb_array_elements(to_jsonb(public.effective_settings_for('Domain', :'dom'))) s
                   where s ->> 'key' = 'answer_due_soon_h'), '9. it is on the settings page');

select * from finish();
rollback;
