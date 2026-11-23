-- Owner's live testing of 23 November 2026, the High findings (decision 331), on the live code:
-- 1. Archived instructors never hold on to a Discord account a real person needs; a real holder can be released with
--    "Release from <name>" and a clear explanation.
-- 2. A Discord check finishes or fails within a few minutes: never "Checking" for hours, and a server not approved
--    for the domain is said at once.
-- 3. Domain status rules: Draft and Paused always; Testing needs a testing channel and a testing email; Live needs an
--    approved Discord server that is ready, an alert channel, and a module in use with class times and an instructor.
--    What is missing is said exactly, with where to fix it; nothing changes silently.
-- 4. New and renamed Discord channels come in by themselves: the app asks for a fresh channel list when someone opens
--    an instructor or a domain (at most every 2 minutes a server).

alter table public.instructor add column if not exists discord_held_by uuid references public.instructor (id) on delete set null;
create index if not exists instructor_discord_held_by_idx on public.instructor (discord_held_by) where discord_held_by is not null;

-- ---------------------------------------------------------------- 2. Checks that never finished
create or replace function private.expire_stuck_checks(p_now timestamptz default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_msg text := 'The Discord check did not finish within a few minutes. Press Check again; if it happens again, see Settings, Connections.';
begin
  -- Work handed to the automation that never came back.
  update public.action_queue set status = 'Failed', error = 'Did not finish within 2 minutes.', processed_at = v_now
   where action like 'discord\_%' and status in ('Queued', 'Processing') and created_at < v_now - interval '2 minutes';
  -- What people see as "Checking", with no check left that could finish it.
  update public.instructor i set discord_status = 'Problem', discord_problem = v_msg, discord_checked_at = v_now, version = i.version
   where i.discord_status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.action = 'discord_member' and a.status in ('Queued', 'Processing')
                      and a.payload ->> 'id' = i.id::text);
  update public.team_member t set discord_status = 'Problem', discord_problem = v_msg, discord_checked_at = v_now, version = t.version
   where t.discord_status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.action = 'discord_member' and a.status in ('Queued', 'Processing')
                      and a.payload ->> 'id' = t.id::text);
  update public.discord_server s set status = 'Problem', problem = v_msg, checked_at = v_now
   where s.status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.action = 'discord_server' and a.status in ('Queued', 'Processing')
                      and a.payload ->> 'server_id' = s.id);
  update public.domain d set discord_status = 'Problem', discord_problem = v_msg, discord_checked_at = v_now, version = d.version
   where d.discord_status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.action = 'discord_server' and a.status in ('Queued', 'Processing')
                      and (a.payload ->> 'server_id' = d.discord_server_id or a.payload ->> 'domain_id' = d.id::text));
