-- Release Milestone 4: Activity history and audit trail.
-- Every entry carries who, what, when, the related domain, cohort, module, class week, class and
-- instructor, and a readable name for the thing that changed (kept even if it is deleted later).
-- Undo is offered only where it is safe. Browser errors go to a private log.

alter table public.history_event add column cohort_id uuid;
alter table public.history_event add column entity_label text;
create index history_event_cohort_idx on public.history_event (cohort_id, id desc);
create index history_event_domain_idx on public.history_event (domain_id, id desc);
create index history_event_module_idx on public.history_event (module_id, id desc);
create index history_event_instructor_idx on public.history_event (instructor_id, id desc);
create index history_event_week_idx on public.history_event (module_week_id, id desc);
create index history_event_undo_idx on public.history_event (undo_of) where undo_of is not null;

-- -------------------------------------------------------------------------------------
-- Readable names
-- -------------------------------------------------------------------------------------
-- The name people know a row by: module, instructor, cohort, class, class week, setting.
create or replace function private.row_label(p_table text, p_row jsonb)
returns text language sql stable security definer set search_path = ''
as $$
  select case p_table
    when 'module_week' then private.mw_label((p_row ->> 'id')::uuid)
    when 'class_session' then (p_row ->> 'title') || ' on '
      || private.fmt_pt_range((p_row ->> 'starts_at')::timestamptz, (p_row ->> 'ends_at')::timestamptz)
    when 'setting' then coalesce((select d.label from public.setting_definition d where d.key = p_row ->> 'key'), p_row ->> 'key')
    when 'module_owner' then (select t.name from public.team_member t where t.id = (p_row ->> 'team_member_id')::uuid)
    when 'module_operations' then (select t.name from public.team_member t where t.id = (p_row ->> 'team_member_id')::uuid)
    when 'domain_team' then (select t.name from public.team_member t where t.id = (p_row ->> 'team_member_id')::uuid)
    when 'module_ranking' then (select i.full_name from public.instructor i where i.id = (p_row ->> 'instructor_id')::uuid)
    when 'instructor_email' then p_row ->> 'email'
    when 'instructor_unavailability' then (p_row ->> 'from_date') || ' to ' || (p_row ->> 'to_date')
    when 'request' then (select i.full_name from public.instructor i where i.id = (p_row ->> 'instructor_id')::uuid)
    when 'booking' then (select i.full_name from public.instructor i where i.id = (p_row ->> 'instructor_id')::uuid)
    else coalesce(p_row ->> 'name', p_row ->> 'full_name', p_row ->> 'title', p_row ->> 'label', p_row ->> 'email', p_row ->> 'key')
  end;
$$;

create or replace function private.entity_label(p_table text, p_id uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare v jsonb;
begin
  if p_table is null or p_id is null
     or not exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = p_table) then
    return null;
  end if;
  execute format('select to_jsonb(t) from public.%I t where t.id = $1', p_table) into v using p_id;
  return case when v is null then null else private.row_label(p_table, v) end;
exception when others then
  return null;
end;
$$;

-- -------------------------------------------------------------------------------------
-- log_event: cohort and readable name; direct database changes are "Database admin"
-- -------------------------------------------------------------------------------------
drop function private.log_event(text, text, text, uuid, jsonb, jsonb, text, uuid, uuid, uuid, uuid, uuid, bigint, boolean);
create or replace function private.log_event(
  p_category text,
  p_action text,
  p_entity_table text default null,
  p_entity_id uuid default null,
  p_before jsonb default null,
  p_after jsonb default null,
  p_note text default null,
  p_domain_id uuid default null,
  p_module_id uuid default null,
  p_module_week_id uuid default null,
  p_class_id uuid default null,
  p_instructor_id uuid default null,
  p_undo_of bigint default null,
  p_is_test boolean default false,
  p_cohort_id uuid default null,
  p_entity_label text default null
) returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_kind text := nullif(current_setting('app.actor_kind', true), '');
  v_instr uuid := nullif(current_setting('app.actor_instructor_id', true), '')::uuid;
  v_label text := nullif(current_setting('app.actor_label', true), '');
  v_sim timestamptz := nullif(current_setting('app.sim_now', true), '')::timestamptz;
  v_tm uuid;
  v_id bigint;
  v_mw public.module_week;
