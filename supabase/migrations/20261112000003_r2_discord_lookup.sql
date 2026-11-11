-- Release 2 Milestone C: Discord.
-- Each domain uses an existing Discord server (the app never creates servers or channels).
-- The bot lists the servers it was invited to and their channels; people choose from those lists.
-- Instructors and team members give their Discord username; the bot finds their user ID by searching
-- the server's members (Server Members Intent). Nobody is asked for a Discord user ID any more.
-- Discord calls are made by the automation (n8n WF6, or `npm run discord -w scripts` locally) through
-- the action queue: next_discord_lookups hands out the work, record_discord_result saves the answers.

-- ------------------------------------------------------------------ servers and channels
create table public.discord_server (
  id text primary key check (id ~ '^\d{17,20}$'),
  name text not null,
  refreshed_at timestamptz not null default now()
);
comment on table public.discord_server is 'Discord servers the bot is in (filled by the automation).';

create table public.discord_channel (
  id text primary key check (id ~ '^\d{17,20}$'),
  server_id text not null,
  name text not null,
  category text,
  position int not null default 0,
  refreshed_at timestamptz not null default now()
);
create index discord_channel_server_idx on public.discord_channel (server_id, category, position);
comment on table public.discord_channel is 'Text channels the bot can see in each server (filled by the automation).';

