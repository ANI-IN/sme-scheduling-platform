-- Release Milestone 8: problems found by the end to end tests.
begin;
\ir ../helpers/helpers.psql
select plan(5);

-- Times built by the database read "9:00 AM to 1:00 PM", never with a dash.
select is(private.fmt_pt_range('2027-01-31 17:00+00', '2027-01-31 21:00+00'), 'Sun, Jan 31 · 9:00 AM to 1:00 PM PST',
  'a time range uses "to"');
select ok(private.fmt_pt_range('2027-07-04 16:00+00', '2027-07-04 20:00+00') !~ '[–—]', 'also in summer time');

select tests.scenario('FX', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
insert into public.instructor_unavailability (instructor_id, from_date, to_date) values (:'i1', '2027-01-25', '2027-02-05');
select is(private.eligibility(:'i1', :'mw'), 'Unavailable Jan 25 to Feb 5', 'unavailable dates use "to"');

-- First sign in: the app may ask twice at once. The second call finds the new row.
select tests.login_google('first.time@example.com');
select is(public.my_account(true) -> 'member' ->> 'email', 'first.time@example.com', 'the first call creates the team member');
select tests.as_postgres();
-- The second request was already on its way and also saw no row: it must not fail.
update public.team_member set name = name where email = 'first.time@example.com';
select tests.login_google('first.time@example.com');
select lives_ok($$ select public.my_account(true) $$, 'a second call at the same moment does not fail');
select tests.as_postgres();

select * from finish();
rollback;
