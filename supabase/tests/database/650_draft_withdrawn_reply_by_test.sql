-- Owner's night batch of 24 November 2026 (decision 333): Draft domains send nothing to instructors, a withdrawn
-- instructor is not asked again for that week, reply by times follow the instructor's time zone when quiet hours
-- are on, the channel refusal says where servers are approved, and the clock's run log is purged.
begin;
\ir ../helpers/helpers.psql
select plan(16);

-- =============================================================== 1 to 3: a Draft domain creates nothing
select tests.scenario('DA', 'Draft', '2027-01-31', 1) as a \gset
select (:'a'::jsonb ->> 'domain') as adom, (:'a'::jsonb ->> 'mw') as amw, (:'a'::jsonb ->> 'i1') as ai1 \gset
select is(private.queue_instructor_message('M15', :'ai1', :'amw', null, now()), 0, '1. a Draft domain queues no instructor message');
select ok(not exists (select 1 from public.message where module_week_id = :'amw'), '2. nothing is created or scheduled');
select ok(exists (select 1 from public.history_event where action = 'Not sent: DA is a draft domain'), '3. and history says so');

-- =============================================================== 4 to 7: back to Draft stops what is waiting
select tests.scenario('DB', 'Live', '2027-01-31', 2) as b \gset
select (:'b'::jsonb ->> 'domain') as bdom, (:'b'::jsonb ->> 'mw') as bmw \gset
select tests.tick(:'bdom', '2027-01-01 18:00+00');
update public.message set status = 'Scheduled', not_before = '2027-01-02 18:00+00' where module_week_id = :'bmw' and template_id = 'M1';
select public.set_domain_status(:'bdom', 'Draft');
select ok(not exists (select 1 from public.message where module_week_id = :'bmw' and audience = 'Instructor' and status in ('Scheduled', 'Pending')),
  '4. back to Draft: the instructor messages still waiting are cancelled');
select ok(exists (select 1 from public.message where module_week_id = :'bmw' and last_error = 'Cancelled before sending: DB went back to Draft.'),
  '5. with the reason');
select is(tests.asking(:'bmw'), null, '6. the open request is withdrawn');
set constraints all immediate;
select is((select status from public.module_week where id = :'bmw'), 'Ready', '7. and the week shows Not asked yet, not Asking');
set constraints all deferred;

-- 8: a message for a Draft domain is stopped at the last moment too, with the reason.
insert into public.message (domain_id, audience, template_id, channel, status, instructor_id, module_week_id, body_text, to_address)
values (:'bdom', 'Instructor', 'M15', 'Email', 'Pending', (:'b'::jsonb ->> 'i1')::uuid, :'bmw', 'x', 'db.instr1@example.org')
returning status as s8, last_error as e8 \gset
select ok(:'s8' = 'Cancelled' and :'e8' like 'Not sent: DB is a draft domain%', '8. a message that would still go for a Draft domain is stopped, never silently');

-- =============================================================== 9 to 11: a withdrawn instructor is not asked again
select tests.scenario('DC', 'Live', '2027-01-31', 2) as c \gset
select (:'c'::jsonb ->> 'domain') as cdom, (:'c'::jsonb ->> 'mw') as cmw, (:'c'::jsonb ->> 'i1') as ci1 \gset
select tests.tick(:'cdom', '2027-01-01 18:00+00');
select private.withdraw_open_request(:'cmw', 'Sooner class', '2027-01-01 18:30+00', false);
set constraints all immediate;
select is(tests.asking(:'cmw'), 'DC Instr2', '9. after a withdrawal the next instructor is asked, not the same one again');
select is(private.week_history_reason(:'ci1', :'cmw'), 'Taken off this class week earlier', '10. the line says why');
set constraints all deferred;
update public.request set close_reason = 'Moved for a break' where module_week_id = :'cmw' and instructor_id = :'ci1';
select is(private.week_history_reason(:'ci1', :'cmw'), null, '11. a week moved for a break may ask them again');

-- =============================================================== 12 to 13: reply by in the instructor's time zone
select tests.scenario('DD', 'Live', '2027-01-31', 1) as d \gset
select (:'d'::jsonb ->> 'domain') as ddom, (:'d'::jsonb ->> 'mw') as dmw, (:'d'::jsonb ->> 'i1') as di1 \gset
insert into public.setting (scope, domain_id, key, value) values ('Domain', :'ddom', 'instructor_quiet_hours_on', 'true');
update public.instructor set time_zone = 'India' where id = :'di1';
-- 6:00 AM India time on Jan 2 (00:30 UTC): asked at 8:00 AM India time; accepted at 9:00 AM India time.
select tests.tick(:'ddom', '2027-01-02 00:30+00');
select tests.at('2027-01-02 03:30+00');
select is(tests.click(:'dmw', :'di1', 'Yes'), 'confirmed', '12. the India instructor accepts');
-- At 11:00 PM India time a class time changes: the time change request waits for 8:00 AM India time.
select tests.at('2027-01-02 17:30+00');
select public.change_class_time((select id from public.class_session where module_week_id = :'dmw' order by starts_at limit 1),
  '2027-01-31', '10:00', '14:00', p_accept_warnings => true, p_reason => 'Test class: the time is chosen on purpose');
select ok(exists (select 1 from public.message where module_week_id = :'dmw' and template_id = 'M5')
          and not exists (select 1 from public.message where module_week_id = :'dmw' and template_id = 'M5' and not_before <> '2027-01-03 02:30+00'),
  '13. the time change waits for 8:00 AM in the instructor''s own time zone (India), not the class''s');

-- =============================================================== 14: where a server is approved now
select ok(position('Setup, Domains, open the domain, Discord server' in pg_get_functiondef('public.set_instructor_channel(uuid,uuid,text)'::regprocedure)) > 0,
  '14. the refusal for an unapproved server says where it is approved now');

-- =============================================================== 15 to 16: the run log keeps 7 days
select lives_ok($$ select private.purge_run_log() $$, '15. the purge runs');
select ok(to_regclass('cron.job') is null or current_database() <> 'postgres'
          or exists (select 1 from cron.job where jobname = 'sme-run-log-purge' and schedule = '15 21 * * *'),
  '16. every night at 21:15 UTC where the clock lives');

select * from finish();
rollback;
