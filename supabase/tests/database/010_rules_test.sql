-- M1: rules the database enforces (PRD §6.2, §20.1).
begin;
select plan(44);
select tests.company();

-- Fixture: two domains sharing one instructor.
create temp table fx as
with d as (select tests.make_domain('Backend-T') as b, tests.make_domain('Fullstack-T') as f)
select d.b as dom_b, d.f as dom_f,
       tests.make_module(d.b, 'Concurrency') as mod_b,
       tests.make_module(d.f, 'React') as mod_f,
       tests.make_instructor('Shared Person') as shared,
       tests.make_instructor('Other Person') as other
from d;
grant select on fx to authenticated;

-- Both module weeks start Sun Jan 31 2027 (same Sunday 9:00 PT live class).
create temp table wk as
select tests.make_week((select mod_b from fx), '2027-01-31') as mw_b,
       tests.make_week((select mod_f from fx), '2027-01-31') as mw_f,
       tests.make_week((select mod_f from fx), '2027-01-31', 'B') as mw_f2;

-- ---------------------------------------------------------------- overlapping bookings
select lives_ok($$ select tests.raw_book((select mw_b from wk), (select shared from fx)) $$,
  'first booking for the shared instructor is accepted');
select throws_ok($$ select tests.raw_book((select mw_f from wk), (select shared from fx)) $$,
  '23P01', null, 'overlapping booking in ANOTHER domain is rejected (exclusion constraint)');
select lives_ok($$ select tests.raw_book((select mw_f from wk), (select other from fx)) $$,
  'a different instructor can take the overlapping class');

-- Non-overlapping class on the Tuesday in between is allowed (per-class slots, not a week-long range).
create temp table tue as
select (select id from public.module where name = 'React') as mod;
insert into public.module_week (module_id, week_start_date, cohort) values ((select mod from tue), '2027-01-31', 'TUE');
insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at)
select w.id, 'Other', 'Tuesday class', public.pt_to_utc('2027-02-02', '10:00'), public.pt_to_utc('2027-02-02', '12:00')
  from public.module_week w where w.cohort = 'TUE';
select lives_ok($$ select tests.raw_book((select id from public.module_week where cohort = 'TUE'), (select shared from fx)) $$,
  'a class on the Tuesday between Sunday and Thursday does not clash');

-- Released bookings do not block.
update public.booking set status = 'Released' where module_week_id = (select mw_b from wk);
select is((select count(*)::int from public.booking_slot s join public.booking b on b.id = s.booking_id
            where b.module_week_id = (select mw_b from wk) and s.active), 0,
  'releasing a booking deactivates its slots');
select lives_ok($$ select tests.raw_book((select mw_f2 from wk), (select shared from fx)) $$,
  'after release the instructor can be booked at that time again');

-- ---------------------------------------------------------------- one active booking per week
select throws_ok($$ select tests.raw_book((select mw_f from wk), (select instructor_id from public.booking where module_week_id = (select mw_b from wk))) $$,
  '23505', null, 'a module week cannot have two active bookings');

-- ---------------------------------------------------------------- one open request per week
insert into public.request (module_week_id, instructor_id, kind, status)
values ((select mw_b from wk), (select shared from fx), 'Outreach', 'Sent');
select throws_ok($$ insert into public.request (module_week_id, instructor_id, kind, status)
                    values ((select mw_b from wk), (select other from fx), 'Outreach', 'Sent') $$,
  '23505', null, 'a second open outreach request for the same module week is rejected');
update public.request set status = 'Declined' where module_week_id = (select mw_b from wk);
select lives_ok($$ insert into public.request (module_week_id, instructor_id, kind, status)
                   values ((select mw_b from wk), (select other from fx), 'Outreach', 'Sent') $$,
  'once the first request is closed, the next instructor can be asked');
select lives_ok($$ insert into public.request (module_week_id, instructor_id, kind, status)
                   values ((select mw_b from wk), (select other from fx), 'TimeChange', 'Sent') $$,
  'a time-change request can be open alongside');

