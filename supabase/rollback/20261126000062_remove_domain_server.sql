-- Rollback of 20261126000062_remove_domain_server.sql. Deletes only the note of which domains had their server removed; domains keep whatever
-- server they have then, and history stays.
drop trigger if exists domain_server_chosen on public.domain;
drop function if exists private.domain_server_chosen();
drop function if exists public.remove_domain_server(uuid);
drop function if exists public.remove_archived_domain_servers(uuid[]);
drop function if exists private.detach_domain_server(uuid, boolean);

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
  -- Decision 333: nothing goes to an instructor for a Draft domain, even a message queued before it went back to Draft.
  if m.audience = 'Instructor' and m.domain_id is not null
     and (select d.status from public.domain d where d.id = m.domain_id) = 'Draft' then
    return 'Not sent: ' || (select d.name from public.domain d where d.id = m.domain_id)
      || ' is a draft domain, and draft domains send nothing to instructors. Set it to Testing or Live first.';
  end if;
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
      return 'Not sent: during the beta, email goes only to ' || array_to_string(c.recipient_email_domains, ', ') || ' addresses. '
        || coalesce(nullif(v_domain, ''), 'This address') || ' is not one of them. Use an address there, or change Settings, Admin.';
    end if;
  end if;
  if c.message_recipients = 'Test instructors and signed in colleagues' then
    -- Owner, 23 November 2026: also anyone who is a signed in colleague or, while the setting is on, on the beta list.
    -- Review R3 (decision 347): for email the address the message goes to decides, not the instructor's other emails.
    if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
       and not (case when m.channel = 'Email' then private.is_beta_email(m.to_address) else private.is_beta_instructor(i.id) end) then
      return 'Not sent: during the beta, messages go only to test instructors, signed in colleagues and people on the beta list. '
        || 'Ask an admin to add ' || coalesce(i.full_name, 'this instructor') || '''s email to the beta list on Settings, Admin, then press Send again.';
    end if;
    if m.channel = 'Discord' then
      if m.discord_dm_user_id is not null and not private.is_beta_discord(m.discord_dm_user_id, i.id) then
        return 'Not sent: during the beta, Discord direct messages go only to colleagues who have signed in or are on the beta list. '
          || 'Ask them to sign in once, or add their email to the beta list on Settings, Admin, then press Send again.';
      end if;
      if exists (select 1 from unnest(coalesce(m.mention_user_ids, '{}')) x where not private.is_beta_discord(x, i.id)) then
        return 'Not sent: during the beta, a message may only tag colleagues who have signed in or are on the beta list. '
          || 'Ask them to sign in once, or add their email to the beta list on Settings, Admin, then press Send again.';
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

create or replace function public.delete_preview(p_kind text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_name text; v_lines jsonb := '[]'; v_e jsonb; v_weeks uuid[]; v_block text; v_extra jsonb := '[]';
  v_info jsonb := '[]'; v_needs boolean;
begin
  perform private.require_team();
  if p_kind = 'domain' then
    select name into v_name from public.domain where id = p_id::uuid;
    v_weeks := array(select id from public.module_week where domain_id = p_id::uuid);
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.module where domain_id = p_id::uuid) || ' modules, with their class times, instructor order, owners and resources' x
       where exists (select 1 from public.module where domain_id = p_id::uuid)
      union all
      select (select count(*) from public.cohort where domain_id = p_id::uuid) || ' cohorts'
       where exists (select 1 from public.cohort where domain_id = p_id::uuid)
      union all
      select (select count(*) from public.instructor_channel where domain_id = p_id::uuid) || ' instructor channels for this domain'
       where exists (select 1 from public.instructor_channel where domain_id = p_id::uuid)
      union all
      select (select count(*) from public.holiday where domain_id = p_id::uuid) || ' holidays'
       where exists (select 1 from public.holiday where domain_id = p_id::uuid)
      union all
      select (select count(*) from public.domain_team where domain_id = p_id::uuid) || ' team roles'
       where exists (select 1 from public.domain_team where domain_id = p_id::uuid)) q;
  elsif p_kind = 'cohort' then
    select name into v_name from public.cohort where id = p_id::uuid;
    v_weeks := array(select id from public.module_week where cohort_id = p_id::uuid);
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.class_pattern_item where cohort_id = p_id::uuid) || ' class times for this cohort' x
       where exists (select 1 from public.class_pattern_item where cohort_id = p_id::uuid)
      union all
      select 'Its own instructor order for ' || (select count(distinct module_id) from public.module_ranking where cohort_id = p_id::uuid) || ' modules'
       where exists (select 1 from public.module_ranking where cohort_id = p_id::uuid)) q;
  elsif p_kind = 'module' then
    select name into v_name from public.module where id = p_id::uuid;
    v_weeks := array(select id from public.module_week where module_id = p_id::uuid);
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.class_pattern_item where module_id = p_id::uuid) || ' class times' x
       where exists (select 1 from public.class_pattern_item where module_id = p_id::uuid)
      union all
      select (select count(*) from public.module_ranking where module_id = p_id::uuid) || ' places in its instructor order'
       where exists (select 1 from public.module_ranking where module_id = p_id::uuid)) q;
  elsif p_kind = 'class_week' then
    select m.name into v_name from public.module_week w join public.module m on m.id = w.module_id where w.id = p_id::uuid;
    v_weeks := array[p_id::uuid];
  elsif p_kind = 'instructor' then
    select full_name into v_name from public.instructor where id = p_id::uuid;
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.booking b join public.module_week w on w.id = b.module_week_id
               where b.instructor_id = p_id::uuid and b.status = 'Active'
                 and coalesce(w.last_class_end_at, w.first_class_at, 'infinity') > now())
             || ' confirmed class weeks still to come are released: they are told, and the next instructor is asked' x
       where exists (select 1 from public.booking b join public.module_week w on w.id = b.module_week_id
                      where b.instructor_id = p_id::uuid and b.status = 'Active'
                        and coalesce(w.last_class_end_at, w.first_class_at, 'infinity') > now())
      union all
      select (select count(*) from public.request where instructor_id = p_id::uuid and kind = 'Outreach'
               and status in ('Queued', 'Sent', 'Reminded'))
             || ' open requests are withdrawn: they are told, and the next instructor is asked'
       where exists (select 1 from public.request where instructor_id = p_id::uuid and kind = 'Outreach'
                      and status in ('Queued', 'Sent', 'Reminded'))
      union all
      select 'Removed from ' || (select count(*) from public.module_ranking where instructor_id = p_id::uuid)
             || ' instructor orders (the people after them move up)'
       where exists (select 1 from public.module_ranking where instructor_id = p_id::uuid)
      union all
      select (select count(*) from public.booking where instructor_id = p_id::uuid and status <> 'Active')
             || ' past or released bookings are removed from the records (Activity history keeps them)'
       where exists (select 1 from public.booking where instructor_id = p_id::uuid and status <> 'Active')) q;
  elsif p_kind = 'team_member' then
    select name, case
      when access_removed_at is not null then 'Their access was removed, so they stay on the Team page and cannot sign in again with this address. Give their access back first.'
      when auth_user_id is not null and auth_user_id = auth.uid() then 'You cannot delete yourself.'
    end into v_name, v_block from public.team_member where id = p_id::uuid;
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.module_owner where team_member_id = p_id::uuid)
             + (select count(*) from public.module_operations where team_member_id = p_id::uuid)
             + (select count(*) from public.domain_team where team_member_id = p_id::uuid)
             || ' roles on domains and modules are removed' x
       where exists (select 1 from public.module_owner where team_member_id = p_id::uuid)
          or exists (select 1 from public.module_operations where team_member_id = p_id::uuid)
          or exists (select 1 from public.domain_team where team_member_id = p_id::uuid)) q;
    if exists (select 1 from public.team_member where id = p_id::uuid and auth_user_id is not null) then
      v_info := jsonb_build_array('They can sign in again with a company account, which adds them back. To keep them out, use Remove access instead.');
    end if;
  elsif p_kind = 'discord_server' then
    select name into v_name from public.discord_server where id = p_id;
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.domain where discord_server_id = p_id) || ' domains no longer have a Discord server chosen' x
       where exists (select 1 from public.domain where discord_server_id = p_id)
      union all
      select (select count(*) from public.instructor_channel ic join public.discord_channel ch on ch.id = ic.channel_id
               where ch.server_id = p_id) || ' instructor channels in it are removed (those instructors get direct messages and email instead)'
       where exists (select 1 from public.instructor_channel ic join public.discord_channel ch on ch.id = ic.channel_id
                      where ch.server_id = p_id)) q;
    v_info := jsonb_build_array('The bot stays in the server. It comes back after Refresh servers unless you remove the bot in Discord.');
  else
    raise exception 'Unknown kind of item: %.', p_kind using errcode = '22023';
  end if;
  if v_name is null then raise exception 'This item no longer exists.' using errcode = '22023'; end if;
  -- Review R7 (decision 347): whole domains, cohorts, modules and team members are deleted by an admin only, and
  -- never the last admin.
  if p_kind in ('domain', 'cohort', 'module', 'team_member') and not private.is_admin() then
    v_block := 'Only an admin can delete a domain, cohort, module or team member.';
  elsif p_kind = 'team_member' and v_block is null
        and exists (select 1 from public.team_member t where t.id = p_id::uuid and t.is_admin and t.access_removed_at is null)
        and not exists (select 1 from public.team_member t where t.id <> p_id::uuid and t.is_admin and t.access_removed_at is null) then
    v_block := 'This is the only admin. Make someone else an admin first.';
  end if;
  if v_weeks is not null and cardinality(v_weeks) > 0 then
    v_e := private.week_effects(v_weeks);
    v_lines := private.effect_lines(v_e);
  end if;
  v_lines := v_extra || v_lines;
  -- Typing the name is asked when other data goes with the item (decision 255). For one class week: when
  -- someone is confirmed for it or being asked.
  v_needs := case when p_kind = 'class_week'
                  then coalesce((v_e ->> 'confirmed')::int, 0) + coalesce((v_e ->> 'asking')::int, 0) > 0
                  else jsonb_array_length(v_lines) > 0 end;
  return jsonb_build_object('name', v_name, 'lines', v_lines || v_info, 'needs_name', v_needs, 'blocked', v_block);
end;
$$;

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
  cc public.channel_check;
  ci public.instructor;
  v_problems text[] := '{}';
  v_missing text[] := '{}';
  v_ch text;
  v_bot bigint;
  v_mem bigint;
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
  elsif a.action = 'discord_channel' then
    -- Decision 330: the bot may post (View Channels, Send Messages, Embed Links, Read Message History) and the
    -- instructor is in the server and sees the channel. Only then is it saved as their channel, with one welcome.
    select * into cc from public.channel_check where id = (a.payload ->> 'check_id')::uuid;
    if cc.id is null or cc.status <> 'Checking' then
      v_out := jsonb_build_object('ok', true, 'stale', true);
    else
      select * into ci from public.instructor where id = cc.instructor_id;
      v_ch := '#' || coalesce(p_result #>> '{channel,body,name}', cc.channel_name, 'the channel');
      v_server_name := coalesce((select s2.name from public.discord_server s2 where s2.id = a.payload ->> 'server_id'), 'the server');
      if coalesce((p_result #>> '{channel,status}')::int, 0) <> 200 then
        v_problems := v_problems || ('The bot cannot see ' || v_ch || '. In Discord, give the bot''s role View Channels in '
          || v_ch || ', then choose the channel again.');
      elsif coalesce((p_result #>> '{roles,status}')::int, 0) <> 200 or coalesce((p_result #>> '{bot,status}')::int, 0) <> 200 then
        v_problems := v_problems || ('The bot could not read its own permissions in ' || v_server_name
          || '. Check that the bot is still in the server, then choose the channel again.');
      else
        v_bot := private.discord_perms(p_result #> '{channel,body}', a.payload ->> 'server_id', p_result #> '{roles,body}',
                                       p_result #> '{bot,body,roles}', p_result #>> '{bot,body,user,id}');
        v_missing := array(select x.label from (values (1024::bigint, 'View Channels', 1), (2048::bigint, 'Send Messages', 2),
                                                       (16384::bigint, 'Embed Links', 3), (65536::bigint, 'Read Message History', 4)) x(bit, label, n)
                             where v_bot & x.bit = 0 order by x.n);
        if cardinality(v_missing) > 0 then
          v_problems := v_problems || ('Let the bot post in ' || v_ch || ': give the bot''s role '
            || array_to_string(v_missing, ', ') || ' there, then choose the channel again.');
        end if;
      end if;
      if coalesce((p_result #>> '{channel,status}')::int, 0) = 200 and coalesce((p_result #>> '{roles,status}')::int, 0) = 200 then
        if coalesce((p_result #>> '{member,status}')::int, 0) = 404 then
          v_problems := v_problems || (ci.full_name || ' is not a member of ' || v_server_name
            || '. Invite them to the server, then choose the channel again.');
        elsif coalesce((p_result #>> '{member,status}')::int, 0) <> 200 then
          v_problems := v_problems || ('The bot could not look up ' || ci.full_name || ' in ' || v_server_name
            || '. Choose the channel again in a minute.');
        else
          v_mem := private.discord_perms(p_result #> '{channel,body}', a.payload ->> 'server_id', p_result #> '{roles,body}',
                                         p_result #> '{member,body,roles}', a.payload ->> 'user_id');
          if v_mem & 1024 = 0 then
            v_problems := v_problems || ('Give ' || ci.full_name || ' access to ' || v_ch || ' (View Channels), then choose the channel again.');
          elsif v_mem & 65536 = 0 then
            v_problems := v_problems || ('Let ' || ci.full_name || ' read the message history of ' || v_ch
              || ' (Read Message History), so they can see our requests, then choose the channel again.');
          end if;
        end if;
      end if;
      if cardinality(v_problems) = 0 then
        insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name, ready_at)
        values (cc.instructor_id, cc.domain_id, cc.channel_id, coalesce(p_result #>> '{channel,body,name}', cc.channel_name), now())
        on conflict (instructor_id, domain_id) do update
          set channel_id = excluded.channel_id, channel_name = excluded.channel_name, ready_at = excluded.ready_at;
        update public.discord_channel set bot_can_post = true, refreshed_at = now() where id = cc.channel_id;
        update public.channel_check set status = 'Ready', problems = '{}', checked_at = now() where id = cc.id;
        perform private.log_event('Discord', 'Discord channel ready for ' || ci.full_name, 'instructor', ci.id, null,
          jsonb_build_object('channel', v_ch), v_ch || ' in ' || v_server_name || ': the bot can post and they can see it.',
          cc.domain_id, null, null, null, ci.id);
        -- One welcome per instructor and domain, tagging them in the channel.
        perform private.send_welcome(cc.instructor_id, cc.domain_id, 'Discord');
        v_out := jsonb_build_object('ok', true, 'status', 'Ready');
      else
        update public.channel_check set status = 'Problem', problems = v_problems, checked_at = now() where id = cc.id;
        perform private.log_event('Discord', 'Discord channel not saved for ' || ci.full_name, 'instructor', ci.id, null,
          jsonb_build_object('channel', v_ch), array_to_string(v_problems, ' '), cc.domain_id, null, null, null, ci.id);
        v_out := jsonb_build_object('ok', false, 'status', 'Problem', 'problem', array_to_string(v_problems, ' '));
      end if;
    end if;
  end if;

  update public.action_queue set status = case when coalesce((v_out ->> 'ok')::boolean, false) then 'Done' else 'Failed' end,
         result = v_out, error = v_out ->> 'problem', processed_at = now()
   where id = p_action_id;
  return v_out;
end;
$$;

alter table public.domain drop column if exists discord_removed_at;
