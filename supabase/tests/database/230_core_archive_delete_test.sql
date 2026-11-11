-- Core readiness step 3: archive, restore and permanent delete (decisions 254 to 260).
begin;
\ir ../helpers/helpers.psql
select plan(55);

-- Two domains: DX is deleted piece by piece, DY stays to show nothing else is touched.
select tests.scenario('DX', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'mw') as mw,
       (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'i3') as i3,
       (:'j'::jsonb ->> 'owner') as owner \gset
select tests.scenario('DY', 'Live', '2027-01-31', 2) as k \gset
select (:'k'::jsonb ->> 'domain') as ydom, (:'k'::jsonb ->> 'mw') as ymw \gset
create temp table hist_before on commit drop as select id from public.history_event;

-- =============================================================== class weeks
-- A second week of the same module: instructor 1 confirmed for the first, the second is being asked.
select tests.make_week(:'mod', '2027-02-07') as mw2 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is(tests.click(:'mw', :'i1', 'Yes'), 'confirmed', 'setup: instructor 1 confirms the first week');
select tests.tick(:'dom', '2027-01-08 18:00+00');
select ok(tests.asking(:'mw2') is not null, 'setup: someone is being asked for the second week');

select public.delete_preview('class_week', :'mw') as p \gset
select is((:'p'::jsonb ->> 'needs_name')::boolean, true, 'week 1. a class week with a confirmed instructor asks for its name');
select ok((:'p'::jsonb -> 'lines')::text like '%1 confirmed instructor is told their class is cancelled%',
  'week 2. the preview says the confirmed instructor is told, as for a cancellation');
select tests.make_week(:'mod', '2027-03-07') as mw3 \gset
select is((public.delete_preview('class_week', :'mw3') ->> 'needs_name')::boolean, false,
  'week 3. a class week nobody is confirmed for or asked about needs no typed name');
select throws_like(format($$ select public.delete_item('class_week', %L, 'wrong') $$, :'mw'),
  'Type the name exactly as shown%', 'week 4. a wrong name is refused');
select public.delete_item('class_week', :'mw', 'concurrency dx');
select ok(not exists (select 1 from public.module_week where id = :'mw'), 'week 5. the name in any case deletes it');
select ok(not exists (select 1 from public.booking where module_week_id = :'mw')
          and not exists (select 1 from public.class_session where module_week_id = :'mw'),
  'week 6. its booking and classes are gone, so nothing points at a missing class week');
select ok((select count(*) from public.message where template_id = 'M11' and instructor_id = :'i1'
            and status in ('Scheduled', 'Pending')) >= 1,
  'week 7. the instructor''s cancellation notice is still queued to go out');
select ok(exists (select 1 from public.history_event where action like 'Class week deleted: Concurrency DX%'
            and before ->> 'module' = 'Concurrency DX' and before ? 'week_start_date'),
  'week 8. Activity history keeps one entry with the module name and the old values');
-- Cancel and restore.
select public.cancel_module_week(:'mw3', 'Test');
select public.restore_module_week(:'mw3');
select is(tests.mw_status(:'mw3'), 'Planned', 'week 9. a cancelled class week can be restored');
select is((select count(*)::int from public.class_session where module_week_id = :'mw3' and status = 'Planned'), 2,
  'week 10. its classes are planned again');
select throws_like(format($$ select public.restore_module_week(%L) $$, :'mw3'),
  'Only a cancelled class week can be restored%', 'week 11. only a cancelled class week can be restored');

-- =============================================================== instructors
select public.delete_preview('instructor', :'i2') as pi \gset
select ok((:'pi'::jsonb -> 'lines')::text like '%Removed from 1 instructor orders%', 'instr 1. the preview lists their places in instructor orders');
select is((:'pi'::jsonb ->> 'needs_name')::boolean, true, 'instr 2. deleting someone with linked data asks for their name');
select tests.asking(:'mw2') as asked \gset
select public.delete_item('instructor', :'i2', 'DX Instr2');
select ok(not exists (select 1 from public.instructor where id = :'i2'), 'instr 3. the instructor is gone');
select is((select string_agg(rank::text, ',' order by rank) from public.module_ranking where module_id = :'mod'), '1,2',
  'instr 4. the instructor order closes up without a gap');
select ok(not exists (select 1 from public.instructor_channel where instructor_id = :'i2')
          and not exists (select 1 from public.instructor_email where instructor_id = :'i2'),
  'instr 5. their channels and email addresses go with them');
