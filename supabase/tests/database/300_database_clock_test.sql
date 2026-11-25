-- Release 3, M1 (decision 281): the database keeps the clock and calls n8n only when there is work.
begin;
\ir ../helpers/helpers.psql
select plan(24);

select tests.scenario('CK', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'i1') as i1 \gset
-- A clean start for the clock: no other work in this test database.
delete from public.message;
delete from public.action_queue;
update public.clock_state set last_poke_at = null, last_reason = null, last_result = null, last_reply_read_at = null,
  budget_alert_month = null where id = 1;

-- 1 to 3: switched off by default, both jobs do nothing.
select is((select clock_enabled from public.app_config where id = 1), false, '1. the clock is off until an admin switches it on');
select is(private.clock_tick() ->> 'skipped', 'clock off', '2. the 2 minute job does nothing while the clock is off');
select is(private.clock_engine() ->> 'skipped', 'clock off', '3. the hourly job does nothing while the clock is off');

-- 4 to 6: switching it on.
select throws_ok($$ select public.configure_clock(true, null) $$, '22023', 'The clock needs the WF4 poke address.',
  '4. switching on needs the WF4 poke address');
select lives_ok($$ select public.configure_clock(true, 'https://example.test/webhook/sme-poke') $$, '5. switched on with the address');
select ok(exists (select 1 from public.history_event where action = 'Database clock switched on'),
  '6. switching the clock on is logged in Activity history');

-- 7 to 8: nothing to do, nothing called.
select is(private.clock_work(), null, '7. no work: no reason to call n8n');
select is(private.clock_tick() ->> 'work', 'false', '8. no work: the job returns without calling n8n');

-- 9 to 11: each kind of work.
insert into public.message (audience, template_id, channel, status, recipient_label, to_address, subject, body_text)
values ('Team', 'T_CLOCK', 'Email', 'Pending', 'Ops', 'ops@example.com', 'Clock test', 'Clock test');
select is(private.clock_work(), 'messages to send', '9. a message waiting to be sent is work');
delete from public.message;
insert into public.action_queue (action, payload) values ('run_check_now', '{}');
select is(private.clock_work(), 'app actions', '10. a queued app action is work');
delete from public.action_queue;
insert into public.action_queue (action, payload) values ('discord_servers', '{}');
select is(private.clock_work(), 'Discord checks', '11. a queued Discord check is work');
delete from public.action_queue;

-- 12 to 14: an open conversation (something sent to an instructor in the last 3 days) and the 10 minute rule.
insert into public.message (audience, template_id, channel, status, instructor_id, sent_at, subject, body_text)
values ('Instructor', 'M1', 'Email', 'Sent', :'i1', now() - interval '1 day', 'Can you teach?', 'Can you teach?');
select is(private.clock_work(), 'reading replies', '12. an open conversation whose replies were never read is work');
update public.clock_state set last_reply_read_at = now() - interval '5 minutes' where id = 1;
select is(private.clock_work(), null, '13. replies read 5 minutes ago: not yet');
update public.clock_state set last_reply_read_at = now() - interval '11 minutes' where id = 1;
select is(private.clock_work(), 'reading replies', '14. replies read 11 minutes ago: read them again (every 10 minutes)');

-- 15 to 18: the brakes.
insert into public.n8n_usage (month, workflow, runs) values (date_trunc('month', now() at time zone 'UTC')::date, 'WF4', 5500);
select is(private.clock_work(), null, '15. above 5,000 runs this month, 11 minutes is not enough');
update public.clock_state set last_reply_read_at = now() - interval '31 minutes' where id = 1;
select is(private.clock_work(), 'reading replies', '16. above 5,000 runs, replies are read every 30 minutes');
update public.n8n_usage set runs = 8500;
update public.clock_state set last_reply_read_at = now() - interval '2 hours' where id = 1;
select is(private.clock_work(), null, '17. above 8,000 runs, no run only to read replies');
insert into public.message (audience, template_id, channel, status, recipient_label, to_address, subject, body_text)
values ('Team', 'T_CLOCK2', 'Email', 'Pending', 'Ops', 'ops@example.com', 'Clock test', 'Clock test');
select is(private.clock_work(), 'messages to send', '18. above 8,000 runs, messages still go out (and replies are read then)');

-- 19 to 21: calling n8n, the one minute limit and the monthly alert.
select is(private.clock_tick() ->> 'reason', 'messages to send', '19. with work the job tries to call n8n');
select ok((select last_result from public.clock_state where id = 1) in ('no Vault', 'no poke key in Vault', 'no pg_net'),
  '20. without the poke key in Vault nothing is sent, and the reason is kept');
select is((select count(*)::int from public.history_event where action = 'n8n budget: replies read less often'), 1,
  '21. one alert in Activity history when the brakes start');
-- Decision 348: the one minute limit is the rule under 6,500 runs (more spacing above that).
update public.n8n_usage set runs = 100;
update public.clock_state set last_poke_at = now() - interval '30 seconds' where id = 1;
-- (22) A call less than a minute ago: wait.

select is(private.clock_tick() ->> 'skipped', 'called less than a minute ago', '22. at most one call to n8n a minute');

-- 23 to 24: counting n8n runs only for calls n8n makes.
delete from public.n8n_usage;
select private.count_n8n_run('WF4');
select is(public.n8n_runs_this_month(), 0, '23. a call made by the app or a test is not counted as an n8n run');
set local request.jwt.claims = '{"role": "service_role"}';
set local request.jwt.claim.role = 'service_role';
select public.next_actions(5);
reset request.jwt.claim.role;
reset request.jwt.claims;
select is(public.n8n_runs_this_month(), 1, '24. a WF4 run (its first call, next_actions) is counted');

select * from finish();
rollback;