do $$
declare t text;
begin
  foreach t in array array['discord_server', 'discord_channel'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (private.is_team_user())', t || '_team_read', t);
  end loop;
end $$;

alter table public.domain
  add column discord_server_id text check (discord_server_id ~ '^\d{17,20}$'),
  add column discord_status text not null default 'NotSet'
    check (discord_status in ('NotSet', 'Checking', 'Ready', 'Problem')),
  add column discord_problem text,
  add column discord_checked_at timestamptz;
comment on column public.domain.discord_server_id is 'The existing Discord server this domain uses.';
-- Every domain used the one company server so far.
update public.domain d set discord_server_id = c.discord_guild_id, version = d.version
  from public.app_config c where c.id = 1 and c.discord_guild_id is not null;

-- Activity history gets a Discord category for every Discord check and lookup.
alter table public.history_event drop constraint history_event_category_check;
alter table public.history_event add constraint history_event_category_check check (category = any (array[
  'Messages', 'Instructor responses', 'Bookings', 'Team actions', 'Setup changes', 'Help requests', 'Reminders', 'System', 'Discord']));

-- ------------------------------------------------------------------ people: username and status
do $$
declare t text;
begin
  foreach t in array array['instructor', 'team_member'] loop
    execute format($f$alter table public.%I
      add column discord_username text check (discord_username ~ '^[a-z0-9_.]{2,32}$'),
      add column discord_status text not null default 'NotSet'
        check (discord_status in ('NotSet', 'Checking', 'Found', 'NotFound', 'Problem')),
      add column discord_problem text,
      add column discord_checked_at timestamptz$f$, t);
    execute format($f$update public.%I set discord_status = 'Found' where discord_user_id is not null$f$, t);
  end loop;
end $$;
comment on column public.instructor.discord_username is 'Discord username (lowercase, no @). The user ID is found from it.';
comment on column public.team_member.discord_username is 'Optional Discord username. Without it the person gets email instead.';

-- The channel of an instructor in each domain (a channel in that domain's server, usually in "1-1").
create table public.instructor_channel (
  instructor_id uuid not null references public.instructor (id) on delete cascade,
  domain_id uuid not null references public.domain (id) on delete cascade,
  channel_id text not null check (channel_id ~ '^\d{17,20}$'),
  channel_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  primary key (instructor_id, domain_id)
);
alter table public.instructor_channel enable row level security;
revoke all on public.instructor_channel from anon;
grant all on public.instructor_channel to service_role;
grant select on public.instructor_channel to authenticated;
create policy instructor_channel_team_read on public.instructor_channel for select to authenticated using (private.is_team_user());
create trigger instructor_channel_touch before update on public.instructor_channel for each row execute function private.touch_row();
create trigger instructor_channel_created_by before insert on public.instructor_channel for each row execute function private.set_created_by();
create trigger instructor_channel_history after insert or update or delete on public.instructor_channel
  for each row execute function private.log_setup_change();

-- Existing channels: the instructor's one channel, for every domain in that server.
insert into public.instructor_channel (instructor_id, domain_id, channel_id)
select i.id, d.id, i.discord_channel_id
  from public.instructor i join public.domain d
    on d.discord_server_id is not distinct from coalesce(i.discord_server_id, d.discord_server_id)
 where i.discord_channel_id is not null
on conflict do nothing;

alter table public.action_queue drop constraint if exists action_queue_action_check;
alter table public.action_queue add constraint action_queue_action_check
  check (action in ('deliver', 'run_check_now', 'send_test_alert', 'discord_servers', 'discord_server', 'discord_member'));

-- ------------------------------------------------------------------ usernames
/** Lowercase, without spaces or a leading @. Old style names like "name#1234" are refused. */
create or replace function private.clean_discord_username(p text)
returns text language sql immutable set search_path = ''
as $$ select nullif(lower(regexp_replace(trim(coalesce(p, '')), '^@', '')), ''); $$;

create or replace function private.discord_username_before_write()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  new.discord_username := private.clean_discord_username(new.discord_username);
  if new.discord_username is not null and new.discord_username !~ '^[a-z0-9_.]{2,32}$' then
    raise exception 'A Discord username has 2 to 32 lowercase letters, numbers, dots or underscores, for example maya.k (without @).'
      using errcode = '22023';
  end if;
  if tg_op = 'INSERT' or new.discord_username is distinct from old.discord_username then
    if new.discord_username is null then
      -- Removing the username removes the Discord account found from it.
      if tg_op = 'UPDATE' and old.discord_username is not null then new.discord_user_id := null; end if;
      new.discord_status := case when new.discord_user_id is not null then 'Found' else 'NotSet' end;
      new.discord_problem := null;
    else
      new.discord_user_id := null;
      new.discord_status := 'Checking';
      new.discord_problem := null;
    end if;
  end if;
  return new;
end;
$$;

/** After a new username is saved, ask the automation to find the person in Discord. */
create or replace function private.discord_username_after_write()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.discord_status = 'Checking' and (tg_op = 'INSERT' or old.discord_status is distinct from 'Checking'
                                           or new.discord_username is distinct from old.discord_username) then
    perform private.queue_discord_member(case tg_table_name when 'instructor' then 'instructor' else 'team' end, new.id);
  end if;
  return new;
end;
$$;

create or replace function private.queue_discord_member(p_kind text, p_id uuid)
returns void language sql security definer set search_path = ''
as $$
  insert into public.action_queue (action, payload, requested_by)
  select 'discord_member', jsonb_build_object('kind', p_kind, 'id', p_id), private.current_team_member_id()
   where not exists (select 1 from public.action_queue a where a.action = 'discord_member' and a.status in ('Queued', 'Processing')
                        and a.payload ->> 'id' = p_id::text);
$$;

do $$
declare t text;
begin
  foreach t in array array['instructor', 'team_member'] loop
    execute format('create trigger %I before insert or update on public.%I for each row execute function private.discord_username_before_write()',
                   t || '_discord_username', t);
    execute format('create trigger %I after insert or update on public.%I for each row execute function private.discord_username_after_write()',
                   t || '_discord_lookup', t);
  end loop;
end $$;

/** The servers to search for a person: the servers of their domains first, then every other server. */
create or replace function private.member_servers(p_kind text, p_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with mine as (
    select d.discord_server_id s, 0 o from public.domain d
     where d.discord_server_id is not null
       and (case when p_kind = 'instructor' then
              exists (select 1 from public.instructor_channel c where c.instructor_id = p_id and c.domain_id = d.id)
              or exists (select 1 from public.module_ranking r join public.module m on m.id = r.module_id
                          where r.instructor_id = p_id and m.domain_id = d.id)
            else exists (select 1 from public.domain_team t where t.team_member_id = p_id and t.domain_id = d.id) end)
    union all
    select d.discord_server_id, 1 from public.domain d where d.discord_server_id is not null
  )
  select coalesce(jsonb_agg(x.s order by x.o), '[]') from (select s, min(o) o from mine group by s) x;
$$;

-- ------------------------------------------------------------------ what people press in the app
/** Check Discord again: the list of servers, one domain's server and channels, or one person. */
create or replace function public.check_discord(p_kind text, p_id uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_kind = 'servers' then
    insert into public.action_queue (action, payload, requested_by)
    select 'discord_servers', '{}', private.current_team_member_id()
     where not exists (select 1 from public.action_queue where action = 'discord_servers' and status in ('Queued', 'Processing'));
  elsif p_kind = 'server' then
    update public.domain set discord_status = case when discord_server_id is null then 'NotSet' else 'Checking' end,
           discord_problem = null, version = version
     where id = p_id;
    if (select discord_server_id from public.domain where id = p_id) is not null then
      insert into public.action_queue (action, payload, requested_by)
      select 'discord_server', jsonb_build_object('domain_id', p_id), private.current_team_member_id()
       where not exists (select 1 from public.action_queue where action = 'discord_server' and status in ('Queued', 'Processing')
                            and payload ->> 'domain_id' = p_id::text);
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
grant execute on function public.check_discord(text, uuid) to authenticated, service_role;
revoke execute on function public.check_discord(text, uuid) from anon;

/** Choose the Discord server of a domain (from the servers the bot is in). */
create or replace function public.set_domain_discord_server(p_domain_id uuid, p_server_id text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_server_id is not null and not exists (select 1 from public.discord_server where id = p_server_id) then
    raise exception 'The bot is not in that Discord server. Invite the bot first, then press Refresh.' using errcode = '22023';
  end if;
  update public.domain set discord_server_id = p_server_id, version = version where id = p_domain_id;
  perform public.check_discord('server', p_domain_id);
end;
$$;
grant execute on function public.set_domain_discord_server(uuid, text) to authenticated;
revoke execute on function public.set_domain_discord_server(uuid, text) from anon;

/** Choose an instructor's channel in one domain (null removes it: messages then go by direct message). */
create or replace function public.set_instructor_channel(p_instructor_id uuid, p_domain_id uuid, p_channel_id text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_server text := (select discord_server_id from public.domain where id = p_domain_id);
  c public.discord_channel;
begin
  perform private.require_team();
  if p_channel_id is null then
    delete from public.instructor_channel where instructor_id = p_instructor_id and domain_id = p_domain_id;
    return;
  end if;
  select * into c from public.discord_channel where id = p_channel_id;
  if c.id is null then
    raise exception 'That channel is not in the list. Press Refresh channels on Connections, then choose again.' using errcode = '22023';
  end if;
  if v_server is distinct from c.server_id then
    raise exception 'That channel is in another Discord server. Choose a channel in the server of this domain.' using errcode = '22023';
  end if;
  insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name)
  values (p_instructor_id, p_domain_id, c.id, c.name)
  on conflict (instructor_id, domain_id) do update set channel_id = excluded.channel_id, channel_name = excluded.channel_name;
  -- A new channel needs a new contact check.
  update public.instructor set verified_at = null, discord_failed_at = null, version = version
   where id = p_instructor_id and verified_at is not null;
end;
$$;
grant execute on function public.set_instructor_channel(uuid, uuid, text) to authenticated;
revoke execute on function public.set_instructor_channel(uuid, uuid, text) from anon;

-- ------------------------------------------------------------------ what the automation does
/** Work for the automation: each item says which Discord calls to make. Service role only. */
create or replace function public.next_discord_lookups(p_limit int default 20)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v jsonb := '[]'; a public.action_queue;
begin
  if not private.is_service() then
    raise exception 'Only the automation can do this.' using errcode = '42501';
  end if;
  for a in
    with c as (select q.id from public.action_queue q where q.status = 'Queued' and q.action like 'discord\_%'
                order by q.created_at limit p_limit for update skip locked)
    update public.action_queue q set status = 'Processing' from c where q.id = c.id returning q.*
  loop
    v := v || jsonb_build_object('action_id', a.id, 'action', a.action) || case a.action
      when 'discord_servers' then '{}'::jsonb
      when 'discord_server' then jsonb_build_object('server_id',
        (select discord_server_id from public.domain where id = (a.payload ->> 'domain_id')::uuid))
      else jsonb_build_object('username',
        case a.payload ->> 'kind' when 'instructor' then (select discord_username from public.instructor where id = (a.payload ->> 'id')::uuid)
                                  else (select discord_username from public.team_member where id = (a.payload ->> 'id')::uuid) end,
        'servers', private.member_servers(a.payload ->> 'kind', (a.payload ->> 'id')::uuid)) end;
  end loop;
  return v;
end;
$$;
grant execute on function public.next_discord_lookups(int) to service_role;
revoke execute on function public.next_discord_lookups(int) from anon, authenticated, public;

/**
 * Save what Discord answered. p_result holds the raw HTTP status and body of each call:
 *   discord_servers: {"guilds": {"status": 200, "body": [{"id", "name"}]}}
 *   discord_server:  {"guild": {...}, "channels": {...}, "members": {"status"}}   (members = a member search probe)
 *   discord_member:  {"searches": [{"server_id", "status", "body": [{"user": {"id", "username"}}]}]}
 * The database decides what the answer means, so the rules are tested here (pgTAP 170).
 */
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
begin
  if not private.is_service() then
    raise exception 'Only the automation can do this.' using errcode = '42501';
  end if;
  select * into a from public.action_queue where id = p_action_id;
  if a.id is null then raise exception 'Unknown action.' using errcode = '22023'; end if;

  if a.action = 'discord_servers' then
    if (p_result #>> '{guilds,status}')::int = 200 then
      delete from public.discord_server where id not in (select x ->> 'id' from jsonb_array_elements(p_result #> '{guilds,body}') x);
      insert into public.discord_server (id, name, refreshed_at)
      select x ->> 'id', x ->> 'name', now() from jsonb_array_elements(p_result #> '{guilds,body}') x
      on conflict (id) do update set name = excluded.name, refreshed_at = now();
      get diagnostics v_n = row_count;
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
    v_status := 'Ready';
    if coalesce((p_result #>> '{guild,status}')::int, 0) <> 200 then
      v_status := 'Problem';
      v_problem := private.discord_http_problem((p_result #>> '{guild,status}')::int, d.discord_server_id);
    else
      v_server_name := p_result #>> '{guild,body,name}';
      insert into public.discord_server (id, name) values (d.discord_server_id, v_server_name)
      on conflict (id) do update set name = excluded.name, refreshed_at = now();
      if coalesce((p_result #>> '{channels,status}')::int, 0) = 200 then
        delete from public.discord_channel where server_id = d.discord_server_id;
        insert into public.discord_channel (id, server_id, name, category, position)
        select c ->> 'id', d.discord_server_id, c ->> 'name', cat ->> 'name', coalesce((c ->> 'position')::int, 0)
          from jsonb_array_elements(p_result #> '{channels,body}') c
          left join lateral (select k from jsonb_array_elements(p_result #> '{channels,body}') k
                              where k ->> 'id' = c ->> 'parent_id' and (k ->> 'type')::int = 4 limit 1) x(cat) on true
         where (c ->> 'type')::int in (0, 5)
        on conflict (id) do update set server_id = excluded.server_id, name = excluded.name, category = excluded.category,
                                       position = excluded.position, refreshed_at = now();
        get diagnostics v_n = row_count;
        -- Keep the names of chosen channels up to date.
        update public.instructor_channel ic set channel_name = c.name, version = ic.version
          from public.discord_channel c where c.id = ic.channel_id and ic.channel_name is distinct from c.name;
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
     where id = d.id;
    v_out := jsonb_build_object('ok', v_status = 'Ready', 'status', v_status, 'problem', v_problem, 'channels', v_n);
    perform private.log_event('Discord', case when v_status = 'Ready' then 'Discord server checked' else 'Discord server has a problem' end,
      'domain', d.id, null, v_out, coalesce(v_problem, coalesce(v_server_name, 'The server') || ' is ready: ' || coalesce(v_n, 0) || ' channels.'),
      d.id, null, null, null, null, null, false, null, d.name);

  elsif a.action = 'discord_member' then
    v_kind := a.payload ->> 'kind';
    v_id := (a.payload ->> 'id')::uuid;
    if v_kind = 'instructor' then
      select discord_username, full_name into v_name, v_label from public.instructor where id = v_id;
    else
      select discord_username, name into v_name, v_label from public.team_member where id = v_id;
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
        update public.instructor set discord_user_id = v_user, discord_status = v_status, discord_problem = v_problem,
               discord_checked_at = now(), version = version
         where id = v_id and discord_username is not distinct from v_name;
      else
        update public.team_member set discord_user_id = v_user, discord_status = v_status, discord_problem = v_problem,
               discord_checked_at = now(), version = version
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
grant execute on function public.record_discord_result(uuid, jsonb) to service_role;
revoke execute on function public.record_discord_result(uuid, jsonb) from anon, authenticated, public;

/** What to do about a Discord error, in plain words. */
create or replace function private.discord_http_problem(p_status int, p_server text)
returns text language sql immutable set search_path = ''
as $$
  select case
    when p_status = 401 then 'The bot''s login (token) is wrong or missing. Whoever looks after the automation must update the Discord bot setting.'
    when p_status in (403, 404) and p_server is not null then 'The bot is not in this Discord server. Open the invite link on Connections, add the bot to the server, then press Check again.'
    when p_status = 429 then 'Discord asked us to slow down. Press Check again in a minute.'
    when p_status is null or p_status = 0 then 'Discord could not be reached. Press Check again later.'
    else 'Discord answered with error ' || p_status || '. Press Check again later.' end;
$$;

create or replace function private.eligibility(p_instructor uuid, p_mw uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_domain uuid;
  v_status text;
  v_reason text;
begin
  select * into i from public.instructor where id = p_instructor;
  select w.domain_id, d.status into v_domain, v_status
    from public.module_week w join public.domain d on d.id = w.domain_id where w.id = p_mw;
  if i.id is null then return 'Unknown instructor'; end if;
  if i.status = 'Inactive' then return 'Inactive'; end if;
  if i.status = 'Archived' then return 'Archived'; end if;
  if v_status = 'Live' and i.is_test then return 'Test instructor (not allowed in Live domains)'; end if;
  if v_status = 'Live' and i.verified_at is null then return 'Not verified'; end if;
  if i.discord_user_id is null and i.email_bounced_at is not null then return 'No working contact details'; end if;

  select 'Unavailable ' || to_char(u.from_date, 'Mon FMDD') || ' to ' || to_char(u.to_date, 'Mon FMDD')
    into v_reason
    from public.instructor_unavailability u
   where u.instructor_id = p_instructor
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and (c.starts_at at time zone private.region_tz(c.region))::date between u.from_date and u.to_date)
   order by u.from_date limit 1;
  if v_reason is not null then return v_reason; end if;

  -- Clashes are checked on the real time (UTC), across every cohort, domain and region.
  return private.week_clash(p_instructor, p_mw);
end;
$$;
create or replace function private.message_block_reason(m public.message)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  c public.app_config;
  i public.instructor;
  v_server text;
  v_domain text;
begin
  if m.direction <> 'Outbound' then return null; end if;
  select * into c from public.app_config where id = 1;
  if m.instructor_id is not null then
    select * into i from public.instructor where id = m.instructor_id;
  end if;
  if c.environment = 'Production' and m.audience = 'Instructor' and coalesce(i.is_test, false) then
    return 'Production never messages test instructors.';
  end if;
  if c.environment = 'Sandbox' then
    if m.channel = 'Email' then
      v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
      if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.sandbox_allowed_email_domains) x))) then
        return 'Sandbox only sends email to allowed domains. ' || coalesce(nullif(v_domain, ''), 'This address') || ' is not on the list.';
      end if;
    elsif m.channel = 'Discord' then
      -- A post goes to the server of its channel. A direct message is allowed only to a test instructor
      -- or a team member (Sandbox never contacts real instructors).
      if m.discord_dm_user_id is not null and m.discord_channel_id is null then
        if m.audience = 'Instructor' and not coalesce(i.is_test, false) then
          return 'Sandbox only sends direct messages to test instructors.';
        end if;
        return null;
      end if;
      v_server := coalesce((select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id),
                           (select dm.discord_server_id from public.domain dm where dm.id = m.domain_id), c.discord_guild_id);
      if v_server is null or not (v_server = any (c.sandbox_allowed_discord_servers)) then
        return 'Sandbox only posts to allowed Discord servers. ' || coalesce('Server ' || v_server, 'This server') || ' is not on the list.';
      end if;
    end if;
  end if;
  return null;
end;
$$;

create or replace function public.discord_watchlist()
returns table (channel_id text, instructor_id uuid, discord_user_id text, last_message_id text)
language sql stable security definer set search_path = ''
as $$
  select distinct ch.channel_id, i.id, i.discord_user_id, c.last_message_id
    from public.instructor i
    join lateral (select ic.channel_id from public.instructor_channel ic where ic.instructor_id = i.id
                  union select i.discord_channel_id where i.discord_channel_id is not null) ch on true
    left join public.discord_cursor c on c.channel_id = ch.channel_id
   where i.discord_user_id is not null and i.status = 'Active'
     and private.is_service()
     and (exists (select 1 from public.request r where r.instructor_id = i.id and r.status in ('Sent', 'Reminded'))
          or exists (select 1 from public.booking b join public.module_week w on w.id = b.module_week_id
                      where b.instructor_id = i.id and b.status = 'Active' and w.first_class_at > now())
          or exists (select 1 from public.help_request h where h.requester_instructor_id = i.id
                      and h.status in ('Open', 'InProgress', 'WaitingOnInstructor')));
$$;

create or replace function private.instructor_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_other text;
  v_guild text := (select c.discord_guild_id from public.app_config c where c.id = 1);
  m text[];
begin
  new.primary_email := lower(trim(new.primary_email));
  new.full_name := trim(new.full_name);
  -- Release 2: channels are chosen per domain from the bot's list (instructor_channel). An old link
  -- is still read so older data keeps working.
  if new.discord_channel_link is not null and trim(new.discord_channel_link) <> ''
     and (tg_op = 'INSERT' or new.discord_channel_link is distinct from old.discord_channel_link) then
    m := regexp_match(trim(new.discord_channel_link),
                      '^https://(?:www\.|ptb\.|canary\.)?discord(?:app)?\.com/channels/(\d{17,20})/(\d{17,20})/?$');
    if m is null then
      raise exception 'The Discord channel link should look like https://discord.com/channels/<server id>/<channel id>.'
        using errcode = '22023';
    end if;
    if v_guild is not null and m[1] <> v_guild and not exists (select 1 from public.domain where discord_server_id = m[1]) then
      raise exception 'This Discord channel link is from a different server. Use a channel in the company server.'
        using errcode = '22023';
    end if;
    new.discord_server_id := m[1];
    new.discord_channel_id := m[2];
  end if;
  v_other := private.instructor_duplicate_name(new.id, new.primary_email, new.discord_user_id, new.is_test);
  if v_other is not null then
    raise exception 'An instructor with this email or Discord ID already exists: %', v_other using errcode = '23505';
  end if;
  if tg_op = 'UPDATE' and (
       new.primary_email is distinct from old.primary_email
       or new.discord_user_id is distinct from old.discord_user_id
       or new.discord_channel_id is distinct from old.discord_channel_id) then
    new.verified_at := null;   -- changing contact details removes the Verified badge
    if new.primary_email is distinct from old.primary_email then
      new.email_bounced_at := null;
    end if;
    if new.discord_channel_id is distinct from old.discord_channel_id then
      new.discord_failed_at := null;
    end if;
  end if;
  return new;
end;
$$;
create or replace function public.my_account(p_signed_in boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_email text := private.current_email();
  v_problem text;
  v_meta jsonb := (select auth.jwt()) -> 'user_metadata';
  v_name text;
  t public.team_member;
begin
  if (select auth.role()) is distinct from 'authenticated' or v_email is null then
    raise exception 'Please sign in first.' using errcode = '42501';
  end if;
  v_problem := private.sign_in_problem(v_email, private.jwt_provider(), private.jwt_hd());
  if v_problem is not null then
    if p_signed_in then
      perform set_config('app.actor_kind', 'System', true);
      perform set_config('app.actor_label', 'Sign in', true);
      perform private.log_event('System', 'Sign in refused', 'team_member',
        (select id from public.team_member where lower(email) = v_email), null, null,
        v_problem || ' Account: ' || v_email || '.');
    end if;
    return jsonb_build_object('allowed', false, 'message', v_problem);
  end if;

  select * into t from public.team_member where lower(email) = v_email;
  if t.id is null then
    v_name := coalesce(nullif(trim(v_meta ->> 'full_name'), ''), nullif(trim(v_meta ->> 'name'), ''),
                       initcap(replace(replace(split_part(v_email, '@', 1), '.', ' '), '_', ' ')));
    -- The app can ask twice at the same moment on a first sign in: the second request
    -- finds the row the first one created instead of failing.
    insert into public.team_member (name, email, auth_user_id, last_sign_in_at)
    values (v_name, v_email, (select auth.uid()), now())
    on conflict do nothing;
    select * into t from public.team_member where lower(email) = v_email;
  elsif p_signed_in then
    perform set_config('app.suppress_setup_log', 'on', true);
    update public.team_member
       set last_sign_in_at = now(), auth_user_id = coalesce(auth_user_id, (select auth.uid()))
     where id = t.id
    returning * into t;
    perform set_config('app.suppress_setup_log', 'off', true);
  end if;
  if p_signed_in then
    perform private.log_event('Team actions', 'Signed in', 'team_member', t.id);
  end if;
  return jsonb_build_object(
    'allowed', true,
    'member', jsonb_build_object('id', t.id, 'name', t.name, 'email', t.email, 'discord_user_id', t.discord_user_id,
                                 'job_title', t.job_title, 'is_placeholder', t.is_placeholder),
    'needs_discord', t.discord_user_id is null and t.discord_username is null and t.discord_prompt_dismissed_at is null,
    'environment', (select c.environment from public.app_config c where c.id = 1));
end;
$$;

drop function if exists public.update_my_profile(text, boolean);
create or replace function public.update_my_profile(p_discord_username text default null, p_dismiss_discord_prompt boolean default false)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_id uuid := private.current_team_member_id();
begin
  perform private.require_team();
  if v_id is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  if private.clean_discord_username(p_discord_username) is not null then
    update public.team_member set discord_username = p_discord_username, version = version where id = v_id;
  elsif p_dismiss_discord_prompt then
    perform set_config('app.suppress_setup_log', 'on', true);
    update public.team_member set discord_prompt_dismissed_at = now(), version = version where id = v_id;
    perform set_config('app.suppress_setup_log', 'off', true);
  end if;
end;
$$;
grant execute on function public.update_my_profile(text, boolean) to authenticated;
revoke execute on function public.update_my_profile(text, boolean) from anon;

create or replace function private.load_sandbox_seed(p_test_email text default null, p_test_discord_user_id text default null,
  p_test_channel_id text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_local text := coalesce(nullif(split_part(coalesce(p_test_email, ''), '@', 1), ''), 'sandbox.instructor');
  v_mail_domain text := coalesce(nullif(split_part(coalesce(p_test_email, ''), '@', 2), ''), 'example.com');
  v_chan text := coalesce(p_test_channel_id, '100000000000000002');
  v_owner uuid; v_ops uuid; v_esc uuid;
  v_dom uuid; v_mod uuid; v_coh_we uuid; v_coh_wd uuid;
  v_tests uuid[] := '{}';
  v_i uuid;
  d record; m record;
  k int;
  v_first_we date; v_first_wd date;
  n_weeks int := 0;
  v_rows jsonb;
begin
  perform set_config('app.actor_kind', 'System', true);
  perform set_config('app.actor_label', 'Sandbox data', true);

  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Owner', 'sandbox.owner@' || v_mail_domain, 'Product manager', true) returning id into v_owner;
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Operations', 'sandbox.operations@' || v_mail_domain, 'Operations', true) returning id into v_ops;
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Escalation', 'sandbox.escalation@' || v_mail_domain, 'Lead', true) returning id into v_esc;

  for k in 1 .. 6 loop
    insert into public.instructor (full_name, primary_email, discord_user_id, is_test, verified_at, notes)
    values ('Test Instructor ' || chr(64 + k), lower(v_local || '+' || chr(96 + k) || '@' || v_mail_domain),
            p_test_discord_user_id, true, now(), 'Sandbox test instructor. Messages go to the testing channel.')
    returning id into v_i;
    v_tests := v_tests || v_i;
  end loop;

  -- Next Saturday and next Tuesday (Pacific), so both cohorts start within two weeks.
  v_first_we := (now() at time zone 'America/Los_Angeles')::date + ((6 - extract(dow from now() at time zone 'America/Los_Angeles')::int + 7) % 7) + 7;
  v_first_wd := (now() at time zone 'America/Los_Angeles')::date + ((2 - extract(dow from now() at time zone 'America/Los_Angeles')::int + 7) % 7) + 7;

  for d in select * from (values ('Backend', array['Database Design', 'API Design', 'Concurrency']),
                                 ('Fullstack', array['React Basics', 'Node Services', 'Deployment'])) x(name, mods) loop
    insert into public.domain (name, status, alert_discord_channel_id, test_discord_channel_id, test_email, discord_server_id)
    values (d.name, 'Test', v_chan, v_chan, lower(v_local || '+testing@' || v_mail_domain),
            (select c.discord_guild_id from public.app_config c where c.id = 1))
    returning id into v_dom;
    insert into public.domain_team (domain_id, team_member_id, role)
    values (v_dom, v_ops, 'Operations'), (v_dom, v_esc, 'Escalation');
    insert into public.cohort (domain_id, name, start_date, status) values (v_dom, 'Weekend cohort', v_first_we, 'Running')
    returning id into v_coh_we;
    insert into public.cohort (domain_id, name, start_date, status, region)
    values (v_dom, 'Weekday cohort', v_first_wd, 'Running', case when d.name = 'Fullstack' then 'India' else 'US' end)
    returning id into v_coh_wd;
    for k in 1 .. cardinality(d.mods) loop
      insert into public.module (domain_id, name, rotation_order) values (v_dom, d.mods[k], k) returning id into v_mod;
      insert into public.module_owner (module_id, team_member_id) values (v_mod, v_owner);
      insert into public.module_resource (module_id, title, url)
      values (v_mod, d.mods[k] || ' module page', 'https://example.com/sandbox/' || lower(replace(d.mods[k], ' ', '-')));
      -- Module default (used by the weekend cohort): Saturday live class and Sunday review.
      insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
      values (v_mod, 'Live class', '{module}: Live class', 0, '09:00', 240, 1),
             (v_mod, 'Assignment review', '{module}: Assignment review', 1, '10:00', 120, 2);
      -- Weekday cohort: Tuesday and Thursday evenings.
      insert into public.class_pattern_item (module_id, cohort_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
      values (v_mod, v_coh_wd, 'Live class', '{module}: Live class', 0, case when d.name = 'Fullstack' then '19:30' else '18:00' end::time, 120, 1),
             (v_mod, v_coh_wd, 'Assignment review', '{module}: Assignment review', 2, case when d.name = 'Fullstack' then '19:30' else '18:00' end::time, 90, 2);
      -- Instructor order: three test instructors, rotated so each module has a different Primary.
      insert into public.module_ranking (module_id, instructor_id, rank)
      select v_mod, v_tests[((k - 1 + j) % 6) + 1], j + 1 from generate_series(0, 2) j;
    end loop;
    select id into v_mod from public.module where domain_id = v_dom and rotation_order = 1;
    v_rows := public.generate_classes(v_dom, v_mod, array(select v_first_we + 7 * j from generate_series(0, 7) j), 'Weekend cohort');
    n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Sandbox data') ->> 'created')::int, 0);
    v_rows := public.generate_classes(v_dom, v_mod, array(select v_first_wd + 7 * j from generate_series(0, 7) j), 'Weekday cohort');
    n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Sandbox data') ->> 'created')::int, 0);
  end loop;
  perform private.log_event('System', 'Sandbox data loaded', null, null, null,
    jsonb_build_object('domains', 2, 'class_weeks', n_weeks, 'test_instructors', cardinality(v_tests)));
  return jsonb_build_object('class_weeks', n_weeks, 'test_instructors', cardinality(v_tests));
end;
$$;
create or replace function private.queue_instructor_message(
  p_template text,
  p_instructor uuid,
  p_mw uuid,
  p_request uuid,
  p_now timestamptz,
  p_buttons jsonb default '[]',
  p_extra jsonb default '{}',
  p_urgent boolean default false,
  p_key_suffix text default '',
  p_help_request uuid default null,
  p_only_channel text default null
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  d public.domain;
  v_domain uuid;
  v_channels text;
  v_r jsonb;
  v_tv int;
  v_send timestamptz;
  v_test boolean;
  v_prefix text := '';
  v_count int := 0;
  v_n int;
  v_ch text;
  v_key text;
  v_text text;
  v_html text;
  v_btn_html text;
  v_chan text;
begin
  select * into i from public.instructor where id = p_instructor;
  if p_mw is not null then
    select w.domain_id, w.time_version into v_domain, v_tv from public.module_week w where w.id = p_mw;
  end if;
  if p_request is not null then
    select r.time_version into v_tv from public.request r where r.id = p_request;
  end if;
  select * into d from public.domain where id = v_domain;
  -- The instructor's channel in this domain (Release 2: one channel per domain).
  -- An older single channel (from a channel link) is used when no channel is chosen for this domain.
  -- A message without a domain (the contact check) uses the instructor's first channel.
  v_chan := coalesce((select ic.channel_id from public.instructor_channel ic
                       where ic.instructor_id = p_instructor and (ic.domain_id = v_domain or v_domain is null)
                       order by ic.created_at limit 1),
                     i.discord_channel_id);
  v_test := private.is_test_domain(d.id);
  v_channels := 'Both';
  v_r := private.render_instructor(p_template, p_mw, p_instructor, p_extra);
  if v_test then
    v_prefix := '[TEST → would go to ' || i.full_name || '] ';
  end if;
  v_send := private.instructor_send_time(v_domain, p_now, p_urgent, coalesce(private.week_region(p_mw), 'US'));

  select coalesce(string_agg(format('<a href="%s" style="display:inline-block;margin:4px 8px 4px 0;padding:10px 16px;background:#1f6feb;color:#fff;border-radius:6px;text-decoration:none;font-weight:600">%s</a>',
                                    private.html_escape(b ->> 'url'), private.html_escape(b ->> 'label')), ''), '')
    into v_btn_html from jsonb_array_elements(p_buttons) b;

  foreach v_ch in array array['Discord', 'Email'] loop
    continue when p_only_channel is not null and v_ch <> p_only_channel;
    continue when v_ch = 'Discord' and v_channels = 'EmailOnly';
    continue when v_ch = 'Email' and v_channels = 'DiscordOnly';
    continue when v_ch = 'Discord' and not v_test and v_chan is null;
    continue when v_ch = 'Email' and not v_test and coalesce(i.primary_email, '') = '';
    v_key := p_template || ':' || coalesce(p_request::text, coalesce(p_mw::text, '-') || ':' || p_instructor::text)
             || ':' || coalesce(v_tv, 0) || ':' || v_ch || coalesce(nullif(':' || p_key_suffix, ':'), '');
    if v_ch = 'Discord' then
      v_text := v_prefix || 'Hi ' ||
                case when i.discord_user_id is not null and (not v_test or i.is_test) then '<@' || i.discord_user_id || '>'
                     else (v_r ->> 'first_name') end
                || ' 👋 ' || (v_r ->> 'body');
      v_html := null;
    else
      v_text := v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')
                || case when jsonb_array_length(p_buttons) > 0 then E'\n\n' ||
                     (select string_agg((b ->> 'label') || ': ' || (b ->> 'url'), E'\n') from jsonb_array_elements(p_buttons) b) else '' end
                || E'\n\n— SME Scheduling';
      v_html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#1f2328">'
                || replace(private.html_escape(v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')), E'\n', '<br>')
                || case when v_btn_html <> '' then '<p style="margin-top:16px">' || v_btn_html || '</p>' else '' end
                || '<p style="color:#59636e;font-size:13px">— SME Scheduling</p></div>';
    end if;
    insert into public.message (
      domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id, module_week_id,
      request_id, help_request_id, recipient_label, to_address, discord_channel_id, mention_user_ids, subject,
      body_text, body_html, buttons, is_test)
    values (
      v_domain, 'Instructor', p_template, v_ch, v_key,
      case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, p_instructor, p_mw,
      p_request, p_help_request, i.full_name,
      case when v_ch = 'Email' then case when v_test then d.test_email else i.primary_email end end,
      case when v_ch = 'Discord' then case when v_test then d.test_discord_channel_id else v_chan end end,
      case when v_ch = 'Discord' and i.discord_user_id is not null and (not v_test or i.is_test) then array[i.discord_user_id] else '{}' end,
      v_prefix || (v_r ->> 'subject'), v_text, v_html, p_buttons, v_test)
    on conflict (unique_key) where unique_key is not null do nothing;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
  end loop;
  return v_count;
end;
$$;
create or replace function public.next_actions(p_limit int default 20)
returns setof public.action_queue language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  return query
  with c as (select a.id from public.action_queue a where a.status = 'Queued' and left(a.action, 8) <> 'discord_' order by a.created_at limit p_limit for update skip locked)
  update public.action_queue a set status = 'Processing' from c where a.id = c.id returning a.*;
end;
$$;