end;
$$;
revoke execute on function private.expire_stuck_checks(timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- 1. Release a Discord account from a real holder
create or replace function public.release_discord_account(p_instructor_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  h public.instructor;
begin
  perform private.require_team();
  select * into i from public.instructor where id = p_instructor_id;
  if i.id is null then raise exception 'Instructor not found.' using errcode = '22023'; end if;
  select * into h from public.instructor where id = i.discord_held_by;
  if h.id is null then
    raise exception 'Nobody else holds this Discord account now. Press Check Discord.' using errcode = '22023';
  end if;
  update public.instructor set discord_user_id = null, discord_status = 'NotSet', discord_problem = null, version = version
   where id = h.id;
  update public.instructor set discord_held_by = null, version = version where id = i.id;
  perform private.log_event('Discord', 'Discord account released from ' || h.full_name, 'instructor', h.id, null,
    jsonb_build_object('released_to', i.full_name), 'Released by hand so ' || i.full_name || ' can use it.',
    null, null, null, null, h.id);
  perform public.check_discord('instructor', i.id);
  return jsonb_build_object('ok', true, 'released_from', h.full_name);
end;
$$;
revoke execute on function public.release_discord_account(uuid) from public, anon;
grant execute on function public.release_discord_account(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- 4. A fresh channel list, by itself
create or replace function public.request_channel_refresh(p_domain_id uuid default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  s record;
  v_n int := 0;
begin
  perform private.require_team();
  for s in select ds.id from public.discord_server ds
            where ds.access = 'Approved' and ds.archived_at is null and ds.status <> 'Checking'
              and coalesce(ds.refreshed_at, '-infinity') < now() - interval '2 minutes'
              and (p_domain_id is null or ds.id = (select d.discord_server_id from public.domain d where d.id = p_domain_id)
                   or private.server_allowed(ds.id, p_domain_id)) loop
    -- A quiet refresh: the server keeps its status while the list is fetched, so a refresh that never comes back
    -- does not turn a server into "Needs a fix". A check someone asks for (Check again) still shows Checking.
    insert into public.action_queue (action, payload, requested_by)
    select 'discord_server', jsonb_build_object('server_id', s.id, 'quiet', true), private.current_team_member_id()
     where not exists (select 1 from public.action_queue a where a.action = 'discord_server' and a.status in ('Queued', 'Processing')
                          and a.payload ->> 'server_id' = s.id);
    if found then
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('queued', v_n);
end;
$$;
revoke execute on function public.request_channel_refresh(uuid) from public, anon;
grant execute on function public.request_channel_refresh(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- 3. Domain status rules
create or replace function public.domain_status_problems(p_domain_id uuid, p_status text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  d public.domain;
  s public.discord_server;
  v jsonb := '[]';
begin
  perform private.require_team();
  select * into d from public.domain where id = p_domain_id;
  if d.id is null then raise exception 'Domain not found.' using errcode = '22023'; end if;
  if p_status not in ('Draft', 'Test', 'Live', 'Paused') then
    raise exception 'Choose Draft, Testing, Live or Paused.' using errcode = '22023';
  end if;
  if p_status = 'Test' then
    if d.test_discord_channel_id is null then
      v := v || jsonb_build_object('text', 'Choose a testing channel for this domain (below, under Testing).', 'link', '/setup/domains?domain=' || d.id || '#testing');
    end if;
    if coalesce(trim(d.test_email), '') = '' then
      v := v || jsonb_build_object('text', 'Enter a testing email for this domain (below, under Testing).', 'link', '/setup/domains?domain=' || d.id || '#testing');
    end if;
  elsif p_status = 'Live' then
    select * into s from public.discord_server where id = d.discord_server_id;
    if d.discord_server_id is null then
      v := v || jsonb_build_object('text', 'Choose the domain''s Discord server.', 'link', '/setup/domains?domain=' || d.id || '#details');
    elsif not private.server_allowed(d.discord_server_id, d.id) then
      v := v || jsonb_build_object('text', coalesce(s.name, 'The Discord server') || ' is not approved for this domain. An admin approves it.', 'link', '/setup/domains?domain=' || d.id || '#details');
    elsif coalesce(s.status, '') <> 'Ready' or coalesce(d.discord_status, '') <> 'Ready' then
      v := v || jsonb_build_object('text', coalesce(s.name, 'The Discord server') || ' is not ready yet. Press Check on the domain''s Discord server and fix what it says.', 'link', '/setup/domains?domain=' || d.id || '#details');
    end if;
    if d.alert_discord_channel_id is null then
      v := v || jsonb_build_object('text', 'Choose an alert channel for the team.', 'link', '/setup/domains?domain=' || d.id || '#details');
    end if;
    if not exists (select 1 from public.module m
                    where m.domain_id = d.id and m.status = 'Active'
                      and exists (select 1 from public.class_pattern_item p where p.module_id = m.id)
                      and exists (select 1 from public.module_ranking r join public.instructor i on i.id = r.instructor_id
                                   where r.module_id = m.id and i.status = 'Active')) then
      v := v || jsonb_build_object('text', 'Make at least one module live (in use), with class times and at least 1 instructor in its instructor order.', 'link', '/setup/modules');
    end if;
  end if;
  return v;
end;
$$;
revoke execute on function public.domain_status_problems(uuid, text) from public, anon;
grant execute on function public.domain_status_problems(uuid, text) to authenticated, service_role;

create or replace function public.record_discord_result(p_action_id uuid, p_result jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  a public.action_queue;
  d public.domain;
  v_kind text;
  v_id uuid;
  v_user text;
  v_name text;
  v_label text;
  v_status text;
  v_problem text;
  v_out jsonb;
  s jsonb;
  v_denied text[] := '{}';
  v_searched text[] := '{}';
  v_server_name text;
  v_n int;
  v_srv text;
  r record;
begin
  if not private.is_service() then
    raise exception 'Only the automation can do this.' using errcode = '42501';
  end if;
  select * into a from public.action_queue where id = p_action_id;
  if a.id is null then raise exception 'Unknown action.' using errcode = '22023'; end if;

  if (p_result #>> '{me,status}')::int = 200 and p_result #>> '{me,body,id}' is not null then
    update public.app_config set discord_bot_user_id = p_result #>> '{me,body,id}' where id = 1
       and discord_bot_user_id is distinct from p_result #>> '{me,body,id}';
  end if;

  if a.action = 'discord_servers' then
    if (p_result #>> '{guilds,status}')::int = 200 then
      delete from public.discord_server where id not in (select x ->> 'id' from jsonb_array_elements(p_result #> '{guilds,body}') x);
      insert into public.discord_server (id, name, refreshed_at)
      select x ->> 'id', x ->> 'name', now() from jsonb_array_elements(p_result #> '{guilds,body}') x
      on conflict (id) do update set name = excluded.name, refreshed_at = now();
      get diagnostics v_n = row_count;
      for r in select s.id from public.discord_server s
                where s.archived_at is null and (s.checked_at is null or s.checked_at < now() - interval '24 hours')
                  and s.status <> 'Checking' loop
        perform private.queue_server_check(r.id);
      end loop;
      v_out := jsonb_build_object('ok', true, 'servers', v_n);
      perform private.log_event('Discord', 'Discord servers listed', null, null, null, v_out,
        'The bot is in ' || v_n || ' server' || case when v_n = 1 then '' else 's' end || '.');
    else
      v_problem := private.discord_http_problem((p_result #>> '{guilds,status}')::int, null);
      v_out := jsonb_build_object('ok', false, 'problem', v_problem);
      perform private.log_event('Discord', 'Discord check failed', null, null, null, v_out, v_problem);
    end if;

  elsif a.action = 'discord_server' then
    select * into d from public.domain where id = (a.payload ->> 'domain_id')::uuid;
    v_srv := coalesce(a.payload ->> 'server_id', d.discord_server_id);
    v_status := 'Ready';
    if coalesce((p_result #>> '{guild,status}')::int, 0) <> 200 then
      v_status := 'Problem';
      v_problem := private.discord_http_problem((p_result #>> '{guild,status}')::int, v_srv);
    else
      v_server_name := p_result #>> '{guild,body,name}';
      insert into public.discord_server (id, name) values (v_srv, v_server_name)
      on conflict (id) do update set name = excluded.name, refreshed_at = now();
      if coalesce((p_result #>> '{channels,status}')::int, 0) = 200 then
        delete from public.discord_channel where server_id = v_srv;
        insert into public.discord_channel (id, server_id, name, category, position, bot_can_post)
        select c ->> 'id', v_srv, c ->> 'name', cat ->> 'name', coalesce((c ->> 'position')::int, 0),
               case when (p_result #>> '{roles,status}')::int = 200 and (p_result #>> '{bot,status}')::int = 200
                    then private.discord_can_post(c, v_srv, p_result #> '{roles,body}',
                                                  p_result #> '{bot,body,roles}', p_result #>> '{bot,body,user,id}') end
          from jsonb_array_elements(p_result #> '{channels,body}') c
          left join lateral (select k from jsonb_array_elements(p_result #> '{channels,body}') k
                              where k ->> 'id' = c ->> 'parent_id' and (k ->> 'type')::int = 4 limit 1) x(cat) on true
         where (c ->> 'type')::int in (0, 5)
        on conflict (id) do update set server_id = excluded.server_id, name = excluded.name, category = excluded.category,
                                       position = excluded.position, bot_can_post = excluded.bot_can_post, refreshed_at = now();
        get diagnostics v_n = row_count;
        -- Keep the names of chosen channels up to date.
        update public.instructor_channel ic set channel_name = c.name, version = ic.version
          from public.discord_channel c where c.id = ic.channel_id and ic.channel_name is distinct from c.name;
        -- Only channels the bot may post in count.
        v_n := (select count(*) from public.discord_channel c where c.server_id = v_srv and c.bot_can_post is not false);
        -- DIS-11: an instructor channel that is gone (or the bot lost access) becomes a task now,
        -- before a message fails on it.
        perform private.raise_attention(dd.id, 'Other', 'Normal',
          'Discord channel gone: ' || i.full_name,
          'The Discord channel #' || coalesce(ic.channel_name, '?') || ' of ' || i.full_name || ' in ' || dd.name
            || case when ch.id is null then ' no longer exists or the bot cannot see it.' else ' does not let the bot post.' end
            || ' Choose a new channel on Setup, Instructors.',
          'channel-gone:' || ic.instructor_id || ':' || ic.domain_id,
          coalesce(nullif(private.domain_role_ids(dd.id, 'Ops'), '{}'), private.all_operations_ids()), now(),
          jsonb_build_object('instructor_id', ic.instructor_id), false)
          from public.instructor_channel ic join public.instructor i on i.id = ic.instructor_id
          left join public.discord_channel ch on ch.id = ic.channel_id
         join public.domain dd on dd.id = ic.domain_id
        where dd.discord_server_id = v_srv and i.status = 'Active' and (ch.id is null or ch.bot_can_post = false);
        if v_n = 0 then
          v_status := 'Problem';
          v_problem := 'The bot cannot see any text channels in ' || coalesce(v_server_name, 'this server')
            || '. Give the bot''s role access to the 1-1 category (View Channels, Send Messages, Embed Links, Read Message History).';
        end if;
      else
        v_status := 'Problem';
        v_problem := 'The bot could not list the channels of ' || coalesce(v_server_name, 'this server') || '. Give the bot''s role the View Channels permission.';
      end if;
      if v_status = 'Ready' and coalesce((p_result #>> '{members,status}')::int, 200) <> 200 then
        v_status := 'Problem';
        v_problem := 'The bot cannot search the members of ' || coalesce(v_server_name, 'this server')
          || ', so it cannot find people by username. In the Discord Developer Portal, open the bot and turn on Server Members Intent.';
      end if;
    end if;
    update public.domain set discord_status = v_status, discord_problem = v_problem, discord_checked_at = now(), version = version
     where discord_server_id = v_srv;
    update public.discord_server set status = v_status, problem = v_problem, checked_at = now() where id = v_srv;
    v_out := jsonb_build_object('ok', v_status = 'Ready', 'status', v_status, 'problem', v_problem, 'channels', v_n);
    perform private.log_event('Discord', case when v_status = 'Ready' then 'Discord server checked' else 'Discord server has a problem' end,
      null, null, null, v_out, coalesce(v_problem, coalesce(v_server_name, 'The server') || ' is ready: ' || coalesce(v_n, 0) || ' channels.'),
      coalesce(d.id, (select x.id from public.domain x where x.discord_server_id = v_srv order by x.name limit 1)),
      null, null, null, null, null, false, null,
      coalesce(v_server_name, (select name from public.discord_server where id = v_srv), d.name));

  elsif a.action = 'discord_member' then
    v_kind := a.payload ->> 'kind';
    v_id := (a.payload ->> 'id')::uuid;
    if v_kind = 'instructor' then
      select discord_username, full_name into v_name, v_label from public.instructor where id = v_id;
    else
      select discord_username, name into v_name, v_label from public.team_member where id = v_id;
    end if;
    if a.payload ? 'username' and a.payload ->> 'username' is distinct from v_name then
      -- The username changed while Discord was being searched: look again for the new one.
      update public.action_queue set status = 'Done', result = jsonb_build_object('ok', true, 'stale', true), processed_at = now()
       where id = p_action_id;
      perform private.queue_discord_member(v_kind, v_id);
      return jsonb_build_object('ok', true, 'status', 'Checking', 'stale', true);
    end if;
    for s in select * from jsonb_array_elements(coalesce(p_result -> 'searches', '[]')) loop
      v_server_name := coalesce((select name from public.discord_server where id = s ->> 'server_id'), 'the server');
      if (s ->> 'status')::int = 200 then
        v_searched := v_searched || v_server_name;
        select m #>> '{user,id}' into v_user from jsonb_array_elements(coalesce(s -> 'body', '[]')) m
         where lower(m #>> '{user,username}') = v_name limit 1;
        exit when v_user is not null;
      else
        v_denied := v_denied || v_server_name;
      end if;
    end loop;
    if v_name is null then
      v_status := 'NotSet';
    elsif v_user is not null then
      v_status := 'Found';
    elsif cardinality(v_searched) = 0 and cardinality(v_denied) > 0 then
      v_status := 'Problem';
      v_problem := 'The bot cannot search the members of ' || array_to_string(v_denied, ', ')
        || '. In the Discord Developer Portal, open the bot and turn on Server Members Intent, then press Check Discord.';
    elsif cardinality(v_searched) = 0 then
      v_status := 'Problem';
      v_problem := 'No Discord server is set up yet. Choose the server of each domain on Connections, then press Check Discord.';
    else
      v_status := 'NotFound';
      v_problem := 'Nobody with the username ' || v_name || ' is in ' || array_to_string(v_searched, ', ')
        || '. Check the spelling (lowercase, without @) and that they joined the server, then press Check Discord.';
    end if;
    -- Owner, 23 November 2026: archived instructors never hold on to a Discord account someone else needs. Their link
    -- is cleared (their history stays), and it is logged.
    if v_kind = 'instructor' and v_status = 'Found' then
      for r in select i2.id, i2.full_name from public.instructor i2
                where i2.discord_user_id = v_user and i2.id <> v_id and i2.status = 'Archived' loop
        update public.instructor set discord_user_id = null, discord_status = 'NotSet', discord_problem = null, version = version
         where id = r.id;
        perform private.log_event('Discord', 'Discord account released from ' || r.full_name, 'instructor', r.id, null,
          jsonb_build_object('released_to', v_label), r.full_name || ' is archived, so their Discord account goes to ' || v_label || '.',
          null, null, null, null, r.id);
      end loop;
      update public.instructor set discord_held_by = null where id = v_id and discord_held_by is not null;
    end if;
    begin
      if v_kind = 'instructor' then
        update public.instructor set discord_user_id = case when v_status = 'Found' then v_user else discord_user_id end,
               discord_status = v_status, discord_problem = v_problem, discord_checked_at = now(), version = version
         where id = v_id and discord_username is not distinct from v_name;
      else
        update public.team_member set discord_user_id = case when v_status = 'Found' then v_user else discord_user_id end,
               discord_status = v_status, discord_problem = v_problem, discord_checked_at = now(), version = version
         where id = v_id and discord_username is not distinct from v_name;
      end if;
    exception when unique_violation then
      v_status := 'Problem';
      -- The real holder: a real instructor in use (test instructors never block anyone, archived ones were released above).
      select i2.id, i2.full_name into r from public.instructor i2
       where i2.discord_user_id = v_user and i2.id <> v_id and not i2.is_test and i2.status <> 'Archived'
       order by i2.created_at limit 1;
      v_problem := 'This Discord account is already linked to '
        || coalesce(r.full_name, (select name from public.team_member where discord_user_id = v_user and id <> v_id limit 1), 'someone else')
        || case when r.id is not null then '. If that is an old record of the same person or a mistake, press Release from '
                  || r.full_name || ', then the account is linked here.' else '. Check the username.' end;
      v_user := null;
      if v_kind = 'instructor' then
        update public.instructor set discord_user_id = null, discord_status = v_status, discord_problem = v_problem,
               discord_held_by = r.id, discord_checked_at = now(), version = version where id = v_id;
      else
        update public.team_member set discord_user_id = null, discord_status = v_status, discord_problem = v_problem,
               discord_checked_at = now(), version = version where id = v_id;
      end if;
    end;
    v_out := jsonb_build_object('ok', v_status = 'Found', 'status', v_status, 'problem', v_problem);
    perform private.log_event('Discord', case v_status when 'Found' then 'Discord account found' else 'Discord account not found' end,
      case v_kind when 'instructor' then 'instructor' else 'team_member' end, v_id, null, v_out,
      coalesce(v_problem, v_label || ' is ' || v_name || ' on Discord.'),
      null, null, null, null, case v_kind when 'instructor' then v_id end, null, false, null, v_label);
  end if;

  update public.action_queue set status = case when coalesce((v_out ->> 'ok')::boolean, false) then 'Done' else 'Failed' end,
         result = v_out, error = v_out ->> 'problem', processed_at = now()
   where id = p_action_id;
  return v_out;
end;
$$;

create or replace function public.check_discord(p_kind text, p_id uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_kind = 'servers' then perform private.require_admin(); end if;
  if p_kind = 'servers' then
    insert into public.action_queue (action, payload, requested_by)
    select 'discord_servers', '{}', private.current_team_member_id()
     where not exists (select 1 from public.action_queue where action = 'discord_servers' and status in ('Queued', 'Processing'));
  elsif p_kind = 'server' then
    -- Owner, 23 November 2026: a server that is not approved for the domain is said at once, never left "Checking".
    update public.domain d set discord_status = case when d.discord_server_id is null then 'NotSet'
                                                    when not private.server_allowed(d.discord_server_id, d.id) then 'Problem'
                                                    else 'Checking' end,
           discord_problem = case when d.discord_server_id is not null and not private.server_allowed(d.discord_server_id, d.id)
             then coalesce((select s.name from public.discord_server s where s.id = d.discord_server_id), 'This server')
                  || ' is not approved for this domain. An admin approves it on Setup, Domains.' end,
           discord_checked_at = case when d.discord_server_id is not null and not private.server_allowed(d.discord_server_id, d.id)
             then now() else d.discord_checked_at end,
           version = d.version
     where d.id = p_id;
    if (select discord_server_id from public.domain where id = p_id) is not null
       and private.server_allowed((select discord_server_id from public.domain where id = p_id), p_id) then
      perform private.queue_server_check((select discord_server_id from public.domain where id = p_id));
    end if;
  elsif p_kind in ('instructor', 'team') then
    if p_kind = 'instructor' then
      update public.instructor set discord_status = 'Checking', discord_problem = null, version = version
       where id = p_id and discord_username is not null;
    else
      update public.team_member set discord_status = 'Checking', discord_problem = null, version = version
       where id = p_id and discord_username is not null;
    end if;
    perform private.queue_discord_member(p_kind, p_id);
  else
    raise exception 'Unknown Discord check.' using errcode = '22023';
  end if;
end;
$$;

create or replace function private.clock_tick(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_reason text;
  v_result text;
  v_runs int;
  st public.clock_state;
begin
  -- Owner, 23 November 2026: a Discord check finishes or fails within a few minutes, never "Checking" for hours.
  perform private.expire_stuck_checks(coalesce(p_now, now()));
  if not coalesce((select c.clock_enabled from public.app_config c where c.id = 1), false) then
    return jsonb_build_object('skipped', 'clock off');
  end if;
  select * into st from public.clock_state where id = 1 for update;
  -- One alert a month when the brakes start.
  v_runs := public.n8n_runs_this_month(v_now);
  if v_runs >= 8000 and st.budget_alert_month is distinct from date_trunc('month', v_now at time zone 'UTC')::date then
    perform private.log_event('System', 'n8n budget: replies read less often', null, null, null,
      jsonb_build_object('runs_this_month', v_runs,
        'reading', case when v_runs < 9300 then 'every 20 minutes' else 'only when n8n runs for other work' end));
    update public.clock_state set budget_alert_month = date_trunc('month', v_now at time zone 'UTC')::date where id = 1;
  end if;
  v_reason := private.clock_work(v_now);
  if v_reason is null then return jsonb_build_object('work', false); end if;
  if st.last_poke_at is not null and st.last_poke_at > v_now - interval '1 minute' then
    return jsonb_build_object('work', true, 'reason', v_reason, 'skipped', 'called less than a minute ago');
  end if;
  v_result := private.poke_n8n(v_reason);
  update public.clock_state
     set last_poke_at = case when v_result = 'sent' then v_now else last_poke_at end,
         last_reason = v_reason, last_result = v_result, updated_at = now()
   where id = 1;
  return jsonb_build_object('work', true, 'reason', v_reason, 'result', v_result);
end;
$$;

create or replace function public.set_domain_status(p_domain_id uuid, p_status text)
returns void language plpgsql security definer set search_path = ''
as $$
declare d public.domain;
begin
  perform private.require_team();
  select * into d from public.domain where id = p_domain_id for update;
  if d.id is null then raise exception 'Domain not found.' using errcode = '22023'; end if;
  if d.status = p_status then return; end if;
  -- Owner, 23 November 2026: what is missing is said exactly, and nothing changes.
  if jsonb_array_length(public.domain_status_problems(p_domain_id, p_status)) > 0 then
    raise exception '%', (select string_agg(x ->> 'text', ' ') from jsonb_array_elements(public.domain_status_problems(p_domain_id, p_status)) x)
      using errcode = '22023';
  end if;
  perform set_config('app.suppress_setup_log', 'on', true);
  update public.domain set status = p_status,
         test_clock_at = case when p_status = 'Test' or (p_status = 'Paused' and status = 'Test') then test_clock_at end
   where id = p_domain_id;
  perform set_config('app.suppress_setup_log', 'off', true);
  perform private.log_event('Setup changes',
    case p_status when 'Live' then 'Went live' when 'Test' then 'Testing turned on' when 'Paused' then 'Domain paused'
                  else 'Moved back to Draft' end,
    'domain', d.id, jsonb_build_object('status', d.status), jsonb_build_object('status', p_status), null, d.id);
end;
$$;
