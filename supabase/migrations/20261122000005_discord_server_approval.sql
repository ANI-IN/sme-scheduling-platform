-- Release 3, M4: Discord servers approved by an admin (docs/PLAN_RELEASE_3.md, decisions 278 and 288).
--
-- Anyone with the invite link can add the bot to their own server. The server then shows on Settings, Connections
-- as "Waiting for approval", and until an admin approves it the bot does nothing there: no posts, no direct messages
-- for its domains, no reading replies from its channels, no member searches and no channel list (only its name and ID
-- are recorded). An admin approves or refuses each server, chooses which domains may use it, and can remove access at
-- any time (public.set_discord_server_access); each change is logged. Removing access marks the domains that used it
-- "Needs a fix" with one task each; their emails still go out. This replaces the Sandbox "allowed Discord servers"
-- setting: servers on that list that a domain uses are approved here for those domains, every other server waits.
-- Rollback: supabase/rollback/20261122000005_discord_server_approval.sql.

alter table public.discord_server add column access text not null default 'Waiting'
  check (access in ('Waiting', 'Approved', 'Refused', 'Removed'));
alter table public.discord_server add column access_changed_at timestamptz;
alter table public.discord_server add column access_changed_by uuid references public.team_member (id) on delete set null;

create table public.discord_server_domain (
  server_id text not null references public.discord_server (id) on delete cascade,
  domain_id uuid not null references public.domain (id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (server_id, domain_id)
);
alter table public.discord_server_domain enable row level security;
create policy discord_server_domain_team_read on public.discord_server_domain for select to authenticated using (private.is_team_user());
grant select on public.discord_server_domain to authenticated;
grant select, insert, delete on public.discord_server_domain to service_role;

-- A server is usable for a domain (or, with no domain, at all) once an admin approved it.
create or replace function private.server_allowed(p_server_id text, p_domain_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.discord_server s where s.id = p_server_id and s.access = 'Approved')
     and (p_domain_id is null
          or exists (select 1 from public.discord_server_domain x where x.server_id = p_server_id and x.domain_id = p_domain_id));
$$;
grant execute on function private.server_allowed(text, uuid) to authenticated, service_role;

-- Approve (with the domains that may use it), refuse or remove access.
create or replace function public.set_discord_server_access(p_server_id text, p_access text, p_domain_ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  s public.discord_server;
  v_domains uuid[] := case when p_access = 'Approved' then coalesce(p_domain_ids, '{}') else '{}' end;
  d record;
  v_lost int := 0;
begin
  perform private.require_admin();
  if p_access not in ('Approved', 'Refused', 'Removed') then
    raise exception 'Choose Approved, Refused or Removed.' using errcode = '22023';
  end if;
  select * into s from public.discord_server where id = p_server_id for update;
  if s.id is null then raise exception 'The bot is not in that Discord server.' using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_domains) x where not exists (select 1 from public.domain dd where dd.id = x)) then
    raise exception 'One of the chosen domains does not exist.' using errcode = '22023';
  end if;
  update public.discord_server set access = p_access, access_changed_at = now(),
         access_changed_by = private.current_team_member_id()
   where id = s.id;
  delete from public.discord_server_domain where server_id = s.id and not (domain_id = any (v_domains));
  insert into public.discord_server_domain (server_id, domain_id)
  select s.id, x from unnest(v_domains) x on conflict do nothing;
  -- Domains that used this server and may not any more.
  for d in select dd.id, dd.name from public.domain dd
            where dd.discord_server_id = s.id and not (dd.id = any (v_domains)) loop
    v_lost := v_lost + 1;
    update public.domain set discord_status = 'Problem',
           discord_problem = 'An admin removed access to the Discord server ' || s.name || ' for this domain. Choose another server or ask an admin.',
           version = version
     where id = d.id;
    insert into public.attention_item (domain_id, type, severity, title, detail, dedupe_key)
    select d.id, 'Other', 'Urgent', 'Discord server no longer available',
      'An admin removed access to the Discord server ' || s.name || ' for ' || d.name
        || '. Messages to its channels are stopped; emails still go out. Choose another server on Settings, Connections.',
      'discord-access:' || s.id || ':' || d.id
     where not exists (select 1 from public.attention_item a where a.dedupe_key = 'discord-access:' || s.id || ':' || d.id and a.status <> 'Done');
  end loop;
  perform private.log_event('Discord',
    case p_access when 'Approved' then 'Discord server approved' when 'Refused' then 'Discord server refused'
                  else 'Discord server access removed' end,
    'discord_server', null, jsonb_build_object('server', s.name, 'access', s.access),
    jsonb_build_object('server', s.name, 'server_id', s.id, 'access', p_access,
      'domains', (select coalesce(jsonb_agg(dd.name order by dd.name), '[]') from public.domain dd where dd.id = any (v_domains))));
  -- Read the channels of a newly approved server.
  if p_access = 'Approved' then perform private.queue_server_check(s.id); end if;
  return jsonb_build_object('access', p_access, 'domains', cardinality(v_domains), 'domains_that_lost_access', v_lost);
