-- Decision 347: access findings of the independent review of 25 November 2026 (docs/REVIEW_REPORT.md).
--
-- R3: while the beta rule is on, only an admin ticks or unticks Test instructor, changes an instructor's emails or
-- Discord account, or a team member's Discord account (their own included). Every other edit is unchanged, and the
-- extra email typed while adding a new instructor is still saved. A signed in colleague is someone with a real
-- account (auth.users) behind their team row, and an email to an instructor is judged by the address it goes to.
-- R7: deleting a domain, cohort, module or team member needs an admin, never the last admin; no direct deletes of
-- them and no direct domain status changes.
-- R12: Contact instructor belongs to one of the instructor's domains.
-- R31: resetting a setting for every domain needs an admin.
-- R33: the app keeps write access only to the tables it writes directly.

create or replace function private.beta_locked()
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce((select auth.role()), '') = 'authenticated'
     and coalesce((select c.message_recipients = 'Test instructors and signed in colleagues' from public.app_config c where c.id = 1), false)
     and not private.is_admin();
$$;
revoke execute on function private.beta_locked() from public, anon;

create or replace function private.refuse_beta_change()
returns void language plpgsql volatile set search_path = ''
as $$
begin
  raise exception 'During the beta, only an admin can change Test instructor, an instructor''s emails or a Discord account. Ask an admin.'
    using errcode = '42501';
end;
$$;

create or replace function private.instructor_beta_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not private.beta_locked() then return new; end if;
  if tg_op = 'INSERT' then
    if new.is_test or new.discord_username is not null or new.discord_user_id is not null then perform private.refuse_beta_change(); end if;
  elsif new.is_test is distinct from old.is_test or lower(new.primary_email) is distinct from lower(old.primary_email)
        or new.discord_username is distinct from old.discord_username or new.discord_user_id is distinct from old.discord_user_id then
    perform private.refuse_beta_change();
  end if;
  return new;
end;
$$;
-- "zz": after the triggers that clean up a username or an email, so an unchanged value is not seen as a change.
drop trigger if exists instructor_zz_beta_guard on public.instructor;
create trigger instructor_zz_beta_guard before insert or update on public.instructor
  for each row execute function private.instructor_beta_guard();

create or replace function private.instructor_email_beta_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare i public.instructor;
begin
  if not private.beta_locked() then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_op = 'DELETE' then
    -- Deleting the instructor takes their emails with them (that delete has its own rules).
    if exists (select 1 from public.instructor x where x.id = old.instructor_id) then perform private.refuse_beta_change(); end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then
    if lower(new.email) is distinct from lower(old.email) or new.instructor_id is distinct from old.instructor_id then
      perform private.refuse_beta_change();
    end if;
    return new;
  end if;
  select * into i from public.instructor where id = new.instructor_id;
  -- The mirror of the instructor's own email, or an extra email typed while this person was adding them.
  if lower(new.email) = lower(i.primary_email)
     or (i.updated_by = private.current_team_member_id() and i.created_at > now() - interval '10 minutes') then
    return new;
  end if;
  perform private.refuse_beta_change();
  return new;
end;
$$;
drop trigger if exists instructor_email_zz_beta_guard on public.instructor_email;
create trigger instructor_email_zz_beta_guard before insert or update or delete on public.instructor_email
  for each row execute function private.instructor_email_beta_guard();

create or replace function private.team_member_beta_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not private.beta_locked() then return new; end if;
  if tg_op = 'INSERT' then
    if new.discord_username is not null or new.discord_user_id is not null then perform private.refuse_beta_change(); end if;
  elsif new.discord_username is distinct from old.discord_username or new.discord_user_id is distinct from old.discord_user_id then
    perform private.refuse_beta_change();
  end if;
  return new;
end;
$$;
drop trigger if exists team_member_zz_beta_guard on public.team_member;
create trigger team_member_zz_beta_guard before insert or update on public.team_member
  for each row execute function private.team_member_beta_guard();

-- Who is a signed in colleague: a team row with a real account of the same address behind it.
create or replace function private.is_beta_email(p_email text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.team_member t join auth.users u on u.id = t.auth_user_id and lower(u.email) = lower(t.email)
                  where lower(t.email) = lower(trim(p_email)) and t.access_removed_at is null)
      or ((select c.beta_list_may_receive from public.app_config c where c.id = 1)
          and exists (select 1 from public.beta_access b where lower(b.email) = lower(trim(p_email))));
$$;
revoke execute on function private.is_beta_email(text) from public, anon;