-- ---------------------------------------------------------------- unique message keys
insert into public.message (audience, template_id, channel, unique_key) values ('Instructor', 'M1', 'Discord', 'M1:x:1:Discord');
select throws_ok($$ insert into public.message (audience, template_id, channel, unique_key)
                    values ('Instructor', 'M1', 'Discord', 'M1:x:1:Discord') $$,
  '23505', null, 'duplicate message key is rejected');
select lives_ok($$ insert into public.message (audience, template_id, channel, unique_key)
                   values ('Instructor', 'M1', 'Email', 'M1:x:1:Email') $$, 'different key is accepted');

-- ---------------------------------------------------------------- unique instructors
select throws_ok($$ insert into public.instructor (full_name, primary_email) values ('Dup', 'SHARED.PERSON@example.org') $$,
  '23505', 'An instructor with this email or Discord ID already exists: Shared Person',
  'duplicate primary email (any case) rejected with the existing name');
select throws_ok($$ insert into public.instructor (full_name, primary_email, discord_user_id)
                    values ('Dup2', 'new@example.org', (select discord_user_id from public.instructor where full_name = 'Shared Person')) $$,
  '23505', 'An instructor with this email or Discord ID already exists: Shared Person',
  'duplicate Discord ID rejected with the existing name');
insert into public.instructor_email (instructor_id, email) values ((select other from fx), 'other.alt@example.org');
select throws_ok($$ insert into public.instructor (full_name, primary_email) values ('Dup3', 'other.alt@example.org') $$,
  '23505', 'An instructor with this email or Discord ID already exists: Other Person',
  'a primary email equal to another instructor''s extra email is rejected');
select throws_ok($$ insert into public.instructor_email (instructor_id, email) values ((select other from fx), 'shared.person@example.org') $$,
  '23505', 'An instructor with this email or Discord ID already exists: Shared Person',
  'an extra email equal to another instructor''s primary email is rejected');
select is((select count(*)::int from public.instructor_email where instructor_id = (select shared from fx) and is_primary), 1,
  'primary email is mirrored into instructor_email');

-- Contact change removes Verified badge; Discord link parsing and server check.
update public.instructor set discord_user_id = tests.rand_discord() where id = (select shared from fx);
select is((select verified_at from public.instructor where id = (select shared from fx)), null,
  'changing Discord ID removes the Verified badge');
update public.app_config set discord_guild_id = '111111111111111111';
select throws_ok($$ update public.instructor set discord_channel_link = 'https://discord.com/channels/222222222222222222/333333333333333333' where id = (select other from fx) $$,
  '22023', null, 'a channel link from a different Discord server is rejected');
update public.instructor set discord_channel_link = 'https://discord.com/channels/111111111111111111/444444444444444444' where id = (select other from fx);
select is((select discord_channel_id from public.instructor where id = (select other from fx)), '444444444444444444',
  'channel ID is extracted from the link');

-- ---------------------------------------------------------------- no duplicate module weeks
select throws_ok($$ select tests.make_week((select mod_b from fx), '2027-01-31') $$,
  '23505', null, 'duplicate module week (module + week + cohort) rejected');

-- ---------------------------------------------------------------- daylight saving (PRD §12)
select is(public.pt_to_utc('2027-01-31', '09:00'), '2027-01-31 17:00:00+00'::timestamptz, 'Sun Jan 31 2027 9:00 AM PST = 17:00 UTC');
select is(public.pt_to_utc('2027-03-14', '09:00'), '2027-03-14 16:00:00+00'::timestamptz, 'Sun Mar 14 2027 9:00 AM PDT = 16:00 UTC (first PDT Sunday)');
select is(public.pt_to_utc('2027-11-07', '09:00'), '2027-11-07 17:00:00+00'::timestamptz, 'Sun Nov 7 2027 9:00 AM PST = 17:00 UTC (back to PST)');
select is(private.pt_abbrev('2027-03-14 16:00:00+00'), 'PDT', 'PDT label in summer');
select is(private.pt_abbrev('2027-03-07 17:00:00+00'), 'PST', 'PST label the Sunday before');
create temp table dst as select tests.make_week((select mod_b from fx), '2027-03-14') as mw;
select is((select to_char(private.to_pt(starts_at), 'HH24:MI') from public.class_session c
           where c.module_week_id = (select mw from dst) and c.class_type = 'Live class'),
  '09:00', 'a class generated on the first PDT Sunday still starts at 9:00 PT');
