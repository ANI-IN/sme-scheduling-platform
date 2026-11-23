-- Owner's live testing of 23 November 2026, the High findings (decision 331).
begin;
\ir ../helpers/helpers.psql
select plan(24);

select tests.scenario('HF', 'Draft', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod, (:'j'::jsonb ->> 'i1') as i1, (:'j'::jsonb ->> 'i2') as i2 \gset
insert into public.discord_server (id, name, status, access, refreshed_at) values
  ('999000000000063001', 'HF Server', 'Ready', 'Approved', now() - interval '1 hour'),
  ('999000000000063002', 'HF Other', 'Ready', 'Approved', now());
insert into public.discord_channel (id, server_id, name, bot_can_post) values
  ('999000000000063101', '999000000000063001', 'hf-alerts', true), ('999000000000063102', '999000000000063001', 'hf-testing', true);
update public.domain set alert_discord_channel_id = null, test_discord_channel_id = null, test_email = null, discord_server_id = null,
       discord_status = 'NotSet' where id = :'dom';

-- 1 to 8: domain status rules, said exactly; nothing changes until all is there.
select is(jsonb_array_length(public.domain_status_problems(:'dom', 'Draft')), 0, '1. Draft is always allowed');
select is(jsonb_array_length(public.domain_status_problems(:'dom', 'Paused')), 0, '2. Paused is always allowed');
select is((select string_agg(x ->> 'text', ' | ') from jsonb_array_elements(public.domain_status_problems(:'dom', 'Test')) x),
  'Choose a testing channel for this domain (below, under Testing). | Enter a testing email for this domain (below, under Testing).',
  '3. Testing needs a testing channel and a testing email');
select throws_ok(format($$ select public.set_domain_status(%L, 'Test') $$, :'dom'), '22023',
  'Choose a testing channel for this domain (below, under Testing). Enter a testing email for this domain (below, under Testing).',
  '4. and setting it says what is missing');
select is((select status from public.domain where id = :'dom'), 'Draft', '5. the status did not change');
update public.domain set test_discord_channel_id = '999000000000063102', test_email = 'hf.testing@example.com' where id = :'dom';
select lives_ok(format($$ select public.set_domain_status(%L, 'Test') $$, :'dom'), '6. with both, Testing is set');
update public.module set status = 'Inactive' where id = :'mod';
select is(jsonb_array_length(public.domain_status_problems(:'dom', 'Live')), 3,
  '7. Live needs an approved server that is ready, an alert channel and a live module with times and an instructor');
insert into public.discord_server_domain (server_id, domain_id) values ('999000000000063001', :'dom');
update public.domain set discord_server_id = '999000000000063001', discord_status = 'Ready', alert_discord_channel_id = '999000000000063101'
 where id = :'dom';
update public.module set status = 'Active' where id = :'mod';
select is(public.domain_status_problems(:'dom', 'Live'), '[]'::jsonb, '8. with all of it, Live has nothing missing');

-- 9 to 10: a server that is not approved for the domain is said at once, never left "Checking".
update public.domain set discord_server_id = '999000000000063002' where id = :'dom';
select public.check_discord('server', :'dom');
select is((select discord_status from public.domain where id = :'dom'), 'Problem', '9. checking a server not approved for the domain');
select alike((select discord_problem from public.domain where id = :'dom'), 'HF Other is not approved for this domain.%', '10. says so');
update public.domain set discord_server_id = '999000000000063001', discord_status = 'Ready' where id = :'dom';

-- 11 to 15: checks that never finished end with a clear result.
update public.instructor set discord_username = 'hf.one' where id = :'i1';
delete from public.action_queue where action like 'discord\_%';
update public.instructor set discord_status = 'Checking' where id = :'i1';
insert into public.action_queue (action, payload, status, created_at) values
  ('discord_server', jsonb_build_object('server_id', '999000000000063001'), 'Processing', now() - interval '10 minutes');
update public.discord_server set status = 'Checking' where id = '999000000000063001';
select private.expire_stuck_checks(now());
select is((select discord_status from public.instructor where id = :'i1'), 'Problem', '11. an instructor "Checking" with no check left');
select alike((select discord_problem from public.instructor where id = :'i1'), 'The Discord check did not finish%Press Check again%', '12. is told to check again');
select is((select status from public.action_queue where action = 'discord_server' and payload ->> 'server_id' = '999000000000063001' order by created_at limit 1),
  'Failed', '13. work that never came back fails');
select is((select status from public.discord_server where id = '999000000000063001'), 'Problem', '14. and the server is no longer "Checking"');
select lives_ok($$ select private.clock_tick(now()) $$, '15. the clock runs the sweep every time');
update public.discord_server set status = 'Ready' where id = '999000000000063001';

-- 16 to 21: a Discord account held by someone else.
update public.instructor set is_test = false where id in (:'i1', :'i2');
update public.instructor set discord_user_id = '740000000000000001', status = 'Archived' where id = :'i2';
update public.instructor set discord_username = 'hf.one', discord_status = 'Checking', discord_user_id = null where id = :'i1';
select public.check_discord('instructor', :'i1');
select public.record_discord_result((select id from public.action_queue where action = 'discord_member' and status = 'Queued' order by created_at desc limit 1),
  jsonb_build_object('searches', jsonb_build_array(jsonb_build_object('server_id', '999000000000063001', 'status', 200,
    'body', jsonb_build_array(jsonb_build_object('user', jsonb_build_object('id', '740000000000000001', 'username', 'hf.one')))))));
select is((select discord_user_id from public.instructor where id = :'i1'), '740000000000000001',
  '16. an archived instructor does not block a real person: the account is released to them');
select ok(exists (select 1 from public.history_event where action like 'Discord account released from %'), '17. and it is logged');
-- A real instructor in use holds it: say so, offer Release.
select tests.as_postgres();
update public.instructor set status = 'Active', discord_user_id = '740000000000000002' where id = :'i2';
update public.instructor set discord_status = 'Checking', discord_user_id = null where id = :'i1';
select public.check_discord('instructor', :'i1');
select public.record_discord_result((select id from public.action_queue where action = 'discord_member' and status = 'Queued' order by created_at desc limit 1),
  jsonb_build_object('searches', jsonb_build_array(jsonb_build_object('server_id', '999000000000063001', 'status', 200,
    'body', jsonb_build_array(jsonb_build_object('user', jsonb_build_object('id', '740000000000000002', 'username', 'hf.one')))))));
select alike((select discord_problem from public.instructor where id = :'i1'), '%press Release from %', '18. a real holder: the problem says Release from');
select is((select discord_held_by from public.instructor where id = :'i1'), :'i2'::uuid, '19. and who holds it');
select lives_ok(format($$ select public.release_discord_account(%L) $$, :'i1'), '20. Release from works');
select ok((select discord_user_id is null from public.instructor where id = :'i2')
          and (select discord_status = 'Checking' from public.instructor where id = :'i1'),
  '21. the holder lets go and the account is checked again');

-- 22 to 24: new channels come in by themselves (a fresh list at most every 2 minutes a server).
select is((public.request_channel_refresh(:'dom') ->> 'queued')::int, 1, '22. opening the domain asks for a fresh channel list');
select ok(exists (select 1 from public.action_queue where action = 'discord_server' and status = 'Queued'
                   and payload ->> 'server_id' = '999000000000063001'), '23. as a server check');
update public.discord_server set status = 'Ready', refreshed_at = now() where id = '999000000000063001';
select is((public.request_channel_refresh(:'dom') ->> 'queued')::int, 0, '24. not again within 2 minutes');

select * from finish();
rollback;