begin
  if v_kind is null then
    v_tm := private.current_team_member_id();
    if private.is_team_user() then
      v_kind := 'TeamMember';
      v_label := coalesce(v_label, (select t.name from public.team_member t where t.id = v_tm), private.current_email());
    else
      v_kind := 'System';
      -- A direct database connection (setup scripts, the SQL editor) is named, not hidden as "System".
      v_label := coalesce(v_label,
        case when coalesce((select auth.role()), '') = '' and session_user = 'postgres' then 'Database admin' else 'System' end);
    end if;
  elsif v_kind = 'TeamMember' then
    v_tm := private.current_team_member_id();
  end if;
  if p_module_week_id is not null then
    select * into v_mw from public.module_week where id = p_module_week_id;
  end if;
  insert into public.history_event (
    sim_at, actor_kind, actor_team_member_id, actor_instructor_id, actor_label, category, action,
    entity_table, entity_id, domain_id, module_id, module_week_id, class_id, instructor_id,
    before, after, note, undo_of, is_test, cohort_id, entity_label)
  values (
    v_sim, v_kind, v_tm, v_instr, v_label, p_category, p_action,
    p_entity_table, p_entity_id, coalesce(p_domain_id, v_mw.domain_id), coalesce(p_module_id, v_mw.module_id),
    p_module_week_id, p_class_id, coalesce(p_instructor_id, v_instr), p_before, p_after, p_note, p_undo_of, p_is_test,
    coalesce(p_cohort_id, v_mw.cohort_id), coalesce(p_entity_label, private.entity_label(p_entity_table, p_entity_id)))
  returning id into v_id;
  return v_id;
end;
$$;

-- Setup changes: readable name, cohort, domain (also for rows that only point to a module), and
-- the reason given for a settings override.
create or replace function private.log_setup_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_row jsonb;
  v_ignore text[] := array['updated_at', 'updated_by', 'version', 'verified_at', 'last_response_at',
                           'email_bounced_at', 'discord_failed_at', 'test_clock_at', 'paused_from',
                           'last_sign_in_at', 'auth_user_id', 'discord_prompt_dismissed_at'];
  v_action text;
  k text;
  v_changed boolean := false;
  v_module uuid;
  v_cohort uuid;
  v_domain uuid;
begin
  if current_setting('app.suppress_setup_log', true) = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op = 'INSERT' then
    v_after := to_jsonb(new); v_row := v_after; v_action := tg_table_name || ' added';
  elsif tg_op = 'DELETE' then
    v_before := to_jsonb(old); v_row := v_before; v_action := tg_table_name || ' removed';
  else
    v_before := to_jsonb(old); v_after := to_jsonb(new); v_row := v_after;
    v_action := tg_table_name || ' changed';
    for k in select jsonb_object_keys(v_after) loop
      if not (k = any (v_ignore)) and (v_before -> k) is distinct from (v_after -> k) then
        v_changed := true;
      end if;
    end loop;
    if not v_changed then
      return new;
    end if;
  end if;
  v_module := case when tg_table_name = 'module' then (v_row ->> 'id')::uuid else (v_row ->> 'module_id')::uuid end;
  v_cohort := case when tg_table_name = 'cohort' then (v_row ->> 'id')::uuid else (v_row ->> 'cohort_id')::uuid end;
  v_domain := coalesce(
    case when tg_table_name = 'domain' then (v_row ->> 'id')::uuid else (v_row ->> 'domain_id')::uuid end,
    (select m.domain_id from public.module m where m.id = v_module),
    (select c.domain_id from public.cohort c where c.id = v_cohort),
    (select w.domain_id from public.module_week w where w.id = (v_row ->> 'module_week_id')::uuid));
  perform private.log_event(
    'Setup changes', v_action, tg_table_name::text,
    case when v_row ? 'id' and jsonb_typeof(v_row -> 'id') = 'string' and (v_row ->> 'id') ~ '^[0-9a-f-]{36}$'
         then (v_row ->> 'id')::uuid end,
    v_before, v_after,
    case when tg_table_name = 'setting' then v_row ->> 'reason' end,
    v_domain, v_module, (v_row ->> 'module_week_id')::uuid, null,
    case when tg_table_name = 'instructor' then (v_row ->> 'id')::uuid else (v_row ->> 'instructor_id')::uuid end,
    null, false, v_cohort, private.row_label(tg_table_name, v_row));
  return coalesce(new, old);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Undo: only for edits that are safe to reverse
