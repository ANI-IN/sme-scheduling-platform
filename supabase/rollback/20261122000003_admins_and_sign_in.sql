-- Rollback for 20261122000003_admins_and_sign_in.sql: removes admins, the beta list and "Who may sign in", and puts
-- back every changed function exactly as it was. Anyone with a company account can sign in again.

-- public.set_app_config, as in 20261112000005_r2_review_fixes.sql.
create or replace function public.set_app_config(p_config jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare c public.app_config;
begin
  perform private.require_team();
  select * into c from public.app_config where id = 1;
  if (p_config ->> 'version')::int is distinct from c.version then
    raise exception 'This changed — reload. Someone else saved the system settings after you opened them.' using errcode = '40001';
  end if;
  if p_config ? 'company_email_domain' and lower(trim(p_config ->> 'company_email_domain')) <> c.company_email_domain then
    raise exception 'The company email domain can only be changed by an admin in the database (see docs/SETUP.md).';
  end if;
  if (p_config ? 'response_base_url' and nullif(trim(p_config ->> 'response_base_url'), '') is distinct from c.response_base_url)
     or (p_config ? 'app_base_url' and nullif(trim(p_config ->> 'app_base_url'), '') is distinct from c.app_base_url) then
    raise exception 'The answer link address and the app address are set when the app is set up (npm run configure, see docs/SETUP_GUIDE.md), so nobody can point instructors somewhere else from the app.'
      using errcode = '42501';
  end if;
  update public.app_config set
    discord_guild_id = nullif(trim(coalesce(p_config ->> 'discord_guild_id', discord_guild_id)), ''),
    response_base_url = nullif(trim(coalesce(p_config ->> 'response_base_url', response_base_url)), ''),
    app_base_url = nullif(trim(coalesce(p_config ->> 'app_base_url', app_base_url)), ''),
    admin_discord_channel_id = nullif(trim(coalesce(p_config ->> 'admin_discord_channel_id', admin_discord_channel_id)), ''),
    scheduling_email = nullif(trim(coalesce(p_config ->> 'scheduling_email', scheduling_email)), ''),
    scheduling_sender_name = coalesce(nullif(trim(p_config ->> 'scheduling_sender_name'), ''), scheduling_sender_name)
  where id = 1;
end;
$$;

-- public.set_kill_switch, as in 20261111000005_release_audit.sql.
create or replace function public.set_kill_switch(p_outreach_enabled boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  update public.system_state set outreach_enabled = p_outreach_enabled, kill_switch_changed_at = now(),
         kill_switch_changed_by = private.current_team_member_id()
   where id = 1;
  perform private.log_event('System', case when p_outreach_enabled then 'Messages to instructors turned back on'
                                           else 'All messages to instructors paused' end);
  if p_outreach_enabled then perform private.queue_deliver('messages turned back on'); end if;
end;
$$;

-- public.send_test_alert, as in 20261110000005_actions.sql.
create or replace function public.send_test_alert(p_team_member_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  perform private.queue_team_message('T0', null, 'person', p_team_member_id, '{}', 'Test alert from SME Scheduling',
    'This is a test alert from SME Scheduling. If you can read this, your alerts are set up correctly.',
    'T0:' || p_team_member_id || ':' || extract(epoch from clock_timestamp())::bigint, now());
  perform private.queue_deliver('test alert');
  perform private.log_event('Team actions', 'Test alert sent to ' || private.team_names(array[p_team_member_id]));
end;
$$;

-- public.check_discord_server, as in 20261113000003_core_discord_servers.sql.
create or replace function public.check_discord_server(p_server_id text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if not exists (select 1 from public.discord_server where id = p_server_id) then
    raise exception 'That server is not in the list. Press Refresh servers first.' using errcode = '22023';
  end if;
  perform private.queue_server_check(p_server_id);
  perform private.log_event('Discord', 'Discord server check asked for', null, null, null,
    jsonb_build_object('server_id', p_server_id), null, null, null, null, null, null, null, false, null,
    (select name from public.discord_server where id = p_server_id));
end;
$$;

-- public.reset_sandbox_data, as in 20261113000001_core_empty_start.sql.
create or replace function public.reset_sandbox_data(p_confirm text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_env text := (select environment from public.app_config where id = 1);
begin
  perform private.require_team();
  if v_env = 'Production' then
    raise exception 'Sandbox data can never be reset in Production.' using errcode = '42501';
  end if;
  -- SEC-6: only a database that was set up as Sandbox (or local development) on purpose.
  if (select environment_set_at from public.app_config where id = 1) is null then
    raise exception 'This database was never set up with npm run configure, so its data cannot be reset.' using errcode = '42501';
  end if;
  perform set_config('app.reset_sandbox', 'on', true);
  if p_confirm is distinct from 'RESET' then
    raise exception 'Type RESET to confirm.' using errcode = '22023';
  end if;
  perform private.log_event('System', 'Sandbox data reset started');
  -- Run any checks still waiting in this transaction (instructor order) before clearing tables.
  set constraints all immediate;
  truncate table public.message, public.request, public.response_link, public.booking_slot, public.booking,
    public.checklist_item, public.help_request, public.reminder, public.attention_item, public.manual_queue_item,
    public.class_session, public.module_week, public.module_operations, public.module_ranking,
    public.module_owner, public.module_resource, public.class_pattern_item, public.module, public.cohort,
    public.class_type, public.message_template, public.domain_team, public.instructor_unavailability,
    public.instructor_email, public.instructor_channel, public.instructor, public.action_queue, public.app_error,
    public.holiday, public.domain, public.discord_cursor
    restart identity cascade;
  -- Settings for one domain, cohort, module or class week went with them; settings for every domain stay.
  delete from public.setting where scope <> 'Global';
  -- Real people keep their sign in and profile; people nobody signs in as (placeholders) go.
  delete from public.team_member where is_placeholder and auth_user_id is null;
  update public.system_state set outreach_enabled = true where id = 1;
  set constraints all deferred;
  perform private.log_event('System', 'Sandbox data reset', null, null, null,
    jsonb_build_object('emptied', true));
  return jsonb_build_object('emptied', true);
end;
$$;

-- public.check_discord, as in 20261113000003_core_discord_servers.sql.
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

-- public.set_settings_at, as in 20261111000006_release_pages.sql.
create or replace function public.set_settings_at(p_scope text, p_scope_id uuid, p_values jsonb, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare k text; v jsonb;
begin
  perform private.require_team();
  perform set_config('app.settings_batch', 'on', true);
  for k, v in select * from jsonb_each(p_values) loop
    if v = 'null'::jsonb then
      perform public.reset_setting_at(p_scope, p_scope_id, k);
    else
      perform public.set_setting_at(p_scope, p_scope_id, k, v, p_reason);
    end if;
  end loop;
  perform set_config('app.settings_batch', 'off', true);
  perform private.check_setting_rules(case when p_scope = 'Global' then null else p_scope_id end);
end;
$$;

-- public.set_archived, as in 20261113000002_core_archive_delete.sql.
create or replace function public.set_archived(p_kind text, p_id text, p_archived boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_name text; v_paused int := 0;
begin
  perform private.require_team();
  if p_kind = 'domain' then
    update public.domain set archived_at = case when p_archived then coalesce(archived_at, now()) end
     where id = p_id::uuid returning name into v_name;
  elsif p_kind = 'cohort' then
    update public.cohort set archived_at = case when p_archived then coalesce(archived_at, now()) end
     where id = p_id::uuid returning name into v_name;
  elsif p_kind = 'module' then
    update public.module set status = case when p_archived then 'Archived'
                                           when status = 'Archived' then 'Active' else status end
     where id = p_id::uuid returning name into v_name;
  elsif p_kind = 'discord_server' then
    update public.discord_server set archived_at = case when p_archived then coalesce(archived_at, now()) end
     where id = p_id returning name into v_name;
  else
    raise exception 'Unknown kind of item: %.', p_kind using errcode = '22023';
  end if;
  if v_name is null then raise exception 'This item no longer exists.' using errcode = '22023'; end if;
  -- A module's or cohort's class weeks stop (and start again) with it.
  if p_kind in ('cohort', 'module') then
    if p_archived then
      update public.module_week set paused = true, archive_paused = true
       where (case when p_kind = 'cohort' then cohort_id else module_id end) = p_id::uuid
         and not paused and status not in ('Cancelled', 'Completed');
      get diagnostics v_paused = row_count;
    else
      update public.module_week set paused = false, archive_paused = false
       where (case when p_kind = 'cohort' then cohort_id else module_id end) = p_id::uuid and archive_paused;
      get diagnostics v_paused = row_count;
    end if;
  end if;
  perform private.log_event('Setup changes',
    private.kind_label(p_kind) || case when p_archived then ' archived: ' else ' restored: ' end || v_name,
    case when p_kind = 'discord_server' then null else p_kind end,
    case when p_kind = 'discord_server' then null else p_id::uuid end,
    null, jsonb_build_object('archived', p_archived, 'class_weeks', v_paused), null,
    case p_kind when 'domain' then p_id::uuid
                when 'cohort' then (select domain_id from public.cohort where id = p_id::uuid)
                when 'module' then (select domain_id from public.module where id = p_id::uuid) end,
    case when p_kind = 'module' then p_id::uuid end, null, null, null, null, false,
    case when p_kind = 'cohort' then p_id::uuid end, v_name);
  return jsonb_build_object('name', v_name, 'class_weeks', v_paused);
end;
$$;

-- public.delete_item, as in 20261113000002_core_archive_delete.sql.
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

-- public.set_member_access, as in 20261112000005_r2_review_fixes.sql.
create or replace function public.set_member_access(p_team_member_id uuid, p_has_access boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare t public.team_member; v_me uuid := private.current_team_member_id();
begin
  perform private.require_team();
  select * into t from public.team_member where id = p_team_member_id for update;
  if t.id is null then raise exception 'Team member not found.' using errcode = '22023'; end if;
  if not p_has_access and t.id = v_me then
    raise exception 'You cannot remove your own access.' using errcode = '22023';
  end if;
  if p_has_access = (t.access_removed_at is null) then return; end if;
  perform set_config('app.suppress_setup_log', 'on', true);
  update public.team_member
     set access_removed_at = case when p_has_access then null else now() end,
         access_removed_by = case when p_has_access then null else v_me end,
         active = p_has_access,
         version = version
   where id = t.id;
  perform set_config('app.suppress_setup_log', 'off', true);
  -- Removing access also signs the person out everywhere (their refresh tokens go with the sessions).
  if not p_has_access and t.auth_user_id is not null then
    begin
      delete from auth.sessions where user_id = t.auth_user_id;
    exception when others then
      perform private.log_event('System', 'Could not end the sessions of ' || t.name, 'team_member', t.id, null, null, sqlerrm);
    end;
  end if;
  perform private.log_event('Setup changes', case when p_has_access then 'Access given back' else 'Access removed' end,
    'team_member', t.id, jsonb_build_object('name', t.name, 'has_access', not p_has_access),
    jsonb_build_object('name', t.name, 'has_access', p_has_access), nullif(trim(coalesce(p_reason, '')), ''));
end;
$$;

-- private.sign_in_problem, as in 20261112000005_r2_review_fixes.sql.
create or replace function private.sign_in_problem(p_email text, p_provider text, p_hd text)
returns text language sql stable security definer set search_path = ''
as $$
  select case
    when coalesce(c.company_email_domain, '') = '' then
      'Sign in is not set up yet. Ask the admin to set the company email domain.'
    when lower(split_part(coalesce(p_email, ''), '@', 2)) <> lower(c.company_email_domain) then
      'Only company Google accounts can use SME Scheduling.'
    when c.environment <> 'Development' and coalesce(p_provider, '') <> 'google' then
      'Please sign in with your company Google account.'
    when c.environment <> 'Development' and lower(coalesce(p_hd, '')) <> lower(c.company_email_domain) then
      'Only company Google accounts can use SME Scheduling.'
    when exists (select 1 from public.team_member t where t.access_removed_at is not null
                   and (lower(t.email) = lower(p_email) or t.auth_user_id = (select auth.uid()))) then
      'Your access to SME Scheduling was removed. Ask your team lead if you think this is a mistake.'
  end
  from public.app_config c where c.id = 1;
$$;

drop function if exists public.set_sign_in_mode(text);
drop function if exists public.beta_list_remove(text);
drop function if exists public.beta_list_add(text, text);
drop function if exists public.set_admin(uuid, boolean);
drop policy if exists beta_access_admin_read on public.beta_access;
drop function if exists private.require_admin();
drop function if exists private.is_admin();
drop table if exists public.beta_access;
alter table public.app_config drop column if exists sign_in_mode;
alter table public.team_member drop column if exists is_admin;