end;
$$;
revoke execute on function public.set_discord_server_access(text, text, uuid[]) from public, anon;
grant execute on function public.set_discord_server_access(text, text, uuid[]) to authenticated, service_role;

-- Today's servers: those on the Sandbox allowed list that a domain uses are approved for those domains.
update public.discord_server s set access = 'Approved', access_changed_at = now()
 where s.id = any (coalesce((select c.sandbox_allowed_discord_servers from public.app_config c where c.id = 1), '{}'::text[]))
   and exists (select 1 from public.domain d where d.discord_server_id = s.id);
insert into public.discord_server_domain (server_id, domain_id)
select d.discord_server_id, d.id from public.domain d join public.discord_server s on s.id = d.discord_server_id
 where s.access = 'Approved'
on conflict do nothing;
do $$
declare s record;
begin
  for s in select id, name from public.discord_server where access = 'Approved' loop
    perform private.log_event('Discord', 'Discord server approved', 'discord_server', null, null,
      jsonb_build_object('server', s.name, 'server_id', s.id, 'access', 'Approved', 'by', 'setup (it was on the Sandbox allowed list)'));
  end loop;
end;
$$;

-- private.message_block_reason: posts and direct messages only through approved servers (was 20261122000004_beta_guard.sql).
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
  if c.environment = 'Production' and c.message_recipients = 'Anyone' and m.audience = 'Instructor' and coalesce(i.is_test, false) then
    return 'Production never messages test instructors.';
  end if;
  if m.channel = 'Discord' and m.discord_channel_id is not null and m.discord_dm_user_id is not null then
    return 'A Discord message goes either to a channel or to one person, not both.';
  end if;
  -- Release 3 beta guard (decision 287): settings checked in every environment, for every recipient and tag.
  if m.channel = 'Email' and coalesce(array_length(c.recipient_email_domains, 1), 0) > 0 then
    v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
    if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.recipient_email_domains) x))) then
      return 'During the beta, email goes only to ' || array_to_string(c.recipient_email_domains, ', ') || ' addresses. '
        || coalesce(nullif(v_domain, ''), 'This address') || ' is not one of them.';
    end if;
  end if;
  if c.message_recipients = 'Test instructors and signed in colleagues' then
    if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false) then
      return 'During the beta, only test instructors are contacted. Mark ' || coalesce(i.full_name, 'this instructor')
        || ' as a test instructor to try this.';
    end if;
    if m.channel = 'Discord' then
      if m.discord_dm_user_id is not null and not private.is_signed_in_colleague_discord(m.discord_dm_user_id) then
        return 'During the beta, direct messages go only to the Discord accounts of signed in colleagues. Test instructors use a colleague''s own account.';
      end if;
      if exists (select 1 from unnest(coalesce(m.mention_user_ids, '{}')) x where not private.is_signed_in_colleague_discord(x)) then
        return 'During the beta, a message may only tag signed in colleagues. It tags a Discord account that is not one.';
      end if;
    end if;
  end if;
  -- Discord servers approved by an admin (decision 288), in every environment.
  if m.channel = 'Discord' and m.discord_channel_id is not null then
    v_server := (select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id);
    if v_server is null then
      return 'The bot only posts in channels it has listed. Press Refresh on Settings, Connections first.';
    end if;
    if not private.server_allowed(v_server, m.domain_id) then
      return 'The bot only posts in Discord servers an admin has approved for this domain.';
    end if;
  elsif m.channel = 'Discord' and m.discord_dm_user_id is not null and m.domain_id is not null
        and (select d.discord_server_id from public.domain d where d.id = m.domain_id) is not null
        and not private.server_allowed((select d.discord_server_id from public.domain d where d.id = m.domain_id), m.domain_id) then
    return 'The bot sends direct messages for this domain only once an admin has approved its Discord server.';
  end if;
  if c.environment = 'Sandbox' then
    if m.channel = 'Email' then
      if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
         and not private.is_test_domain(m.domain_id) then
        return 'Sandbox never contacts real instructors by email, even at an allowed address. Mark them as a test instructor to try this.';
      end if;
      v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
      if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.sandbox_allowed_email_domains) x))) then
        return 'Sandbox only sends email to allowed domains. ' || coalesce(nullif(v_domain, ''), 'This address') || ' is not on the list.';
      end if;
    elsif m.channel = 'Discord' then
      if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
         and not private.is_test_domain(m.domain_id) then
        return 'Sandbox never contacts real instructors on Discord. Mark them as a test instructor to try this.';
      end if;
      -- A post goes to the server of its channel. A direct message is allowed only to a test instructor
      -- or a team member (Sandbox never contacts real instructors).
      if m.discord_dm_user_id is not null and m.discord_channel_id is null then
        if m.audience = 'Instructor' and not coalesce(i.is_test, false) then
          return 'Sandbox only sends direct messages to test instructors.';
        end if;
        -- SEC-5: only to the Discord account of a team member who still has access (test instructors use
        -- the account of the person testing), never to an account a real instructor uses or one the bot
        -- found in another server.
        if exists (select 1 from public.instructor x where x.discord_user_id = m.discord_dm_user_id and not x.is_test)
           or not exists (select 1 from public.team_member t where t.discord_user_id = m.discord_dm_user_id
                           and t.access_removed_at is null) then
          return 'Sandbox only sends direct messages to the Discord accounts of team members. Test instructors use the Discord account of the person testing.';
        end if;
        return null;
      end if;
      -- The channel must be one the bot listed, in an allowed server (no guessing from the domain).
      v_server := (select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id);
      if v_server is null then
        return 'Sandbox only posts to channels the bot has listed. Press Check on Settings, Connections first.';
      end if;
    end if;
  end if;
  return null;