select ok(exists (select 1 from public.history_event where action = 'Instructor deleted: DX Instr2'
                   and before ->> 'full_name' = 'DX Instr2'),
  'instr 6. Activity history keeps their name and details');
-- Instructor 1 is confirmed for nothing now; give them a confirmed week and delete them.
select tests.make_week(:'mod', '2027-03-14') as mw4 \gset
select public.assign_manually(:'mw4', :'i1', 'Phone');
select ok((public.delete_preview('instructor', :'i1') -> 'lines')::text like '%1 confirmed class weeks still to come are released%',
  'instr 7. the preview says their confirmed classes are released');
select public.delete_item('instructor', :'i1', 'DX Instr1');
select is(tests.booked(:'mw4'), null, 'instr 8. their confirmed class week has nobody booked any more');
select ok(exists (select 1 from public.message where template_id like 'M%' and instructor_id is null
                   and to_address = 'dx.instr1@example.org'),
  'instr 9. the message telling them stays, with its address, after they are deleted');

-- =============================================================== modules
select tests.make_module(:'dom', 'Second DX', 2) as mod2 \gset
select tests.rank(:'mod2', :'i3');
select tests.make_week(:'mod2', '2027-02-14') as m2w \gset
select tests.make_week(:'mod2', '2027-02-21') as m2hand \gset
update public.module_week set paused = true where id = :'m2hand';
select public.set_archived('module', :'mod2', true) as ar \gset
select is((select status from public.module where id = :'mod2'), 'Archived', 'module 1. archive sets the module to archived');
select ok((select paused and archive_paused from public.module_week where id = :'m2w'),
  'module 2. its class weeks stop: they are paused');
select public.set_archived('module', :'mod2', false);
select is((select status from public.module where id = :'mod2'), 'Active', 'module 3. restore makes it active again');
select ok(not (select paused from public.module_week where id = :'m2w'), 'module 4. its class weeks start again');
select is((select count(*)::int from public.module_week where module_id = :'mod2' and paused), 1,
  'module 5. a week that was paused by hand before stays paused');
select public.delete_preview('module', :'mod2') as pm \gset
select is((:'pm'::jsonb ->> 'needs_name')::boolean, true, 'module 6. a module with classes asks for its name');
select public.delete_item('module', :'mod2', 'Second DX');
select ok(not exists (select 1 from public.module where id = :'mod2')
          and not exists (select 1 from public.module_week where module_id = :'mod2')
          and not exists (select 1 from public.class_pattern_item where module_id = :'mod2'),
  'module 7. the module, its class weeks and its class times are gone');
select ok(exists (select 1 from public.module where id = :'mod'), 'module 8. the other module of the domain is untouched');
select ok(not exists (select 1 from public.history_event where action = 'module removed' and entity_id = :'mod2'),
  'module 9. one history entry for the delete, not one per row');

