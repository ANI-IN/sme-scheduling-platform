-- Regression guard (owner, 24 November 2026): fails if any later migration undoes a fix that is live. Every fix is
-- checked by what it does, plus the marker of each function that must keep it (the r3-m6 merge redefined several).
begin;
\ir ../helpers/helpers.psql
select plan(14);
create function pg_temp.def(text, text) returns text language sql as $$
  select string_agg(pg_get_functiondef(p.oid), ' ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $1 and p.proname = $2 $$;

-- Sending at any hour (decision 332).
select tests.scenario('KA', 'Live', '2027-01-31', 2) as a \gset
select (:'a'::jsonb ->> 'domain') as adom, (:'a'::jsonb ->> 'mw') as amw, (:'a'::jsonb ->> 'i1') as ai1 \gset
select is(private.instructor_send_time(:'adom', '2027-01-01 07:00+00', false, 'US', :'ai1'), '2027-01-01 07:00+00'::timestamptz,
  '1. any hour: 11:00 PM Pacific goes at once while quiet hours are off');
select tests.tick(:'adom', '2027-01-01 07:00+00');
select ok(exists (select 1 from public.message where module_week_id = :'amw' and template_id = 'M1')
          and not exists (select 1 from public.message where module_week_id = :'amw' and template_id = 'M1' and not_before <> '2027-01-01 07:00+00'),
  '2. any hour: the request itself goes at once');
-- Both times in instructor messages (decision 332).
select ok(exists (select 1 from public.message where module_week_id = :'amw' and template_id = 'M1' and channel = 'Email'
                    and body_text ~ 'P[SD]T \([^)]*IST\)' and body_text ~ 'reply by [^\n]*P[SD]T / [^\n]*IST\.'),
  '3. both times: class times and the reply by time in US Pacific and India time');

-- Never Asking with nobody asked (decision 332).
update public.instructor set status = 'Inactive' where id = :'ai1';
select private.withdraw_open_request(:'amw', 'test', '2027-01-01 07:30+00', false);
set constraints all immediate;
select is(tests.asking(:'amw'), 'KA Instr2', '4. never Asking with nobody asked: the next instructor is asked when the change is saved');
set constraints all deferred;
select ok(position('settle_asking_weeks' in pg_temp.def('private', 'clock_tick')) > 0,
  '5. and the clock still sweeps');
select ok(exists (select 1 from pg_trigger where tgname = 'request_closed_settle'),
  '6. the check on saving is in place');

-- Release from (decision 331).
select ok(position('press Release from' in pg_temp.def('public', 'record_discord_result')) > 0
          and position('discord_held_by' in pg_temp.def('public', 'record_discord_result')) > 0,
  '7. Release from: the Discord result names the holder and offers Release from');
select ok(position('Discord account released from' in pg_temp.def('public', 'record_discord_result')) > 0,
  '8. archived instructors release the account by themselves');
select ok(to_regprocedure('public.release_discord_account(uuid)') is not null, '9. Release from exists');

-- Nothing stays Checking, and the domain status rules (decision 331).
select ok(position('expire_stuck_checks' in pg_temp.def('private', 'clock_tick')) > 0,
  '10. the clock ends checks that never came back');
select ok(position('domain_status_problems' in pg_temp.def('public', 'set_domain_status')) > 0,
  '11. a domain status says what is missing');

-- Draft domains and the instructor's time zone (decision 333).
select ok(position('is a draft domain' in pg_temp.def('private', 'queue_instructor_message')) > 0, '12. a Draft domain creates no instructor message');
select ok(position('p_instructor)' in pg_temp.def('private', 'queue_instructor_message')) > 0, '13. messages use the instructor''s own time zone');
select ok(position('b.instructor_id)' in pg_temp.def('private', 'step_checkins')) > 0,
  '14. check in reply by times use the instructor''s own time zone');

select * from finish();
rollback;