end;
$$;

-- private.queue_server_check: only approved servers are checked (was 20261113000003_core_discord_servers.sql).
create or replace function private.queue_server_check(p_server_id text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.discord_server s where s.id = p_server_id and s.access = 'Approved') then return; end if;
  update public.discord_server set status = 'Checking', problem = null where id = p_server_id;
  insert into public.action_queue (action, payload, requested_by)
  select 'discord_server', jsonb_build_object('server_id', p_server_id), private.current_team_member_id()
   where not exists (select 1 from public.action_queue where action = 'discord_server' and status in ('Queued', 'Processing')
                        and payload ->> 'server_id' = p_server_id);
end;
$$;

-- private.member_servers: username searches only in approved servers (was 20261113000003_core_discord_servers.sql).
create or replace function private.member_servers(p_kind text, p_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with mine as (
    select ch.server_id s, 0 o from public.instructor_channel ic join public.discord_channel ch on ch.id = ic.channel_id
     where p_kind = 'instructor' and ic.instructor_id = p_id
    union all
    select d.discord_server_id s, 1 o from public.domain d
     where d.discord_server_id is not null
       and (case when p_kind = 'instructor' then
              exists (select 1 from public.instructor_channel c where c.instructor_id = p_id and c.domain_id = d.id)
              or exists (select 1 from public.module_ranking r join public.module m on m.id = r.module_id
                          where r.instructor_id = p_id and m.domain_id = d.id)
            else exists (select 1 from public.domain_team t where t.team_member_id = p_id and t.domain_id = d.id) end)
    union all
    select d.discord_server_id, 2 from public.domain d where d.discord_server_id is not null
    union all
    select s.id, 3 from public.discord_server s where s.archived_at is null
  )
  select coalesce(jsonb_agg(x.s order by x.o), '[]') from (select s, min(o) o from mine group by s) x
   where exists (select 1 from public.discord_server ds where ds.id = x.s and ds.access = 'Approved');
$$;

-- public.discord_watchlist: replies read only in approved servers (was 20261112000003_r2_discord_lookup.sql).
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
     and exists (select 1 from public.discord_channel dc join public.discord_server ds on ds.id = dc.server_id
                  where dc.id = ch.channel_id and ds.access = 'Approved')
     and (exists (select 1 from public.request r where r.instructor_id = i.id and r.status in ('Sent', 'Reminded'))
          or exists (select 1 from public.booking b join public.module_week w on w.id = b.module_week_id
                      where b.instructor_id = i.id and b.status = 'Active' and w.first_class_at > now())
          or exists (select 1 from public.help_request h where h.requester_instructor_id = i.id
                      and h.status in ('Open', 'InProgress', 'WaitingOnInstructor')));
$$;

-- public.set_domain_discord_server: only approved servers (was 20261112000003_r2_discord_lookup.sql).
create or replace function public.set_domain_discord_server(p_domain_id uuid, p_server_id text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_server_id is not null and not exists (select 1 from public.discord_server where id = p_server_id) then
    raise exception 'The bot is not in that Discord server. Invite the bot first, then press Refresh.' using errcode = '22023';
  end if;
  if p_server_id is not null and not private.server_allowed(p_server_id, p_domain_id) then
    raise exception 'An admin must approve this Discord server for this domain first (Settings, Connections).' using errcode = '22023';
  end if;
  update public.domain set discord_server_id = p_server_id, version = version where id = p_domain_id;
  perform public.check_discord('server', p_domain_id);
end;
$$;

-- public.set_instructor_channel: only channels in approved servers (was 20261113000003_core_discord_servers.sql).
create or replace function public.set_instructor_channel(p_instructor_id uuid, p_domain_id uuid, p_channel_id text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
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
  if not private.server_allowed(c.server_id, p_domain_id) then
    raise exception 'An admin must approve the Discord server of #% for this domain first (Settings, Connections).', c.name
      using errcode = '22023';
  end if;
  if c.bot_can_post = false then
    raise exception 'The bot cannot post in #%. Give the bot''s role View Channels and Send Messages there, press Check on Connections, then choose it again.', c.name
      using errcode = '22023';
  end if;
  if exists (select 1 from public.instructor_channel x join public.instructor i on i.id = x.instructor_id
              where x.domain_id = p_domain_id and x.channel_id = p_channel_id and x.instructor_id <> p_instructor_id and i.status = 'Active') then
    raise exception '#% is already the channel of %. Each instructor needs their own channel, so nobody else can answer for them.',
      c.name, (select i.full_name from public.instructor_channel x join public.instructor i on i.id = x.instructor_id
                where x.domain_id = p_domain_id and x.channel_id = p_channel_id and x.instructor_id <> p_instructor_id limit 1)
      using errcode = '22023';
  end if;
  insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name)
  values (p_instructor_id, p_domain_id, c.id, c.name)
  on conflict (instructor_id, domain_id) do update set channel_id = excluded.channel_id, channel_name = excluded.channel_name;
  -- A new channel needs a new contact check.
  update public.instructor set verified_at = null, discord_failed_at = null, version = version
   where id = p_instructor_id and verified_at is not null;
end;
$$;
