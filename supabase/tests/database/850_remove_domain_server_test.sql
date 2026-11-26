-- Decision 350, owner 26 November 2026: an admin takes the Discord server off a domain (never off a Live one), a
-- domain whose server was removed sends nothing on Discord until one is chosen again, archived domains are cleared
-- in one go, and archived domains never count as using a server.
begin;
\ir ../helpers/helpers.psql
select plan(37);

select tests.company();
select tests.scenario('RS', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as live \gset
select tests.make_domain('RS Draft', 'Draft') as draft \gset
select tests.make_domain('RS Paused', 'Paused') as paused \gset
select tests.make_domain('RS Kept', 'Test') as kept \gset
select tests.make_domain('RS Never', 'Draft') as never \gset
select tests.make_domain('RS Old', 'Draft') as old \gset
select tests.make_domain('RS Old approved', 'Draft') as oldonly \gset
select tests.make_domain('RS Old live', 'Live') as oldlive \gset
update public.domain set archived_at = now() where id in (:'old', :'oldonly', :'oldlive');
update public.domain set discord_server_id = '999000000000000001', discord_status = 'Ready'
 where id in (:'live', :'draft', :'paused', :'kept', :'old', :'oldlive');
select tests.login_google('nina@example.com'); select tests.as_postgres();
select tests.login_google('omar@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id, discord_prompt_dismissed_at, is_admin)
select initcap(split_part(u.email, '@', 1)), u.email, u.id, now(), u.email = 'omar@example.com'
  from auth.users u where u.email in ('nina@example.com', 'omar@example.com')
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id, is_admin = excluded.is_admin;
delete from public.message;

-- A message of the domain, to its alert channel, to one person or by email; returns what became of it.
create or replace function pg_temp.send(p_domain uuid, p_key text, p_kind text default 'channel')
returns text language plpgsql as $$
declare v text;
begin
  insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, discord_channel_id,
                              discord_dm_user_id, to_address, domain_id, subject, body_text)
  select 'Admin', 'T_RS', case when p_kind = 'email' then 'Email' else 'Discord' end, 'Pending', p_key, 'RS',
         case when p_kind = 'channel' then d.alert_discord_channel_id end,
         case when p_kind = 'direct' then (select discord_user_id from public.team_member where name = 'RS Ops') end,
         case when p_kind = 'email' then 'someone@example.org' end, d.id, 'RS', 'RS'
    from public.domain d where d.id = p_domain;
  select status into v from public.message where unique_key = p_key;
  return v;
end $$;

-- =============================================================== removing one domain's server
select tests.login_google('nina@example.com');
select throws_ok(format('select public.remove_domain_server(%L)', :'draft'), '42501', 'Only an admin can change this.',
  '1. a normal user cannot remove a server');
select tests.as_postgres();
select count(*)::int as setup_lines from public.history_event where domain_id = :'paused' and category = 'Setup changes' \gset
select tests.login_google('omar@example.com');
select throws_ok(format('select public.remove_domain_server(%L)', :'live'), '22023', 'Set the domain to Draft or Paused first.',
  '2. a Live domain keeps its server');
select tests.as_postgres();
select is((select discord_server_id from public.domain where id = :'live'), '999000000000000001', '3. unchanged');
select pg_temp.send(:'paused', 'rs-0') as waiting \gset
select tests.login_google('omar@example.com');
select lives_ok(format('select public.remove_domain_server(%L)', :'paused'), '4. an admin removes it from a paused domain');
select throws_ok(format('select public.remove_domain_server(%L)', :'paused'), '22023', 'This domain has no Discord server.',
  '5. there is nothing to remove twice');
select tests.as_postgres();
select is((select coalesce(discord_server_id, 'none') || ' ' || discord_status from public.domain where id = :'paused'),
  'none NotSet', '6. the domain has no server');
select ok(exists (select 1 from public.discord_server_domain where domain_id = :'paused'),
  '7. the approval stays, so a server can be chosen again');
select is((select count(*)::int from public.history_event where domain_id = :'paused' and category = 'Discord'
            and action = 'Discord server removed from domain' and actor_label = 'Omar'
            and before ->> 'server' = 'Test server'), 1, '8. logged once, with who and which server');
select is((select count(*)::int from public.history_event where domain_id = :'paused' and category = 'Setup changes'),
  :setup_lines, '9. and not a second time as a setup change');

-- =============================================================== nothing on Discord until one is chosen again
select tests.taken(id) from public.message where unique_key = 'rs-0';
select is(:'waiting' || ' ' || (select status from public.message where unique_key = 'rs-0'), 'Pending Cancelled',
  '9b. a post already waiting is stopped when the automation takes it');
select is(pg_temp.send(:'paused', 'rs-1'), 'Cancelled', '10. no channel post');
select alike((select last_error from public.message where unique_key = 'rs-1'),
  'No Discord server is chosen for RS Paused.%', '11. with the reason');
select is(pg_temp.send(:'paused', 'rs-2', 'direct'), 'Cancelled', '12. no direct message');
select is(pg_temp.send(:'paused', 'rs-3', 'email'), 'Pending', '13. email still goes');
select is(pg_temp.send(:'never', 'rs-4'), 'Pending', '14. a domain that never had a server removed works as before');
select tests.login_google('nina@example.com');
select lives_ok(format('select public.set_domain_discord_server(%L, %L)', :'paused', '999000000000000001'),
  '15. anyone on the team can choose a server again');
select tests.as_postgres();
select is(pg_temp.send(:'paused', 'rs-5'), 'Pending', '16. and Discord messages go again');

-- =============================================================== clearing the choice follows the same rules
select tests.login_google('nina@example.com');
select throws_ok(format('select public.set_domain_discord_server(%L, null)', :'draft'), '42501', 'Only an admin can change this.',
  '17. a normal user cannot clear it either');
select tests.as_postgres();
select tests.login_google('omar@example.com');
select throws_ok(format('select public.set_domain_discord_server(%L, null)', :'live'), '22023',
  'Set the domain to Draft or Paused first.', '18. nor can it be cleared on a Live domain');
select lives_ok(format('select public.set_domain_discord_server(%L, null)', :'draft'), '19. an admin clears it on a draft');
select tests.as_postgres();
select ok((select discord_server_id from public.domain where id = :'draft') is null
          and exists (select 1 from public.history_event where domain_id = :'draft'
                       and action = 'Discord server removed from domain'), '20. removed and logged');

-- =============================================================== every archived domain at once
select tests.login_google('nina@example.com');
select throws_ok(format('select public.remove_archived_domain_servers(array[%L]::uuid[])', :'old'), '42501',
  'Only an admin can change this.', '21. a normal user cannot');
select tests.as_postgres();
select tests.login_google('omar@example.com');
select throws_ok(format('select public.remove_archived_domain_servers(array[%L, %L]::uuid[])', :'old', :'kept'), '22023', null,
  '22. a domain in use is never part of it');
select tests.as_postgres();
select is((select discord_server_id from public.domain where id = :'old'), '999000000000000001', '23. and then nothing changes');
select tests.login_google('omar@example.com');
select public.remove_archived_domain_servers(array[:'old', :'oldonly', :'oldlive']::uuid[]) as bulk \gset
select tests.as_postgres();
select is(:'bulk'::jsonb -> 'removed', '["RS Old", "RS Old approved"]'::jsonb, '24. the answer names the domains cleared');
select ok((select discord_server_id from public.domain where id = :'old') is null
          and not exists (select 1 from public.discord_server_domain where domain_id in (:'old', :'oldonly')),
  '25. no server and no approval left on them');
select ok((select discord_server_id from public.domain where id = :'oldlive') = '999000000000000001'
          and exists (select 1 from public.discord_server_domain where domain_id = :'oldlive'),
  '26. an archived domain still set to Live is left alone');
select ok((select discord_server_id from public.domain where id = :'kept') = '999000000000000001'
          and exists (select 1 from public.discord_server_domain where domain_id = :'kept'), '27. domains in use are untouched');
select is((select count(*)::int from public.history_event where action = 'Discord server removed from domain'
            and domain_id in (:'old', :'oldonly')), 2, '28. one line in Activity history each');
select is((select count(*)::int from public.message where status = 'Pending' and audience = 'Instructor'), 0,
  '29. nothing was sent to anyone');

-- =============================================================== archived domains never count as using a server
-- In use with this server now: the Live, the Paused (chosen again) and the Testing domain.
select tests.login_google('omar@example.com');
select alike(public.delete_preview('discord_server', '999000000000000001')::text, '%3 domains no longer have a Discord server%',
  '30. deleting the server counts only the domains in use');
select tests.as_postgres();
-- A second server used only by an archived domain is not searched first for its instructors.
insert into public.discord_server (id, name, status, access) values ('999000000000000002', 'Old server', 'Ready', 'Approved');
select tests.make_domain('RS Gone', 'Draft') as gone \gset
select tests.make_module(:'gone', 'RS Gone module') as gone_module \gset
select tests.make_instructor('RS Roamer') as roamer \gset
select tests.rank(:'gone_module', :'roamer');
update public.domain set discord_server_id = '999000000000000002', archived_at = now() where id = :'gone';
select is(private.member_servers('instructor', :'roamer') ->> 0, '999000000000000001',
  '31. an archived domain does not put its server first');
-- The server is checked: a missing instructor channel is a task for a domain in use, not for an archived one.
update public.domain set discord_server_id = '999000000000000001' where id = :'gone';
insert into public.instructor_channel (instructor_id, domain_id, channel_id)
select :'roamer', :'gone', discord_channel_id from public.instructor where id = :'roamer';
delete from public.action_queue;
select private.queue_server_check('999000000000000001');
select public.next_discord_lookups(50) as handed \gset
select public.record_discord_result(
  (select id from public.action_queue where action = 'discord_server' and status = 'Processing' limit 1),
  jsonb_build_object('guild', jsonb_build_object('status', 200, 'body', jsonb_build_object('id', '999000000000000001', 'name', 'Test server')),
    'channels', jsonb_build_object('status', 200, 'body', jsonb_build_array(
      jsonb_build_object('id', '999000000000000099', 'type', 0, 'name', 'only-one', 'position', 1))),
    'members', '{"status": 200}'::jsonb)) as answered \gset
select ok(exists (select 1 from public.attention_item where domain_id = :'live' and title like 'Discord channel gone:%'),
  '32. a domain in use gets the task');
select ok(not exists (select 1 from public.attention_item where domain_id = :'gone' and title like 'Discord channel gone:%'),
  '33. an archived domain does not');
select tests.login_google('omar@example.com');
select public.set_discord_server_access('999000000000000001', 'Removed') as lost \gset
select tests.as_postgres();
select ok(exists (select 1 from public.attention_item where domain_id = :'live' and title = 'Discord server no longer available'),
  '34. removing access tells the domains in use');
select ok(not exists (select 1 from public.attention_item a join public.domain d on d.id = a.domain_id
                       where d.archived_at is not null and a.title = 'Discord server no longer available'),
  '35. no archived domain gets a task');
select is((:'lost'::jsonb ->> 'domains_that_lost_access')::int, 3, '36. and none is counted');

select * from finish();
rollback;
