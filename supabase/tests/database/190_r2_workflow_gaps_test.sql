-- Release 2 Milestone F: more scenarios for the workflows with the fewest tests:
-- confirmation and booking, manual assignment, and replacing an instructor.
begin;
\ir ../helpers/helpers.psql
select plan(24);

select tests.scenario('WG', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset

-- ============================================================ Manual assignment
-- Outreach has started: instructor 1 is being asked.
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is(tests.asking(:'mw'), 'WG Instr1', 'manual 1. instructor 1 is being asked');
-- The team assigns instructor 2 by hand instead.
select public.assign_manually(:'mw', :'i2', 'Agreed on a call');
select is((select count(*)::int from public.booking where module_week_id = :'mw' and status = 'Active'), 1,
  'manual 2. exactly one active booking after a manual assignment');
select is((select instructor_id from public.booking where module_week_id = :'mw' and status = 'Active'), :'i2'::uuid,
  'manual 3. the booking is for the instructor chosen by the team');
select is((select confirmed_via from public.booking where module_week_id = :'mw' and status = 'Active'), 'Manual',
  'manual 4. the booking says it was made by hand');
select is((select count(*)::int from public.request where module_week_id = :'mw' and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded')), 0,
  'manual 5. the open request to instructor 1 is closed');
select ok((select count(*) from public.message where module_week_id = :'mw' and instructor_id = :'i1' and template_id = 'M12') >= 1,
  'manual 6. instructor 1 is told politely that the class is taken (M12)');
select ok(exists (select 1 from public.history_event where module_week_id = :'mw' and note like '%Agreed on a call%'),
  'manual 7. the note from the team is in Activity history');
select throws_like($$ select public.assign_manually('$$ || :'mw' || $$'::uuid, '$$ || :'i3' || $$'::uuid) $$,
  '%already has a confirmed instructor%', 'manual 8. a class week that already has an instructor cannot get a second one by hand');

-- A deactivated instructor cannot be assigned.
select tests.scenario('WH', 'Live', '2027-01-31', 2) as k \gset
select (:'k'::jsonb ->> 'mw') as mwh, (:'k'::jsonb ->> 'i2') as h2 \gset
update public.instructor set status = 'Inactive', version = version where id = :'h2';
select throws_like($$ select public.assign_manually('$$ || :'mwh' || $$'::uuid, '$$ || :'h2' || $$'::uuid) $$,
  '%Inactive%', 'manual 9. an instructor who is not in use cannot be assigned');
select is((select count(*)::int from public.booking where module_week_id = :'mwh'), 0, 'manual 10. and no booking is left behind');

-- An offline confirmation is recorded as such.
select (:'k'::jsonb ->> 'i1') as h1 \gset
select public.record_offline_confirmation(:'mwh', :'h1', 'Said yes in person');
select is((select confirmed_via from public.booking where module_week_id = :'mwh' and status = 'Active'), 'Offline',
  'manual 11. a yes given outside the app is recorded as an offline confirmation');

-- ============================================================ Confirmation and booking
select ok((select confirmed_at is not null from public.booking where module_week_id = :'mw' and status = 'Active'),
  'confirm 1. the booking records when it was confirmed');
select is((select count(*)::int from public.booking_slot s join public.booking b on b.id = s.booking_id
            where b.module_week_id = :'mw' and b.status = 'Active'),
          (select count(*)::int from public.class_session where module_week_id = :'mw' and status <> 'Cancelled'),
  'confirm 2. the booking holds one time slot per class');
select ok((select count(*) from public.checklist_item ci join public.class_session c on c.id = ci.class_id where c.module_week_id = :'mw') > 0,
  'confirm 3. the checklist is created for a manual booking too');
select is((select status from public.module_week where id = :'mw'), 'Confirmed', 'confirm 4. the class week is Confirmed');

-- ============================================================ Replacing an instructor
select public.release_booking(:'mw', 'Not well', true);
select is((select status from public.booking where module_week_id = :'mw' and instructor_id = :'i2'), 'Released',
  'replace 1. the booking is released');
select ok((select release_reason from public.booking where module_week_id = :'mw' and instructor_id = :'i2') = 'OpsReleased'
          and exists (select 1 from public.history_event where module_week_id = :'mw' and note like '%Not well%'),
  'replace 2. the booking says the team released it, and the reason is in Activity history');
select is((select count(*)::int from public.booking_slot s join public.booking b on b.id = s.booking_id
            where b.module_week_id = :'mw' and b.status = 'Active'), 0,
  'replace 3. no time slot is held for the released instructor');
select ok(exists (select 1 from public.message where module_week_id = :'mw' and instructor_id = :'i2' and template_id = 'M16'),
  'replace 4. the released instructor gets the thank you and release note');
select tests.tick(:'dom', '2027-01-01 20:00+00');
select isnt(tests.asking(:'mw'), 'WG Instr2', 'replace 5. the released instructor is not asked again for this week');
select ok(tests.asking(:'mw') is not null, 'replace 6. someone else is asked');
select public.assign_manually(:'mw', :'i3');
select is((select count(*)::int from public.booking where module_week_id = :'mw' and status = 'Active'), 1,
  'replace 7. after the replacement there is still exactly one active booking');
select ok(exists (select 1 from public.message where module_week_id = :'mw' and instructor_id = :'i3' and template_id = 'M4'),
  'replace 8. the new instructor gets the confirmation');
select throws_like('select public.release_booking(gen_random_uuid())',
  '%no confirmed instructor%', 'replace 9. releasing a class week without an instructor says there is nobody to release');

select * from finish();
rollback;
