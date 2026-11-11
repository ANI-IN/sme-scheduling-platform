-- Core readiness step 4: a bot in 15 or more Discord servers (decisions 261 to 263).
begin;
\ir ../helpers/helpers.psql
select plan(17);

select tests.company();
select tests.make_domain('MS') as dom \gset
select tests.make_instructor('MS Instr') as ins \gset

create or replace function tests.answer_server(p_server text, p_result jsonb) returns jsonb language sql as $$
  select public.record_discord_result(
    (select id from public.action_queue where action = 'discord_server' and status = 'Processing'
        and payload ->> 'server_id' = p_server order by created_at desc limit 1), p_result);
$$;
create or replace function tests.ready(p_server text, p_channel text) returns jsonb language sql as $$
  select tests.answer_server(p_server, jsonb_build_object(
    'guild', jsonb_build_object('status', 200, 'body', jsonb_build_object('id', p_server, 'name', 'Server ' || right(p_server, 2))),
    'channels', jsonb_build_object('status', 200, 'body', jsonb_build_array(
      jsonb_build_object('id', p_channel, 'type', 0, 'name', 'test-instructor-' || right(p_server, 2), 'position', 1))),
    'members', '{"status": 200}'::jsonb));
$$;

-- =============================================================== the bot is in 16 servers
select public.check_discord('servers');
select public.next_discord_lookups(50);
select public.record_discord_result(
  (select id from public.action_queue where action = 'discord_servers' and status = 'Processing' limit 1),
  jsonb_build_object('guilds', jsonb_build_object('status', 200, 'body',
    (select jsonb_agg(jsonb_build_object('id', (55500000000000000 + n)::text, 'name', 'Program server ' || n))
       from generate_series(1, 16) n))));
select is((select count(*)::int from public.discord_server), 16, 'many 1. all 16 servers the bot is in are listed');
select is((select count(*)::int from public.discord_server where status = 'Checking'), 16,
  'many 2. each server gets its own status, and the ones never checked are checked');
select is((select count(*)::int from public.action_queue where action = 'discord_server' and status = 'Queued'), 16,
  'many 3. one check is queued per server, not more');

-- Spread out: three server checks a run.
select public.next_discord_lookups(50) as first_run \gset
select is(jsonb_array_length(:'first_run'::jsonb), 3, 'many 4. one run takes at most three server checks, to stay under Discord''s limits');
select ok((select bool_and(x ? 'action_id' and x ->> 'action' = 'discord_server' and x ->> 'server_id' like '555%')
             from jsonb_array_elements(:'first_run'::jsonb) x),
  'many 4b. each piece of work is one object with its action and its server, as the workflow reads it');
select is((select count(*)::int from public.action_queue where action = 'discord_server' and status = 'Queued'), 13,
  'many 5. the rest wait for the next runs');

-- Results: one ready, one with a problem.
select tests.ready('55500000000000001', '55510000000000001');
select is((select status from public.discord_server where id = '55500000000000001'), 'Ready',
  'many 6. a server the bot can use is Ready on its own row');
select ok((select checked_at is not null from public.discord_server where id = '55500000000000001'),
  'many 7. the time of the check is kept');
select public.record_discord_result(
  (select id from public.action_queue where action = 'discord_server' and status = 'Processing'
     and payload ->> 'server_id' = '55500000000000002' limit 1),
  '{"guild": {"status": 403}}'::jsonb);
select is((select status from public.discord_server where id = '55500000000000002'), 'Problem',
  'many 8. a server the bot cannot read shows a problem');
select ok((select problem from public.discord_server where id = '55500000000000002') is not null,
  'many 9. with the reason');

-- Cached: listing the servers again does not check a server checked today.
update public.action_queue set status = 'Done' where action like 'discord\_%';
update public.discord_server set status = 'Ready', checked_at = now() where id <> '55500000000000003';
update public.discord_server set status = 'Ready', checked_at = now() - interval '2 days' where id = '55500000000000003';
select public.check_discord('servers');
select public.next_discord_lookups(50);
select public.record_discord_result(
  (select id from public.action_queue where action = 'discord_servers' and status = 'Processing' limit 1),
  jsonb_build_object('guilds', jsonb_build_object('status', 200, 'body',
    (select jsonb_agg(jsonb_build_object('id', (55500000000000000 + n)::text, 'name', 'Program server ' || n))
       from generate_series(1, 16) n))));
select is((select string_agg(payload ->> 'server_id', ',') from public.action_queue
            where action = 'discord_server' and status = 'Queued'), '55500000000000003',
  'many 10. results are kept for a day: only the server checked two days ago is checked again');

-- Check again: one server now, even if it was checked today.
select public.check_discord_server('55500000000000005');
select is((select status from public.discord_server where id = '55500000000000005'), 'Checking',
  'many 11. Check again checks one server now');
select throws_like($$ select public.check_discord_server('99999') $$, '%not in the list%',
  'many 12. a server the bot is not in cannot be checked');

-- An archived server is not checked by itself.
update public.action_queue set status = 'Done' where action like 'discord\_%';
update public.discord_server set checked_at = null where id = '55500000000000006';
select public.set_archived('discord_server', '55500000000000006', true);
select public.check_discord('servers');
select public.next_discord_lookups(50);
select public.record_discord_result(
  (select id from public.action_queue where action = 'discord_servers' and status = 'Processing' limit 1),
  jsonb_build_object('guilds', jsonb_build_object('status', 200, 'body',
    (select jsonb_agg(jsonb_build_object('id', (55500000000000000 + n)::text, 'name', 'Program server ' || n))
       from generate_series(1, 16) n))));
select ok(not exists (select 1 from public.action_queue where action = 'discord_server' and status = 'Queued'
                       and payload ->> 'server_id' = '55500000000000006'),
  'many 13. an archived server is not checked automatically');

-- Instructor channels from any server.
insert into public.discord_channel (id, server_id, name) values ('55520000000000009', '55500000000000009', 'ms-instr');
select public.set_domain_discord_server(:'dom', '55500000000000001');
select lives_ok(format($$ select public.set_instructor_channel(%L, %L, '55520000000000009') $$, :'ins', :'dom'),
  'many 14. an instructor channel can be in any server the bot is in, not only the domain''s');
select is((private.member_servers('instructor', :'ins') ->> 0), '55500000000000009',
  'many 15. their Discord account is looked for in the server of their channel first');
-- Username searches are spread out too: ten a run.
insert into public.action_queue (action, payload)
select 'discord_member', jsonb_build_object('kind', 'instructor', 'id', :'ins') from generate_series(1, 14);
select is((select count(*)::int from jsonb_array_elements(public.next_discord_lookups(50)) x where x ->> 'action' = 'discord_member'), 10,
  'many 16. one run takes at most ten username searches');

select * from finish();
rollback;