select is((select ends_at - starts_at from public.class_session c join public.module_week w on w.id = c.module_week_id
           where w.module_id = (select mod_b from fx) and w.week_start_date = '2027-03-14' and c.class_type = 'Live class'),
  interval '4 hours', 'duration is 4 hours across the DST week');

-- ---------------------------------------------------------------- history append-only
insert into public.holiday (date, name) values ('2031-12-25', 'Christmas');
select ok(exists(select 1 from public.history_event where entity_table = 'holiday' and action = 'holiday added'
                  and after ->> 'name' = 'Christmas'), 'setup changes are logged with after values');
update public.holiday set name = 'Christmas Day' where date = '2031-12-25';
select ok(exists(select 1 from public.history_event where entity_table = 'holiday' and action = 'holiday changed'
                  and before ->> 'name' = 'Christmas' and after ->> 'name' = 'Christmas Day'),
  'edits are logged with before → after');
select throws_ok($$ update public.history_event set note = 'tampered' $$, '42501', null,
  'history cannot be updated (even by the owner)');
select throws_ok($$ delete from public.history_event $$, '42501', null, 'history cannot be deleted');

-- ---------------------------------------------------------------- optimistic locking
select throws_ok($$ update public.holiday set name = 'X', version = 1 where date = '2031-12-25' $$,
  '40001', null, 'a save based on an old version is rejected ("This changed — reload")');

-- ---------------------------------------------------------------- settings validation
select throws_ok($$ insert into public.setting (scope, domain_id, key, value) values ('Domain', (select dom_b from fx), 'outreach_days', '90') $$,
  '22023', null, 'out-of-range setting rejected');
select throws_ok($$ insert into public.setting (scope, domain_id, key, value) values ('Domain', (select dom_b from fx), 'readiness_days', '32') $$,
  '22023', null, 'readiness must be ≥ outreach + 5');
select lives_ok($$ insert into public.setting (scope, domain_id, key, value) values ('Domain', (select dom_b from fx), 'outreach_days', '21') $$,
  'valid setting accepted');
select is(private.setting_int((select dom_b from fx), 'outreach_days'), 21, 'domain value overrides the default');

-- ---------------------------------------------------------------- RLS / access
select tests.login_anon();
select throws_ok($$ select count(*) from public.instructor $$, '42501', null, 'anonymous API calls cannot read instructors');
select tests.as_postgres();
select tests.login_as('intruder@gmail.com');
select is((select count(*)::int from public.instructor), 0, 'a non-company account sees no data');
select throws_ok($$ insert into public.holiday (date, name) values ('2031-01-01', 'x') $$, '42501', null,
  'a non-company account cannot write');
select tests.as_postgres();
select tests.login_as('ops.person@example.com');
select ok((select count(*)::int from public.instructor) >= 2, 'a company account can read');
select lives_ok($$ insert into public.holiday (date, name) values ('2031-01-01', 'New Year') $$, 'a company account can edit setup data');
select throws_ok($$ update public.history_event set note = 'x' $$, '42501', null, 'a company account cannot edit history');
select throws_ok($$ insert into public.booking (module_week_id, instructor_id, confirmed_via) values ((select mw_b from wk), (select other from fx), 'Manual') $$,
  '42501', null, 'bookings cannot be written directly through the API (only through database functions)');
select tests.as_postgres();

select * from finish();
rollback;
