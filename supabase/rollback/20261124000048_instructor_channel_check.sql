-- Rollback of 20261123000035_instructor_channel_check.sql
create or replace function public.next_discord_lookups(p_limit int default 20)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v jsonb := '[]'; a public.action_queue;
begin
  if not private.is_service() then
    raise exception 'Only the automation can do this.' using errcode = '42501';
  end if;
  -- Work handed out more than 10 minutes ago and never answered goes back in the queue.
  update public.action_queue set status = 'Queued'
   where status = 'Processing' and action like 'discord\_%' and updated_at < now() - interval '10 minutes';
  for a in
    -- Spread out (decision 262): one server list, three server checks and ten username searches a run.
    with r as (select q.id, q.action, row_number() over (partition by q.action order by q.created_at) n
                 from public.action_queue q where q.status = 'Queued' and q.action like 'discord\_%'),
         c as (select q.id from public.action_queue q join r on r.id = q.id
                where r.n <= case r.action when 'discord_servers' then 1 when 'discord_server' then 3 else 10 end
                order by q.created_at limit p_limit for update of q skip locked)
    update public.action_queue q set status = 'Processing',
           payload = q.payload || case when q.action = 'discord_member' then jsonb_build_object('username',
             case q.payload ->> 'kind' when 'instructor' then (select discord_username from public.instructor where id = (q.payload ->> 'id')::uuid)
                                       else (select discord_username from public.team_member where id = (q.payload ->> 'id')::uuid) end)
             else '{}'::jsonb end
      from c where q.id = c.id returning q.*
  loop
    v := v || jsonb_build_array(jsonb_build_object('action_id', a.id, 'action', a.action) || case a.action
      when 'discord_servers' then '{}'::jsonb
      when 'discord_server' then jsonb_build_object('server_id',
        coalesce(a.payload ->> 'server_id', (select discord_server_id from public.domain where id = (a.payload ->> 'domain_id')::uuid)),
        'bot_user_id', (select c.discord_bot_user_id from public.app_config c where c.id = 1))
      else jsonb_build_object('username', a.payload ->> 'username',
        'servers', private.member_servers(a.payload ->> 'kind', (a.payload ->> 'id')::uuid)) end);
  end loop;
  return v;
end;
$$;

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

drop function if exists public.check_instructor_channel(uuid, uuid, text);
drop function if exists private.discord_perms(jsonb, text, jsonb, jsonb, text);
drop function if exists private.parse_discord_channel(text);
alter table public.instructor_channel drop column if exists ready_at;
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
              and tablename = 'channel_check') then
    alter publication supabase_realtime drop table public.channel_check;
  end if;
end;
$$;
drop table if exists public.channel_check;
