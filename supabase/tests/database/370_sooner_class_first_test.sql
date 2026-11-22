-- Release 3, M7 part 1 (decision 296): Primary first, the sooner class wins. One instructor is never asked for two
-- classes at overlapping times; the sooner class week gets them and a later one asks its next instructor.
begin;
\ir ../helpers/helpers.psql
select plan(14);

select tests.scenario('SC', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3 \gset
insert into public.cohort (domain_id, name, region, start_date) values (:'dom', 'SC Early', 'US', '2027-01-02') returning id as ca \gset
insert into public.cohort (domain_id, name, region, start_date) values (:'dom', 'SC Late', 'US', '2027-01-09') returning id as cb \gset

create or replace function tests.week(p_mod uuid, p_coh uuid, p_date date, p_start time, p_end time, p_region text default null)
returns uuid language sql as $$
  select (public.add_one_class(null, p_mod, p_coh, p_date, p_start, p_end, 'Live class', null, true, null, p_region, 1) ->> 'module_week_id')::uuid;
$$;
create or replace function tests.open_req(p_mw uuid)
returns uuid language sql as $$
  select id from public.request where module_week_id = p_mw and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded');
$$;

-- =============================================================== 1. two cohorts, one Primary, overlapping times
select tests.week(:'mod', :'ca', '2027-02-06', '09:00', '13:00') as wa \gset
select tests.week(:'mod', :'cb', '2027-02-06', '10:00', '12:00') as wb \gset
select tests.tick(:'dom', '2027-01-08 18:00+00');
select is(tests.asking(:'wa'), 'SC Instr1', '1. the sooner class week asks the Primary');
select is(tests.asking(:'wb'), 'SC Instr2', '2. the later class week skips the Primary and asks Backup 1');
select is((select count(*)::int from public.request where instructor_id = :'i1' and kind = 'Outreach' and module_week_id in (:'wa', :'wb')
             and status in ('Queued', 'Sent', 'Reminded')), 1,
  '3. the Primary has one open request, not two at the same time');
select alike((select reason from private.build_line(:'wb') where instructor_id = :'i1'),
  'Being asked for a sooner class: %', '4. the later week says why the Primary is skipped');

-- =============================================================== 2. a sooner week appears after a later one started asking
select tests.week(:'mod', :'ca', '2027-02-13', '09:00', '11:00') as wc \gset
select tests.tick(:'dom', '2027-01-15 18:00+00');
select tests.open_req(:'wc') as wc_req \gset
-- The request has reached the instructor.
update public.message set status = 'Sent' where request_id = :'wc_req' and template_id = 'M1';
select tests.week(:'mod', :'cb', '2027-02-13', '08:00', '10:00') as wd \gset
select tests.tick(:'dom', '2027-01-15 19:00+00');
select is(tests.asking(:'wd'), 'SC Instr1', '5. the new sooner class week takes the Primary');
select is(tests.asking(:'wc'), 'SC Instr2', '6. the later class week asks its next instructor at once');
select is((select close_reason from public.request where id = :'wc_req'), 'Sooner class',
  '7. the later request is withdrawn because of the sooner class');
select ok(tests.msgs(:'wc', 'M12') >= 1, '8. the Primary is told the later class no longer needs them (it had reached them)');
select ok(exists (select 1 from public.history_event where module_week_id = :'wc' and action = 'Sooner class first: SC Instr1'),
  '9. Activity history says the later class week gave way to a sooner class');

-- =============================================================== 3. not told about a request that never reached them
select tests.week(:'mod', :'ca', '2027-02-20', '09:00', '11:00') as we \gset
select tests.tick(:'dom', '2027-01-22 18:00+00');
select tests.week(:'mod', :'cb', '2027-02-20', '08:00', '10:00') as wf \gset
select tests.tick(:'dom', '2027-01-22 19:00+00');
select is(tests.asking(:'wf') || ' / ' || tests.msgs(:'we', 'M12'), 'SC Instr1 / 0',
  '10. a request that had not gone out yet is withdrawn without a "no longer needed" message');

-- =============================================================== 4. a confirmed booking is never taken away
select tests.week(:'mod', :'ca', '2027-02-27', '10:00', '12:00') as wg \gset
select public.assign_manually(:'wg', :'i1');
select tests.week(:'mod', :'cb', '2027-02-27', '09:00', '11:00') as wh \gset
select tests.tick(:'dom', '2027-01-29 18:00+00');
select is(tests.booked(:'wg') || ' / ' || tests.asking(:'wh'), 'SC Instr1 / SC Instr2',
  '11. a sooner class week does not take an instructor who is already confirmed for a later one');

-- =============================================================== 5. a clash after "Yes" no longer keeps them out for good
select tests.week(:'mod', :'ca', '2027-03-20', '09:00', '11:00') as wx \gset
insert into public.request (module_week_id, instructor_id, kind, status, close_reason, time_version)
values (:'wx', :'i3', 'Outreach', 'Declined', 'Clash', 1);
select is(private.week_history_reason(:'i3', :'wx'), null,
  '12. once the clash is gone, the instructor can be asked for that class week again');
select is(private.week_history_reason(:'i2', :'wb'), 'Did not reply earlier',
  '13. other history reasons stay as they were (Backup 1 did not answer in time for 6 February)');

-- =============================================================== 6. across domains
select tests.scenario('SD', 'Live', '2027-01-31', 1) as k \gset
select (:'k'::jsonb ->> 'domain') as dom2, (:'k'::jsonb ->> 'module') as mod2 \gset
delete from public.module_ranking where module_id = :'mod2';
insert into public.module_ranking (module_id, instructor_id, rank) values (:'mod2', :'i1', 1);
insert into public.instructor_channel (instructor_id, domain_id, channel_id)
select :'i1', :'dom2', discord_channel_id from public.instructor where id = :'i1';
select tests.approve_test_channels();
insert into public.cohort (domain_id, name, region, start_date) values (:'dom2', 'SD One', 'US', '2027-01-02') returning id as cd \gset
select tests.week(:'mod', :'ca', '2027-03-06', '09:00', '11:00') as wy \gset
select tests.tick(:'dom', '2027-02-05 18:00+00');
select tests.week(:'mod2', :'cd', '2027-03-06', '08:00', '10:00') as wz \gset
select tests.tick(:'dom2', '2027-02-05 19:00+00');
select is(tests.asking(:'wz') || ' / ' || tests.asking(:'wy'), 'SC Instr1 / SC Instr2',
  '14. a sooner class in another domain gets the instructor, and the later one asks its next instructor');

select * from finish();
rollback;