create or replace function private.is_beta_instructor(p_instructor_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  with e as (
    select lower(i.primary_email) email from public.instructor i where i.id = p_instructor_id
    union select lower(x.email) from public.instructor_email x where x.instructor_id = p_instructor_id)
  select exists (select 1 from e where private.is_beta_email(e.email));
$$;

create or replace function private.is_signed_in_colleague_discord(p_discord_user_id text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.team_member t join auth.users u on u.id = t.auth_user_id and lower(u.email) = lower(t.email)
                  where t.discord_user_id = p_discord_user_id and t.access_removed_at is null);
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

create or replace function public.delete_item(p_kind text, p_id text, p_typed_name text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  p jsonb := public.delete_preview(p_kind, p_id);
  v_name text := p ->> 'name';
  v_before jsonb;
  v_domain uuid; v_module uuid; v_week uuid; v_cohort uuid; v_instr uuid;
  v_reason text;
begin
  if p_kind = 'discord_server' then perform private.require_admin(); end if;
  if p_kind in ('domain', 'cohort', 'module', 'team_member') and not private.is_admin() then
    raise exception 'Only an admin can delete a domain, cohort, module or team member.' using errcode = '42501';
  end if;
  if p ->> 'blocked' is not null then raise exception '%', p ->> 'blocked' using errcode = '42501'; end if;
  if (p ->> 'needs_name')::boolean and lower(trim(coalesce(p_typed_name, ''))) <> lower(trim(v_name)) then
    raise exception 'Type the name exactly as shown to delete it: %', v_name using errcode = '22023';
  end if;
  v_reason := 'Deleted: ' || v_name;
  -- One readable history entry for the whole delete (the rows below would each add their own).
  perform set_config('app.suppress_setup_log', 'on', true);
  if p_kind = 'domain' then
    select to_jsonb(d) into v_before from public.domain d where id = p_id::uuid;
    v_domain := p_id::uuid;
    v_before := v_before || jsonb_build_object(
      'modules', (select coalesce(jsonb_agg(name order by rotation_order), '[]') from public.module where domain_id = v_domain),
      'cohorts', (select coalesce(jsonb_agg(name order by name), '[]') from public.cohort where domain_id = v_domain));
    perform private.purge_domain(v_domain, v_reason);
    v_domain := null;
  elsif p_kind = 'cohort' then
    select to_jsonb(c), c.domain_id into v_before, v_domain from public.cohort c where id = p_id::uuid;
    perform private.purge_cohort(p_id::uuid, v_reason);
  elsif p_kind = 'module' then
    select to_jsonb(m), m.domain_id into v_before, v_domain from public.module m where id = p_id::uuid;
    perform private.purge_module(p_id::uuid, v_reason);
  elsif p_kind = 'class_week' then
    select to_jsonb(w) || jsonb_build_object('module', v_name, 'label', private.mw_label(w.id)), w.domain_id
      into v_before, v_domain from public.module_week w where id = p_id::uuid;
    v_name := v_before ->> 'label';
    perform private.purge_module_week(p_id::uuid, v_reason);
  elsif p_kind = 'instructor' then
    select to_jsonb(i) || jsonb_build_object('emails', (select coalesce(jsonb_agg(email), '[]') from public.instructor_email where instructor_id = i.id))
      into v_before from public.instructor i where id = p_id::uuid;
    perform private.purge_instructor(p_id::uuid, v_reason);
  elsif p_kind = 'team_member' then
    select to_jsonb(t) into v_before from public.team_member t where id = p_id::uuid;
    perform private.purge_team_member(p_id::uuid);
  elsif p_kind = 'discord_server' then
    select to_jsonb(s) into v_before from public.discord_server s where id = p_id;
    perform private.purge_discord_server(p_id);
  end if;
  perform set_config('app.suppress_setup_log', 'off', true);
  perform private.log_event(case when p_kind = 'class_week' then 'Team actions' else 'Setup changes' end,
    private.kind_label(p_kind) || ' deleted: ' || v_name,
    case p_kind when 'class_week' then 'module_week' when 'discord_server' then null else p_kind end,
    case when p_kind = 'discord_server' then null else p_id::uuid end,
    v_before, null, (select string_agg(x, '. ') from jsonb_array_elements_text(p -> 'lines') x),
    case when p_kind = 'domain' then null else v_domain end, null, null, null, null, null, false, null, v_name);
  return jsonb_build_object('deleted', true, 'name', v_name);
end;
$$;

create or replace function public.reset_setting_at(p_scope text, p_scope_id uuid, p_key text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_scope = 'Global' then perform private.require_admin(); end if;  -- Review R31 (decision 347)
  delete from public.setting
   where key = p_key and scope = p_scope
     and coalesce(module_week_id, module_id, cohort_id, domain_id) is not distinct from private.scope_id_of(p_scope, p_scope_id);
end;
$$;

create or replace function public.contact_instructor(p_instructor_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_from text := coalesce((select t.name from public.team_member t where t.id = private.current_team_member_id()), 'SME Scheduling');
  v_n int;
  v_dom uuid;
begin
  perform private.require_team();
  if coalesce(trim(p_text), '') = '' then raise exception 'Write a message first.' using errcode = '22023'; end if;
  if length(p_text) > 2000 then raise exception 'Keep the message under 2,000 characters.' using errcode = '22023'; end if;
  select * into i from public.instructor where id = p_instructor_id;
  if i.id is null then raise exception 'Instructor not found.' using errcode = '22023'; end if;
  if i.status = 'Archived' then raise exception '% is archived, so nothing is sent to them.', i.full_name using errcode = '22023'; end if;
  -- Review R12 (decision 347): the message belongs to one of the instructor's domains, so the Draft rule, pauses,
  -- testing and the Discord server approval of that domain apply. Live first, then Testing, then Paused.
  select x.id into v_dom from public.domain x
   where x.archived_at is null and x.id in (
          select c.domain_id from public.instructor_channel c where c.instructor_id = i.id
          union select m.domain_id from public.module_ranking r join public.module m on m.id = r.module_id where r.instructor_id = i.id
          union select w.domain_id from public.request q join public.module_week w on w.id = q.module_week_id where q.instructor_id = i.id
          union select w.domain_id from public.booking b join public.module_week w on w.id = b.module_week_id where b.instructor_id = i.id)
   -- Then, as before for a message of no domain (decision 339), the domain of their checked channel, else their newest.
   order by case x.status when 'Live' then 0 when 'Test' then 1 when 'Paused' then 2 else 3 end,
            (select max(case when c.ready_at is not null then 1 else 0 end) from public.instructor_channel c
              join public.discord_channel ch on ch.id = c.channel_id
              where c.instructor_id = i.id and c.domain_id = x.id and private.server_allowed(ch.server_id, x.id)) desc nulls last,
            (select max(c.created_at) from public.instructor_channel c join public.discord_channel ch on ch.id = c.channel_id
              where c.instructor_id = i.id and c.domain_id = x.id and private.server_allowed(ch.server_id, x.id)) desc nulls last,
            x.name
   limit 1;
  if v_dom is not null and (select x.status from public.domain x where x.id = v_dom) = 'Draft' then
    raise exception '% is only in draft domains, and draft domains send nothing to instructors. Set one of their domains to Testing or Live first.', i.full_name
      using errcode = '22023';
  end if;
  v_n := private.queue_instructor_message('M23', i.id, null, null, now(), '[]',
    jsonb_build_object('text', trim(p_text), 'from', v_from, 'domain_id', v_dom), false, 'contact:' || gen_random_uuid());
  perform private.log_event('Team actions', 'Message sent to ' || i.full_name, 'instructor', i.id, null,
    jsonb_build_object('text', trim(p_text), 'messages', v_n), null, null, null, null, null, i.id);
  perform private.queue_deliver('contact');
  return jsonb_build_object('ok', true, 'messages', v_n);
end;
$$;

-- R33 and R7: write access only where the app writes directly. Everything else changes through database functions.
-- What was granted before, so the rollback puts back exactly that (live and local differ).
create table private.release_59_grants (kind text not null, name text not null, role text not null, privilege text not null);
insert into private.release_59_grants
select 'table', c.relname, a.grantee::regrole::text, a.privilege_type
  from pg_class c cross join lateral aclexplode(c.relacl) a
 where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p')
   and a.grantee in ('authenticated'::regrole, 'anon'::regrole)
   and a.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')
union all
select 'default', '', a.grantee::regrole::text, a.privilege_type
  from pg_default_acl d cross join lateral aclexplode(d.defaclacl) a
 where d.defaclnamespace = 'public'::regnamespace and d.defaclobjtype = 'r' and d.defaclrole = current_user::regrole
   and a.grantee in ('authenticated'::regrole, 'anon'::regrole)
   and a.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER');

revoke insert, update, delete, truncate, references, trigger on all tables in schema public from authenticated, anon;
alter default privileges in schema public revoke insert, update, delete, truncate, references, trigger on tables from authenticated, anon;
grant insert, update on public.instructor, public.module, public.cohort, public.team_member to authenticated;
grant insert, delete on public.instructor_email, public.instructor_unavailability, public.domain_team, public.class_type,
  public.module_owner, public.module_operations to authenticated;
grant insert, update, delete on public.holiday, public.standard_schedule_class, public.class_pattern_item, public.module_resource to authenticated;
-- A new domain starts in Draft; its status changes only through set_domain_status, which checks it is ready.
grant insert on public.domain to authenticated;
grant update (name, alert_discord_channel_id, version) on public.domain to authenticated;
alter policy domain_team_insert on public.domain with check (private.is_team_user() and status = 'Draft');
