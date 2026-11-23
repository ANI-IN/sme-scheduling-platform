-- Rollback of 20261123000036_live_high_fixes.sql
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
      v_problem := 'This Discord account is already used by '
        || coalesce((select full_name from public.instructor where discord_user_id = v_user and id <> v_id limit 1),
                    (select name from public.team_member where discord_user_id = v_user and id <> v_id limit 1), 'someone else')
        || '. Check the username.';
      v_user := null;
      if v_kind = 'instructor' then
        update public.instructor set discord_user_id = null, discord_status = v_status, discord_problem = v_problem,
               discord_checked_at = now(), version = version where id = v_id;
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
    update public.domain set discord_status = case when discord_server_id is null then 'NotSet' else 'Checking' end,
           discord_problem = null, version = version
     where id = p_id;
    if (select discord_server_id from public.domain where id = p_id) is not null then
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

drop function if exists public.domain_status_problems(uuid, text);
drop function if exists public.request_channel_refresh(uuid);
drop function if exists public.release_discord_account(uuid);
drop function if exists private.expire_stuck_checks(timestamptz);
drop index if exists public.instructor_discord_held_by_idx;
alter table public.instructor drop column if exists discord_held_by;