-- =============================================================== cohorts
insert into public.cohort (domain_id, name, region) values (:'dom', 'DX India cohort', 'India') returning id as coh \gset
update public.cohort set name = 'DX India evenings' where id = :'coh';
select is((select name from public.cohort where id = :'coh'), 'DX India evenings', 'cohort 1. a cohort can be added and renamed');
insert into public.class_pattern_item (module_id, cohort_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
values (:'mod', :'coh', 'Live class', '{module}: Live class', 1, '19:30', 120, 1);
select public.set_archived('cohort', :'coh', true);
select ok((select archived_at is not null from public.cohort where id = :'coh'), 'cohort 2. archive hides the cohort');
select public.set_archived('cohort', :'coh', false);
select ok((select archived_at is null from public.cohort where id = :'coh'), 'cohort 3. restore brings it back');
select is((public.delete_preview('cohort', :'coh') ->> 'needs_name')::boolean, true,
  'cohort 4. a cohort with its own class times asks for its name');
select public.delete_item('cohort', :'coh', 'DX India evenings');
select ok(not exists (select 1 from public.cohort where id = :'coh')
          and not exists (select 1 from public.class_pattern_item where cohort_id = :'coh'),
  'cohort 5. the cohort and its class times are gone');

-- =============================================================== team members
select tests.make_team_member('DX Removed') as gone \gset
update public.team_member set access_removed_at = now() where id = :'gone';
select throws_like(format($$ select public.delete_item('team_member', %L, 'DX Removed') $$, :'gone'),
  'Their access was removed%', 'team 1. someone whose access was removed cannot be deleted (they stay blocked)');
select ok((public.delete_preview('team_member', :'owner') -> 'lines')::text like '%roles on domains and modules are removed%',
  'team 2. the preview lists their roles');
select public.delete_item('team_member', :'owner', (select name from public.team_member where id = :'owner'));
select ok(not exists (select 1 from public.team_member where id = :'owner')
          and not exists (select 1 from public.module_owner where team_member_id = :'owner'),
  'team 3. the person and their module roles are gone');

-- =============================================================== Discord servers
insert into public.discord_server (id, name) values ('777000000000000001', 'DX server');
insert into public.discord_channel (id, server_id, name) values ('777000000000000011', '777000000000000001', 'dx-instr3');
update public.domain set discord_server_id = '777000000000000001' where id = :'dom';
update public.instructor_channel set channel_id = '777000000000000011' where instructor_id = :'i3';
select public.set_archived('discord_server', '777000000000000001', true);
select ok((select archived_at is not null from public.discord_server where id = '777000000000000001'),
  'discord 1. a server can be archived (hidden)');
select public.set_archived('discord_server', '777000000000000001', false);
select public.delete_item('discord_server', '777000000000000001', 'DX server');
select ok(not exists (select 1 from public.discord_server where id = '777000000000000001')
          and not exists (select 1 from public.instructor_channel where channel_id = '777000000000000011'),
  'discord 2. deleting a server removes it and the instructor channels in it');
select is((select discord_server_id from public.domain where id = :'dom'), null,
  'discord 3. the domain no longer has a server chosen');

-- =============================================================== domains
select tests.make_week(:'mod', '2027-04-04') as mw5 \gset
select public.assign_manually(:'mw5', :'i3', 'Phone');
select public.set_archived('domain', :'dom', true);
select ok(not exists (select 1 from jsonb_array_elements(public.engine_tick_all('2027-01-20 18:00+00') -> 'domains') x
                       where x ->> 'domain' = 'DX'), 'domain 1. the hourly check skips an archived domain');
select public.set_archived('domain', :'dom', false);
select ok(exists (select 1 from jsonb_array_elements(public.engine_tick_all('2027-01-20 18:00+00') -> 'domains') x
                   where x ->> 'domain' = 'DX'), 'domain 2. and runs again after it is restored');
select public.delete_preview('domain', :'dom') as pd \gset
select ok((:'pd'::jsonb -> 'lines')::text like '%modules, with their class times%'
          and (:'pd'::jsonb -> 'lines')::text like '%confirmed instructor%',
  'domain 3. the preview lists the modules and the confirmed instructors who are told');
select throws_like(format($$ select public.delete_item('domain', %L) $$, :'dom'),
  'Type the name exactly as shown%', 'domain 4. a domain with modules is not deleted without its name');
select public.delete_item('domain', :'dom', 'DX');
select ok(not exists (select 1 from public.domain where id = :'dom')
          and not exists (select 1 from public.module where domain_id = :'dom')
          and not exists (select 1 from public.cohort where domain_id = :'dom')
          and not exists (select 1 from public.module_week where domain_id = :'dom'),
  'domain 5. the domain, its modules, cohorts and class weeks are gone');
select ok((select count(*) from public.message where template_id = 'M11' and instructor_id = :'i3'
            and status in ('Scheduled', 'Pending')) >= 1, 'domain 6. the confirmed instructor is told, as for a cancellation');
select ok(exists (select 1 from public.domain where id = :'ydom') and exists (select 1 from public.module_week where id = :'ymw'),
  'domain 7. the other domain is untouched');
select ok(exists (select 1 from public.history_event where action = 'Domain deleted: DX' and before -> 'modules' ? 'Concurrency DX'),
  'domain 8. Activity history keeps the domain and the names of its modules');
select ok(not exists (select id from hist_before except select id from public.history_event),
  'domain 9. every older history entry is still there');

-- =============================================================== undo
select ok(not private.can_undo((select h from public.history_event h where action = 'Domain deleted: DX')),
  'undo 1. a permanent delete cannot be undone');
insert into public.holiday (domain_id, date, name) values (:'ydom', '2027-05-01', 'DY day') returning id as hol \gset
update public.holiday set name = 'DY holiday' where id = :'hol';
delete from public.holiday where id = :'hol';
select ok(private.can_undo((select h from public.history_event h where entity_id = :'hol' and action = 'holiday changed')),
  'undo 2. an edit can still be undone');
select ok(not private.can_undo((select h from public.history_event h where entity_id = :'hol' and action = 'holiday removed')),
  'undo 3. removing a row cannot be undone');
select throws_like($$ update public.history_event set note = 'x' where id = (select max(id) from public.history_event) $$,
  '%', 'undo 4. history still cannot be edited');

select * from finish();
rollback;