-- -------------------------------------------------------------------------------------
-- Allowed: a setup change made through a table edit or an instructor order save, not undone yet, not
-- itself an undo. Never for creating or deleting a domain, cohort or module (nor messages, answers or
-- automatic actions, which are not setup changes).
create or replace function private.can_undo(e public.history_event)
returns boolean language sql stable security definer set search_path = ''
as $$
  select e.category = 'Setup changes'
     and e.undo_of is null
     and e.entity_table is not null
     and e.entity_table in ('team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
           'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'setting',
           'holiday', 'cohort', 'module_operations', 'class_type')
     and (e.action = 'Ranking saved' or e.action in (e.entity_table || ' added', e.entity_table || ' changed', e.entity_table || ' removed'))
     and not (e.entity_table in ('domain', 'cohort', 'module') and (e.before is null or e.after is null))
     and not exists (select 1 from public.history_event u where u.undo_of = e.id);
$$;

-- Computed column for the app: GET /history_event?select=*,undoable
create or replace function public.undoable(e public.history_event)
returns boolean language sql stable security definer set search_path = ''
as $$ select private.is_team_user() and private.can_undo(e); $$;
grant execute on function public.undoable(public.history_event) to authenticated;
revoke execute on function public.undoable(public.history_event) from anon, public;

create or replace function private.require_undoable(p_event_id bigint)
returns void language plpgsql stable security definer set search_path = ''
as $$
declare e public.history_event;
begin
  select * into e from public.history_event where id = p_event_id;
  if e.id is null then raise exception 'This entry was not found.' using errcode = '22023'; end if;
  if exists (select 1 from public.history_event u where u.undo_of = e.id) then
    raise exception 'This change was already undone.' using errcode = '22023';
  end if;
  if not private.can_undo(e) then
    raise exception 'This change cannot be undone. Change it directly instead.' using errcode = '22023';
  end if;
end;
$$;

-- -------------------------------------------------------------------------------------
-- Events that were missing or unclear
-- -------------------------------------------------------------------------------------
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

-- Downloads (spreadsheets) are recorded: what, how many rows, which filters.
create or replace function public.log_export(p_what text, p_rows int, p_filters jsonb default '{}', p_domain_id uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  perform private.log_event('Team actions', 'Downloaded ' || p_what, null, null, null,
    jsonb_build_object('rows', p_rows, 'filters', coalesce(p_filters, '{}')), null, p_domain_id);
end;
$$;
grant execute on function public.log_export(text, int, jsonb, uuid) to authenticated;
revoke execute on function public.log_export(text, int, jsonb, uuid) from anon, public;

-- -------------------------------------------------------------------------------------
-- Private log of errors in the app (browser), shown on Connections
-- -------------------------------------------------------------------------------------
create table public.app_error (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  team_member_id uuid references public.team_member (id) on delete set null,
  message text not null,
  detail text,
  page text,
  browser text,
  count int not null default 1,
  last_at timestamptz not null default now()
);
create index app_error_at_idx on public.app_error (last_at desc);
alter table public.app_error enable row level security;
revoke all on public.app_error from anon;
grant all on public.app_error to service_role;
revoke all on public.app_error from authenticated;
grant select on public.app_error to authenticated;
create policy app_error_team_read on public.app_error for select to authenticated using (private.is_team_user());

-- Repeats of the same error from the same person within an hour are counted, not stored again.
create or replace function public.log_app_error(p_message text, p_detail text default null, p_page text default null,
  p_browser text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_me uuid := private.current_team_member_id(); v_id bigint;
begin
  if not private.is_team_user() then return; end if;
  select id into v_id from public.app_error
   where team_member_id is not distinct from v_me and message = left(coalesce(p_message, ''), 500)
     and last_at > now() - interval '1 hour'
   order by id desc limit 1;
  if v_id is not null then
    update public.app_error set count = count + 1, last_at = now() where id = v_id;
  elsif (select count(*) from public.app_error where team_member_id is not distinct from v_me and at > now() - interval '1 hour') < 50 then
    insert into public.app_error (team_member_id, message, detail, page, browser)
    values (v_me, left(coalesce(p_message, 'Unknown error'), 500), left(p_detail, 4000), left(p_page, 500), left(p_browser, 300));
  end if;
end;
$$;
grant execute on function public.log_app_error(text, text, text, text) to authenticated;
revoke execute on function public.log_app_error(text, text, text, text) from anon, public;

-- Undo refuses anything the rule above does not allow.
create or replace function public.undo_history_event(p_event_id bigint)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  e public.history_event;
  v_cur jsonb;
  v_cols text;
  v_ignore text[] := array['id', 'created_at', 'updated_at', 'updated_by', 'version', 'verified_at', 'last_response_at',
                           'email_bounced_at', 'discord_failed_at', 'test_clock_at'];
  v_cmp_before jsonb;
  v_cmp_cur jsonb;
begin
  perform private.require_team();
  perform private.require_undoable(p_event_id);
  select * into e from public.history_event where id = p_event_id;
  if exists (select 1 from public.history_event u where u.undo_of = e.id) then
    raise exception 'This change was already undone.';
  end if;
  if e.entity_table not in ('team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
       'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'setting', 'holiday',
       'cohort', 'module_operations', 'class_type') then
    raise exception 'This kind of change can''t be undone.';
  end if;

  if e.action = 'Ranking saved' then
    select coalesce(jsonb_agg(instructor_id order by rank), '[]') into v_cur from public.module_ranking where module_id = e.entity_id and cohort_id is not distinct from (e.after ->> 'cohort_id')::uuid;
    if v_cur <> (e.after -> 'instructor_ids') then
      raise exception 'The ranking changed again since then, so undo isn''t safe. Edit it directly instead.';
    end if;
    perform public.save_ranking(e.entity_id, array(select (x #>> '{}')::uuid from jsonb_array_elements(e.before -> 'instructor_ids') x), null, (e.after ->> 'cohort_id')::uuid);
  else
    execute format('select to_jsonb(t) from public.%I t where id = $1', e.entity_table) into v_cur using e.entity_id;
    select string_agg(format('%I', c.column_name), ', ') into v_cols
      from information_schema.columns c
     where c.table_schema = 'public' and c.table_name = e.entity_table and c.column_name <> all (v_ignore)
       and c.is_generated = 'NEVER';
    if e.after is not null then
      select jsonb_object_agg(k, v) into v_cmp_before from jsonb_each(e.after) x(k, v) where k <> all (v_ignore);
      select jsonb_object_agg(k, v) into v_cmp_cur from jsonb_each(coalesce(v_cur, '{}')) x(k, v) where k <> all (v_ignore);
      if v_cmp_cur is distinct from v_cmp_before then
        raise exception 'This was changed again since then, so undo isn''t safe. Edit it directly instead.';
      end if;
    end if;
    if e.before is null then                -- undo an insert
      begin
        execute format('delete from public.%I where id = $1', e.entity_table) using e.entity_id;
      exception when foreign_key_violation then
        raise exception 'It''s already in use, so it can''t be removed. Archive or deactivate it instead.';
      end;
    elsif e.after is null then              -- undo a delete
      execute format('insert into public.%I (id, %s) select id, %s from jsonb_populate_record(null::public.%I, $1)',
        e.entity_table, v_cols, v_cols, e.entity_table) using e.before;
    else                                     -- undo an update
      execute format('update public.%I t set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1)) where t.id = $2',
        e.entity_table, v_cols, v_cols, e.entity_table) using e.before, e.entity_id;
    end if;
  end if;
  perform private.log_event('Setup changes', 'Undo: ' || e.action, e.entity_table, e.entity_id, e.after, e.before,
    'Undid change #' || e.id, e.domain_id, e.module_id, null, null, e.instructor_id, e.id);
  return jsonb_build_object('ok', true);
end;
$$;
