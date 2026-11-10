-- Release Milestone 2, part 2: settings layers, routing by assignment, cohort aware instructor
-- order, and the engine reading settings per class week. Generated from the previous definitions
-- with targeted edits; see docs/RELEASE_PLAN.md section 2.

-- -------------------------------------------------------------------------------------
-- Settings: Global, Domain, Cohort, Module, single class week (most specific wins)
-- -------------------------------------------------------------------------------------
-- The layers that apply to an id. Ids are unique across tables, so one function serves a class
-- week, a module, a cohort or a domain id.
create or replace function private.setting_chain(p_id uuid)
returns table (scope text, scope_id uuid, ord int)
language sql stable security definer set search_path = ''
as $$
  with w as (select id, module_id, cohort_id, domain_id from public.module_week where id = p_id),
       m as (select id, domain_id from public.module where id = p_id),
       c as (select id, domain_id from public.cohort where id = p_id)
  select 'ModuleWeek', w.id, 1 from w
  union all select 'Module', w.module_id, 2 from w
  union all select 'Cohort', w.cohort_id, 3 from w
  union all select 'Domain', w.domain_id, 4 from w
  union all select 'Module', m.id, 2 from m
  union all select 'Domain', m.domain_id, 4 from m
  union all select 'Cohort', c.id, 3 from c
  union all select 'Domain', c.domain_id, 4 from c
  union all select 'Domain', p_id, 4
   where p_id is not null and not exists (select 1 from w) and not exists (select 1 from m) and not exists (select 1 from c);
$$;

create or replace function private.setting_with_source(p_id uuid, p_key text, out value jsonb, out source text, out source_id uuid)
language sql stable security definer set search_path = ''
as $$
  select coalesce(x.value, g.value, d.default_value),
         coalesce(x.scope, case when g.value is not null then 'Global' else 'Default' end),
         x.scope_id
    from public.setting_definition d
    left join lateral (
      select s.value, ch.scope, ch.scope_id
        from private.setting_chain(p_id) ch
        join public.setting s on s.key = p_key and s.scope = ch.scope
                             and coalesce(s.module_week_id, s.module_id, s.cohort_id, s.domain_id) = ch.scope_id
       order by ch.ord limit 1) x on true
    left join public.setting g on g.key = p_key and g.scope = 'Global'
   where d.key = p_key;
$$;

-- Effective value for a class week, module, cohort or domain id (null = global).
create or replace function private.get_setting(p_domain uuid, p_key text)
returns jsonb
language sql stable security definer set search_path = ''
as $$ select (private.setting_with_source(p_domain, p_key)).value; $$;

create or replace function private.scope_id_of(p_scope text, p_id uuid)
returns uuid language sql immutable set search_path = ''
as $$ select case when p_scope = 'Global' then null else p_id end; $$;

-- Save one value at one layer. A reason is kept for overrides below the domain.
create or replace function public.set_setting_at(p_scope text, p_scope_id uuid, p_key text, p_value jsonb, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_scope not in ('Global', 'Domain', 'Cohort', 'Module', 'ModuleWeek') then
    raise exception 'Unknown settings level.' using errcode = '22023';
  end if;
  insert into public.setting (scope, domain_id, cohort_id, module_id, module_week_id, key, value, reason)
  values (p_scope,
          case when p_scope = 'Domain' then p_scope_id end,
          case when p_scope = 'Cohort' then p_scope_id end,
          case when p_scope = 'Module' then p_scope_id end,
          case when p_scope = 'ModuleWeek' then p_scope_id end,
          p_key, p_value, nullif(trim(coalesce(p_reason, '')), ''))
  on conflict (key, scope, coalesce(module_week_id, module_id, cohort_id, domain_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set value = excluded.value, reason = excluded.reason;
end;
$$;

create or replace function public.reset_setting_at(p_scope text, p_scope_id uuid, p_key text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  delete from public.setting
   where key = p_key and scope = p_scope
     and coalesce(module_week_id, module_id, cohort_id, domain_id) is not distinct from private.scope_id_of(p_scope, p_scope_id);
end;
$$;

create or replace function public.set_setting(p_domain_id uuid, p_key text, p_value jsonb)
returns void language sql security definer set search_path = ''
as $$ select public.set_setting_at(case when p_domain_id is null then 'Global' else 'Domain' end, p_domain_id, p_key, p_value); $$;

create or replace function public.reset_setting(p_domain_id uuid, p_key text)
returns void language sql security definer set search_path = ''
as $$ select public.reset_setting_at(case when p_domain_id is null then 'Global' else 'Domain' end, p_domain_id, p_key); $$;

-- Every setting for one layer (Domain, Cohort, Module or ModuleWeek id), with where each value
-- comes from: "Default", "Global", "Domain", "Cohort", "Module" or "ModuleWeek".
create or replace function public.effective_settings_for(p_scope text, p_scope_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', d.key, 'group', d.group_name, 'label', d.label, 'type', d.value_type,
           'value', e.value, 'source', e.source, 'source_id', e.source_id,
           'default', d.default_value, 'min', d.min_value, 'max', d.max_value, 'allowed', d.allowed, 'help', d.help,
           'overridden', e.source = p_scope and e.source_id is not distinct from private.scope_id_of(p_scope, p_scope_id),
           'reason', (select s.reason from public.setting s where s.key = d.key and s.scope = p_scope
                       and coalesce(s.module_week_id, s.module_id, s.cohort_id, s.domain_id) is not distinct from private.scope_id_of(p_scope, p_scope_id)))
         order by d.sort_order), '[]')
    from public.setting_definition d
    cross join lateral private.setting_with_source(case when p_scope = 'Global' then null else p_scope_id end, d.key) e
   where private.is_team_user() or private.is_service();
$$;

create or replace function public.effective_settings(p_domain_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$ select public.effective_settings_for('Domain', p_domain_id); $$;

grant execute on function public.set_setting_at(text, uuid, text, jsonb, text) to authenticated;
grant execute on function public.reset_setting_at(text, uuid, text) to authenticated;
grant execute on function public.effective_settings_for(text, uuid) to authenticated;
revoke execute on function public.set_setting_at(text, uuid, text, jsonb, text) from anon;
revoke execute on function public.reset_setting_at(text, uuid, text) from anon;
revoke execute on function public.effective_settings_for(text, uuid) from anon;

-- -------------------------------------------------------------------------------------
-- People: escalation contacts, default operations team, operations team per module and cohort
-- -------------------------------------------------------------------------------------
create or replace function private.domain_role_ids(p_domain uuid, p_role text)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(dt.team_member_id order by t.name), '{}')
    from public.domain_team dt join public.team_member t on t.id = dt.team_member_id
   where dt.domain_id = p_domain and t.active
     and dt.role = case p_role when 'Lead' then 'Escalation' when 'Ops' then 'Operations' else p_role end;
$$;

-- Operations team for a module (and cohort): cohort rows, else module rows, else the domain default.
create or replace function private.ops_for_module(p_module uuid, p_cohort uuid default null)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select coalesce(
    nullif((select coalesce(array_agg(o.team_member_id order by t.name), '{}') from public.module_operations o
              join public.team_member t on t.id = o.team_member_id
             where o.module_id = p_module and p_cohort is not null and o.cohort_id = p_cohort and t.active), '{}'),
    nullif((select coalesce(array_agg(o.team_member_id order by t.name), '{}') from public.module_operations o
              join public.team_member t on t.id = o.team_member_id
             where o.module_id = p_module and o.cohort_id is null and t.active), '{}'),
    private.domain_role_ids((select m.domain_id from public.module m where m.id = p_module), 'Operations'));
$$;

create or replace function private.ops_for_week(p_mw uuid)
returns uuid[] language sql stable security definer set search_path = ''
as $$ select private.ops_for_module(w.module_id, w.cohort_id) from public.module_week w where w.id = p_mw; $$;

-- Everyone on any domain's default operations team (used when nothing points to a domain).
create or replace function private.all_operations_ids()
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(distinct dt.team_member_id), '{}')
    from public.domain_team dt join public.team_member t on t.id = dt.team_member_id
   where dt.role = 'Operations' and t.active;
$$;

create or replace function private.recipients_for_week(p_mw uuid, p_with_ops boolean, p_with_leads boolean default false)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select private.uniq(private.owners_or_leads(w.module_id)
         || case when p_with_ops then private.ops_for_week(w.id) else '{}'::uuid[] end
         || case when p_with_leads then private.domain_role_ids(w.domain_id, 'Escalation') else '{}'::uuid[] end)
    from public.module_week w where w.id = p_mw;
$$;

-- Where a team member helps: "Owner of Concurrency", "Operations for Backend", "Escalation for Backend".
create or replace function public.team_assignments()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_object_agg(t.id, coalesce((
      select jsonb_agg(x.label order by x.ord, x.label) from (
        select 1 as ord, 'Owner of ' || m.name || coalesce(' (' || d.name || ')', '') as label
          from public.module_owner o join public.module m on m.id = o.module_id join public.domain d on d.id = m.domain_id
         where o.team_member_id = t.id and m.status <> 'Archived'
        union all
        select 2, 'Operations for ' || m.name || coalesce(', ' || c.name, '')
          from public.module_operations o join public.module m on m.id = o.module_id left join public.cohort c on c.id = o.cohort_id
         where o.team_member_id = t.id and m.status <> 'Archived'
        union all
        select 3, case dt.role when 'Operations' then 'Operations for ' else 'Escalation for ' end || d.name
          from public.domain_team dt join public.domain d on d.id = dt.domain_id where dt.team_member_id = t.id) x), '[]'::jsonb)), '{}')
    from public.team_member t
   where private.is_team_user() or private.is_service();
$$;
grant execute on function public.team_assignments() to authenticated;
revoke execute on function public.team_assignments() from anon;

-- -------------------------------------------------------------------------------------
-- Cohorts in labels: shown only when a domain has more than one cohort
-- -------------------------------------------------------------------------------------
create or replace function private.cohort_label(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select case when (select count(*) from public.cohort c where c.domain_id = w.domain_id) > 1 then w.cohort end
    from public.module_week w where w.id = p_mw;
$$;

-- Instructor order used for a class week: the cohort's own order when it has one, else the module's.
create or replace function private.order_cohort(p_module uuid, p_cohort uuid)
returns uuid language sql stable security definer set search_path = ''
as $$
  select case when p_cohort is not null
               and exists (select 1 from public.module_ranking k where k.module_id = p_module and k.cohort_id = p_cohort)
              then p_cohort end;
$$;


create or replace function private.validate_setting()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  d public.setting_definition;
  v jsonb := new.value;
  e jsonb;
  n int;
  v_out int;
  v_read int;
  v_dom uuid := coalesce(new.module_week_id, new.module_id, new.cohort_id, new.domain_id);
begin
  select * into d from public.setting_definition where key = new.key;
  if d.value_type = 'int' then
    if jsonb_typeof(v) <> 'number' or (v #>> '{}') !~ '^-?\d+$' then
      raise exception '"%" must be a whole number.', d.label using errcode = '22023';
    end if;
    n := (v #>> '{}')::int;
    if (d.min_value is not null and n < d.min_value) or (d.max_value is not null and n > d.max_value) then
      raise exception '"%" must be between % and %.', d.label, d.min_value, d.max_value using errcode = '22023';
    end if;
  elsif d.value_type = 'bool' then
    if jsonb_typeof(v) <> 'boolean' then
      raise exception '"%" must be on or off.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'enum' then
    if jsonb_typeof(v) <> 'string' or not (d.allowed @> jsonb_build_array(v)) then
      raise exception '"%" must be one of: %.', d.label, d.allowed using errcode = '22023';
    end if;
  elsif d.value_type = 'time' then
    if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^([01]\d|2[0-3]):[0-5]\d$' then
      raise exception '"%" must be a time like 09:00.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'int_list' then
    if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then
      raise exception '"%" needs at least one value.', d.label using errcode = '22023';
    end if;
    for e in select * from jsonb_array_elements(v) loop
      if jsonb_typeof(e) <> 'number' or (e #>> '{}')::numeric not between d.min_value and d.max_value then
        raise exception '"%": every value must be between % and %.', d.label, d.min_value, d.max_value using errcode = '22023';
      end if;
    end loop;
  elsif d.value_type = 'text_list' then
    if jsonb_typeof(v) <> 'array' then
      raise exception '"%" must be a list.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'json' then
    if jsonb_typeof(v) <> 'object' then
      raise exception '"%" must be an object.', d.label using errcode = '22023';
    end if;
    if d.allowed is not null then
      for e in select value from jsonb_each(v) loop
        if not (d.allowed @> jsonb_build_array(e)) then
          raise exception '"%": each value must be one of %.', d.label, d.allowed using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  -- Cross-field rules (evaluated with this new value in place).
  if new.key in ('outreach_days', 'readiness_days') then
    v_out := case when new.key = 'outreach_days' then (v #>> '{}')::int else private.setting_int(v_dom, 'outreach_days') end;
    v_read := case when new.key = 'readiness_days' then (v #>> '{}')::int else private.setting_int(v_dom, 'readiness_days') end;
    if v_read < v_out + 5 then
      raise exception 'The readiness check must be at least 5 days before outreach starts (outreach % days → readiness at least % days).',
        v_out, v_out + 5 using errcode = '22023';
    end if;
  end if;
  if new.key in ('instructor_quiet_start', 'instructor_quiet_end') then
    if private.time_window_minutes(
         case when new.key = 'instructor_quiet_start' then v #>> '{}' else private.setting_text(v_dom, 'instructor_quiet_start') end,
         case when new.key = 'instructor_quiet_end' then v #>> '{}' else private.setting_text(v_dom, 'instructor_quiet_end') end) > 720 then
      raise exception 'Instructor quiet hours can be at most 12 hours long.' using errcode = '22023';
    end if;
  end if;
  if new.key in ('team_quiet_start', 'team_quiet_end') then
    if private.time_window_minutes(
         case when new.key = 'team_quiet_start' then v #>> '{}' else private.setting_text(v_dom, 'team_quiet_start') end,
         case when new.key = 'team_quiet_end' then v #>> '{}' else private.setting_text(v_dom, 'team_quiet_end') end) > 840 then
      raise exception 'Team quiet hours can be at most 14 hours long.' using errcode = '22023';
    end if;
  end if;
  if new.key = 'instructor_channels' and (v #>> '{}') not in ('Both', 'DiscordOnly', 'EmailOnly') then
    raise exception 'Choose at least one channel.' using errcode = '22023';
  end if;
  return new;
end;
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
  if new.discord_channel_link is not null and trim(new.discord_channel_link) <> '' then
    m := regexp_match(trim(new.discord_channel_link),
                      '^https://(?:www\.|ptb\.|canary\.)?discord(?:app)?\.com/channels/(\d{17,20})/(\d{17,20})/?$');
    if m is null then
      raise exception 'The Discord channel link should look like https://discord.com/channels/<server id>/<channel id>.'
        using errcode = '22023';
    end if;
    if v_guild is not null and m[1] <> v_guild then
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

create or replace function private.mw_label(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select m.name || coalesce(' (' || private.cohort_label(w.id) || ')', '') || ' · '
      || coalesce((select string_agg(to_char(c.starts_at at time zone 'America/Los_Angeles', 'Dy Mon FMDD'), ' + ' order by c.starts_at)
                     from public.class_session c where c.module_week_id = w.id and c.status <> 'Cancelled'), 'no classes')
    from public.module_week w join public.module m on m.id = w.module_id where w.id = p_mw;
$$;

create or replace function private.page_details(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select '<p><strong>' || private.html_escape(m.name) || '</strong>'
      || coalesce(' · ' || private.html_escape(private.cohort_label(w.id)), '') || ' · ' || private.html_escape(d.name) || '</p><ul>'
      || coalesce((select string_agg('<li>' || private.html_escape(c.class_type) || ': ' || private.html_escape(private.fmt_pt_range(c.starts_at, c.ends_at)) || '</li>', '' order by c.starts_at)
                     from public.class_session c where c.module_week_id = w.id and c.status <> 'Cancelled'), '')
      || '</ul>'
    from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id
   where w.id = p_mw;
$$;

create or replace function private.build_line(p_mw uuid)
returns table (pos int, instructor_id uuid, full_name text, source text, reason text, warning text, queue_item_id uuid)
language plpgsql stable security definer set search_path = ''
as $$
declare
  w public.module_week;
  r record;
  n int := 0;
  v_hist text;
begin
  select * into w from public.module_week where id = p_mw;
  if w.outreach_mode = 'Manual' then
    for r in select q.id as qid, q.instructor_id as iid, i.full_name as nm
               from public.manual_queue_item q join public.instructor i on i.id = q.instructor_id
              where q.module_week_id = p_mw and q.asked_request_id is null order by q.position loop
      n := n + 1;
      v_hist := private.week_history_reason(r.iid, p_mw);
      pos := n; instructor_id := r.iid; full_name := r.nm; source := 'Manual'; queue_item_id := r.qid;
      reason := coalesce(private.eligibility(r.iid, p_mw), case when v_hist = 'Being asked now' then v_hist end);
      warning := case when v_hist <> 'Being asked now' then v_hist end;
      return next;
    end loop;
    if w.manual_end_behaviour <> 'ContinueWithRanking' then
      return;
    end if;
  end if;
  for r in select k.instructor_id as iid, i.full_name as nm
             from public.module_ranking k join public.instructor i on i.id = k.instructor_id
            where k.module_id = w.module_id and k.cohort_id is not distinct from private.order_cohort(w.module_id, w.cohort_id)
              and (w.outreach_mode <> 'Manual'
                   or k.instructor_id not in (select q.instructor_id from public.manual_queue_item q where q.module_week_id = p_mw))
            order by k.rank loop
    n := n + 1;
    pos := n; instructor_id := r.iid; full_name := r.nm; source := 'Ranking'; queue_item_id := null; warning := null;
    reason := coalesce(private.eligibility(r.iid, p_mw), private.week_history_reason(r.iid, p_mw));
    return next;
  end loop;
end;
$$;

drop function public.save_ranking(uuid, uuid[], uuid[]);

create or replace function public.save_ranking(p_module_id uuid, p_instructor_ids uuid[], p_expected_ids uuid[] default null, p_cohort_id uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_before uuid[];
  v_dom uuid;
  i int;
begin
  perform private.require_team();
  select domain_id into v_dom from public.module where id = p_module_id;
  select coalesce(array_agg(instructor_id order by rank), '{}') into v_before from public.module_ranking where module_id = p_module_id and cohort_id is not distinct from p_cohort_id;
  if p_expected_ids is not null and v_before is distinct from p_expected_ids then
    raise exception 'This changed — reload. Someone else saved this ranking after you opened it.' using errcode = '40001';
  end if;
  if (select count(distinct x) from unnest(p_instructor_ids) x) <> cardinality(p_instructor_ids) then
    raise exception 'An instructor appears twice in the ranking.';
  end if;
  perform set_config('app.suppress_setup_log', 'on', true);
  delete from public.module_ranking where module_id = p_module_id and cohort_id is not distinct from p_cohort_id;
  for i in 1 .. coalesce(cardinality(p_instructor_ids), 0) loop
    insert into public.module_ranking (module_id, cohort_id, instructor_id, rank) values (p_module_id, p_cohort_id, p_instructor_ids[i], i);
  end loop;
  perform set_config('app.suppress_setup_log', 'off', true);
  perform private.log_event('Setup changes', 'Ranking saved', 'module_ranking', p_module_id,
    jsonb_build_object('instructor_ids', to_jsonb(v_before), 'cohort_id', p_cohort_id,
      'names', (select jsonb_agg(ins.full_name order by o) from unnest(v_before) with ordinality u(x, o) join public.instructor ins on ins.id = u.x)),
    jsonb_build_object('instructor_ids', to_jsonb(p_instructor_ids), 'cohort_id', p_cohort_id,
      'names', (select jsonb_agg(ins.full_name order by o) from unnest(p_instructor_ids) with ordinality u(x, o) join public.instructor ins on ins.id = u.x)),
    null, v_dom, p_module_id);
end;
$$;

grant execute on function public.save_ranking(uuid, uuid[], uuid[], uuid) to authenticated;
revoke execute on function public.save_ranking(uuid, uuid[], uuid[], uuid) from anon;

drop function public.ranking_impact(uuid, uuid[]);

create or replace function public.ranking_impact(p_module_id uuid, p_instructor_ids uuid[], p_cohort_id uuid default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_weeks jsonb := '[]';
  v_after jsonb := '{}';
  w record;
  i int;
begin
  perform private.require_team();
  for w in select mw.id from public.module_week mw where mw.module_id = p_module_id
            and private.order_cohort(mw.module_id, mw.cohort_id) is not distinct from p_cohort_id
            and mw.status not in ('Confirmed', 'Completed', 'Cancelled') and mw.first_class_at > now()
            order by mw.first_class_at loop
    v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id, 'label', private.mw_label(w.id), 'next_now', private.next_name(w.id));
  end loop;
  begin
    perform set_config('app.suppress_setup_log', 'on', true);
    delete from public.module_ranking where module_id = p_module_id and cohort_id is not distinct from p_cohort_id;
    for i in 1 .. coalesce(cardinality(p_instructor_ids), 0) loop
      insert into public.module_ranking (module_id, cohort_id, instructor_id, rank) values (p_module_id, p_cohort_id, p_instructor_ids[i], i);
    end loop;
    for w in select x ->> 'module_week_id' as id from jsonb_array_elements(v_weeks) x loop
      v_after := v_after || jsonb_build_object(w.id, private.next_name(w.id::uuid));
    end loop;
    raise exception 'preview_rollback';
  exception when others then
    perform set_config('app.suppress_setup_log', 'off', true);
    if sqlerrm <> 'preview_rollback' then raise; end if;
  end;
  return jsonb_build_object(
    'affected_weeks', jsonb_array_length(v_weeks),
    'confirmed_weeks', (select count(*) from public.module_week mw where mw.module_id = p_module_id and mw.status = 'Confirmed' and mw.first_class_at > now()),
    'weeks', (select coalesce(jsonb_agg(x || jsonb_build_object('next_after', v_after ->> (x ->> 'module_week_id'))), '[]') from jsonb_array_elements(v_weeks) x));
end;
$$;

grant execute on function public.ranking_impact(uuid, uuid[], uuid) to authenticated;
revoke execute on function public.ranking_impact(uuid, uuid[], uuid) from anon;

create or replace function public.week_eligibility(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_module uuid; v_cohort uuid;
begin
  perform private.require_team();
  select module_id, private.order_cohort(module_id, cohort_id) into v_module, v_cohort from public.module_week where id = p_module_week_id;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'instructor_id', i.id, 'name', i.full_name, 'rank', k.rank, 'in_ranking', k.rank is not null,
            'reason', private.eligibility(i.id, p_module_week_id),
            'warning', private.week_history_reason(i.id, p_module_week_id), 'is_test', i.is_test)
          order by k.rank nulls last, i.full_name), '[]')
     from public.instructor i left join public.module_ranking k on k.instructor_id = i.id and k.module_id = v_module and k.cohort_id is not distinct from v_cohort
    where i.status <> 'Archived');
end;
$$;

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
  select * into e from public.history_event where id = p_event_id;
  if e.id is null or e.category <> 'Setup changes' then
    raise exception 'Only setup changes can be undone.';
  end if;
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

create or replace function private.band(p_mw uuid, p_now timestamptz)
returns text language sql stable security definer set search_path = ''
as $$
  select case
    when private.days_until(p_mw, p_now) > private.setting_int(w.id, 'short_notice_days') then 'Long'
    when private.days_until(p_mw, p_now) >= private.setting_int(w.id, 'urgent_band_days') then 'Mid'
    else 'Short' end
  from public.module_week w where w.id = p_mw;
$$;

create or replace function private.window_hours(p_mw uuid, p_now timestamptz, out band text, out reminder_h int, out move_h int)
language plpgsql stable security definer set search_path = ''
as $$
declare v_dom uuid := (select w.domain_id from public.module_week w where w.id = p_mw);
begin
  band := private.band(p_mw, p_now);
  reminder_h := private.setting_int(p_mw, case band when 'Long' then 'window_long_reminder_h' when 'Mid' then 'window_mid_reminder_h' else 'window_short_reminder_h' end);
  move_h := private.setting_int(p_mw, case band when 'Long' then 'window_long_move_h' when 'Mid' then 'window_mid_move_h' else 'window_short_move_h' end);
end;
$$;

create or replace function private.ask_next(p_mw uuid, p_now timestamptz)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  l record;
  v_pick record;
  v_found boolean := false;
  v_skips text := '';
  v_req uuid;
  v_win record;
  v_urgent boolean;
  v_send timestamptz;
  v_deadline timestamptz;
  v_first boolean;
  v_test boolean;
begin
  select * into w from public.module_week where id = p_mw for update;
  if w.status in ('Cancelled', 'Completed') then
    return null;
  end if;
  if w.paused or w.first_class_at is null or w.first_class_at <= p_now
     or not private.instructor_messages_allowed(w.domain_id) then
    -- Can't ask right now (paused, kill switch, class started): never leave the week "Asking" with
    -- nobody asked — set it back to Ready so the next allowed run picks it up.
    if w.status = 'Asking' and not exists (select 1 from public.request r where r.module_week_id = p_mw
                                            and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')) then
      update public.module_week set status = 'Ready' where id = p_mw;
    end if;
    return null;
  end if;
  select r.id into v_req from public.request r
   where r.module_week_id = p_mw and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded');
  if v_req is not null then return v_req; end if;
  if exists (select 1 from public.booking b where b.module_week_id = p_mw and b.status = 'Active') then
    return null;
  end if;

  for l in select * from private.build_line(p_mw) order by pos loop
    if l.reason is null then
      v_pick := l;
      v_found := true;
      exit;
    elsif l.reason not in ('Already declined this module week', 'Did not reply earlier', 'Skipped by ops',
                           'Cancelled this module week earlier', 'Had a clash when they said yes', 'Being asked now') then
      v_skips := v_skips || l.full_name || ' — ' || l.reason || '; ';
    end if;
  end loop;
  v_test := private.is_test_domain(w.domain_id);

  if not v_found then
    if w.status <> 'NeedsInstructor' then
      update public.module_week set status = 'NeedsInstructor' where id = p_mw;
      perform private.log_event('System', 'Ranking exhausted — needs instructor', 'module_week', p_mw, null, null,
        nullif(v_skips, ''), w.domain_id, w.module_id, p_mw, null, null, null, v_test);
    end if;
    perform private.raise_attention(w.domain_id, 'RankingExhausted', 'Urgent',
      'Needs instructor: ' || private.mw_label(p_mw),
      'Everyone in line has been asked or can''t be asked. Assign someone manually or add instructors to the ranking.'
        || coalesce(E'\nSkipped: ' || nullif(v_skips, ''), ''),
      'exhausted:' || p_mw, private.recipients_for_week(p_mw, true), p_now, private.mw_refs(p_mw),
      true, 'T4');
    return null;
  end if;

  v_win := private.window_hours(p_mw, p_now);
  v_urgent := v_win.band = 'Short';
  v_send := private.instructor_send_time(w.domain_id, p_now, v_urgent);
  v_deadline := least(private.instructor_send_time(w.domain_id, v_send + make_interval(hours => v_win.move_h), v_urgent),
                      w.first_class_at);
  insert into public.request (module_week_id, instructor_id, kind, status, time_version, line_source,
    declined_before, sent_at, reminder_at, deadline_at, is_test)
  values (p_mw, v_pick.instructor_id, 'Outreach', 'Sent', w.time_version, v_pick.source,
    v_pick.warning is not null, v_send,
    least(private.instructor_send_time(w.domain_id, v_send + make_interval(hours => v_win.reminder_h), v_urgent), v_deadline),
    v_deadline, v_test)
  returning id into v_req;
  if v_pick.queue_item_id is not null then
    update public.manual_queue_item set asked_request_id = v_req where id = v_pick.queue_item_id;
  end if;
  perform private.queue_instructor_message('M1', v_pick.instructor_id, p_mw, v_req, p_now,
    private.buttons(v_req, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_pt(v_deadline)), v_urgent);

  v_first := w.outreach_started_at is null;
  update public.module_week
     set status = 'Asking', outreach_started_at = coalesce(outreach_started_at, p_now)
   where id = p_mw;
  perform private.log_event('Messages', 'Asked ' || v_pick.full_name, 'request', v_req, null,
    jsonb_build_object('deadline', v_deadline, 'band', v_win.band, 'source', v_pick.source),
    nullif('Skipped: ' || v_skips, 'Skipped: '), w.domain_id, w.module_id, p_mw, null, v_pick.instructor_id, null, v_test);
  if v_first then
    perform private.queue_team_message('T1', w.domain_id, 'alert', null, private.owners_or_leads(w.module_id),
      'Outreach started: ' || private.mw_label(p_mw),
      '📣 Outreach started for ' || private.mw_label(p_mw) || ' — asking ' || v_pick.full_name || '.',
      'T1:' || p_mw, p_now, false, null, p_mw);
  end if;
  if v_urgent then
    perform private.raise_attention(w.domain_id, 'ClassAtRisk', 'Urgent',
      'Under ' || private.setting_int(w.id, 'urgent_band_days') || ' days and no instructor yet: ' || private.mw_label(p_mw),
      'Now asking ' || v_pick.full_name || ' (moves on after ' || v_win.move_h || 'h). Consider phoning people too.',
      'urgentfill:' || p_mw, private.recipients_for_week(p_mw, true), p_now, private.mw_refs(p_mw));
  end if;
  return v_req;
end;
$$;

create or replace function private.confirm_booking(p_mw uuid, p_instructor uuid, p_request uuid, p_via text, p_now timestamptz, p_note text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  r public.request;
  v_reason text;
  v_booking uuid;
  v_req uuid := p_request;
  v_name text := (select i.full_name from public.instructor i where i.id = p_instructor);
  v_test boolean;
  v_clash text;
begin
  select * into w from public.module_week where id = p_mw for update;
  v_test := private.is_test_domain(w.domain_id);
  if w.status in ('Cancelled', 'Completed') then
    return jsonb_build_object('ok', false, 'reason', 'week_closed', 'message', 'This class is no longer scheduled.');
  end if;
  if exists (select 1 from public.booking b where b.module_week_id = p_mw and b.status = 'Active') then
    return jsonb_build_object('ok', false, 'reason', 'already_booked', 'message', 'This module week already has a confirmed instructor.');
  end if;
  if p_via = 'Instructor' then
    select * into r from public.request where id = p_request for update;
    if r.status not in ('Sent', 'Reminded') then
      return jsonb_build_object('ok', false, 'reason', 'closed', 'message', 'This request has closed.');
    end if;
    if r.time_version <> w.time_version then
      return jsonb_build_object('ok', false, 'reason', 'stale', 'message', 'The class times changed — please use the latest message.');
    end if;
  end if;
  v_reason := private.eligibility(p_instructor, p_mw);
  if p_via in ('Manual', 'Offline') and v_reason = 'Not verified' then
    v_reason := null;            -- ops may assign someone they confirmed personally
  end if;
  if v_reason is not null then
    return jsonb_build_object('ok', false, 'reason', case when v_reason like 'Teaching %' then 'clash' else 'ineligible' end,
      'message', v_reason);
  end if;

  begin
    insert into public.booking (module_week_id, instructor_id, request_id, confirmed_via, confirmed_at, confirmed_by,
      time_version_confirmed, is_test)
    values (p_mw, p_instructor, null, p_via, p_now, private.current_team_member_id(), w.time_version, v_test)
    returning id into v_booking;
    insert into public.booking_slot (booking_id, class_id, instructor_id, time_range)
    select v_booking, c.id, p_instructor, tstzrange(c.starts_at, c.ends_at, '[)')
      from public.class_session c where c.module_week_id = p_mw and c.status = 'Planned';
  exception
    when exclusion_violation then
      select 'Teaching ' || m.name || ' at this time' into v_clash
        from public.booking_slot s join public.booking b on b.id = s.booking_id
        join public.module_week w2 on w2.id = b.module_week_id join public.module m on m.id = w2.module_id
       where s.instructor_id = p_instructor and s.active limit 1;
      return jsonb_build_object('ok', false, 'reason', 'clash', 'message', coalesce(v_clash, 'Teaching another class at this time'));
    when unique_violation then
      return jsonb_build_object('ok', false, 'reason', 'already_booked', 'message', 'This module week already has a confirmed instructor.');
  end;

  if p_via <> 'Instructor' then
    -- Another instructor being asked is withdrawn politely; the same instructor's open request is accepted.
    select * into r from public.request
     where module_week_id = p_mw and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded') for update;
    if r.id is not null and r.instructor_id <> p_instructor then
      perform private.withdraw_open_request(p_mw, 'Assigned to someone else', p_now, true);
      r := null;
    end if;
    if r.id is not null then
      v_req := r.id;
    else
      insert into public.request (module_week_id, instructor_id, kind, status, answer, time_version, line_source,
        sent_at, answered_at, is_test, close_reason)
      values (p_mw, p_instructor, 'Outreach', 'Accepted', 'Yes', w.time_version, p_via, p_now, p_now, v_test,
        case when p_via = 'Manual' then 'Assigned manually' else 'Confirmed offline' end)
      returning id into v_req;
    end if;
  end if;

  update public.request set status = 'Accepted', answer = 'Yes', answered_at = p_now where id = v_req and status <> 'Accepted';
  update public.booking set request_id = v_req where id = v_booking;
  update public.module_week set status = 'Confirmed', at_risk = false, at_risk_reason = null where id = p_mw;
  if p_via = 'Instructor' then
    update public.instructor set last_response_at = p_now where id = p_instructor;
  end if;
  perform private.resolve_attention('exhausted:' || p_mw, 'Instructor confirmed');
  perform private.resolve_attention('urgentfill:' || p_mw, 'Instructor confirmed');
  perform private.resolve_attention('atrisk:' || p_mw, 'Replacement confirmed');
  perform private.resolve_attention('readiness:' || p_mw, 'Instructor confirmed');

  -- Class checklist (SCH-8)
  insert into public.checklist_item (class_id, booking_id, label, due_at)
  select c.id, v_booking, lbl, w.first_class_at - make_interval(days => private.setting_int(w.id, 'checklist_due_days'))
    from public.class_session c
    cross join lateral jsonb_array_elements_text(private.get_setting(w.id, 'checklist_items')) lbl
   where c.module_week_id = p_mw and c.status = 'Planned'
  on conflict (class_id, label) do update set booking_id = excluded.booking_id;

  perform private.queue_instructor_message('M4', p_instructor, p_mw, v_req, p_now,
    private.buttons(v_req, array['NeedHelp', 'CantMakeItAnymore']));
  perform private.queue_team_message('T2', w.domain_id, 'alert', null, private.owners_or_leads(w.module_id),
    'Confirmed: ' || private.mw_label(p_mw),
    '✅ ' || v_name || ' is confirmed for ' || private.mw_label(p_mw)
      || case p_via when 'Manual' then ' (assigned manually)' when 'Offline' then ' (confirmed offline)' else '' end || '.',
    'T2:' || v_booking, p_now, false, null, p_mw);
  perform private.log_event('Bookings', 'Booked ' || v_name, 'booking', v_booking, null,
    jsonb_build_object('via', p_via, 'time_version', w.time_version), p_note,
    w.domain_id, w.module_id, p_mw, null, p_instructor, null, v_test);
  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'request_id', v_req);
end;
$$;

create or replace function private.release_booking_flow(p_booking uuid, p_kind text, p_now timestamptz, p_restart boolean default true, p_note text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  b public.booking;
  w public.module_week;
  v_name text;
  v_urgent boolean;
  v_reason text;
  v_test boolean;
begin
  select * into b from public.booking where id = p_booking for update;
  if b.id is null or b.status <> 'Active' then
    return jsonb_build_object('ok', false, 'reason', 'not_active', 'message', 'This booking is no longer active.');
  end if;
  select * into w from public.module_week where id = b.module_week_id for update;
  select i.full_name into v_name from public.instructor i where i.id = b.instructor_id;
  v_test := b.is_test;

  if w.first_class_at <= p_now then
    -- The class already started or passed: no automation, ops told (edge case 9).
    perform private.raise_attention(w.domain_id, 'ClassAtRisk', 'Urgent',
      v_name || ' says they can''t teach ' || private.mw_label(w.id) || ' — the class has already started',
      'No automatic action was taken. Please handle this directly.', 'started:' || b.id,
      private.recipients_for_week(w.id, true), p_now, private.mw_refs(w.id, jsonb_build_object('instructor_id', b.instructor_id)));
    return jsonb_build_object('ok', true, 'started', true);
  end if;

  v_reason := case p_kind
    when 'InstructorCancelled' then v_name || ' cancelled'
    when 'OpsReleased' then 'Released by ops'
    when 'TimeChangeDeclined' then v_name || ' can''t make the new time'
    when 'TimeClash' then 'New time clashes with another booking for ' || v_name
    when 'Deactivated' then v_name || ' was deactivated'
    when 'NoReplyRelease' then v_name || ' did not reply to the last check-in'
    else p_kind end;

  update public.booking set status = 'Released', released_at = p_now, release_reason = p_kind where id = b.id;
  update public.request set status = 'Superseded', close_reason = 'Booking released'
   where booking_id = b.id and status in ('Queued', 'Sent', 'Reminded');
  perform private.queue_instructor_message(
    case when p_kind in ('InstructorCancelled', 'TimeChangeDeclined') then 'M10' else 'M12' end,
    b.instructor_id, w.id, null, p_now, '[]', '{}', false, 'release:' || b.id);

  v_urgent := private.days_until(w.id, p_now) < private.setting_int(w.id, 'short_notice_days');
  -- Without a restart the week is paused, so the hourly check doesn't restart it either.
  update public.module_week
     set status = 'Ready', at_risk = true, at_risk_reason = v_reason, paused = paused or not p_restart
   where id = w.id;
  perform private.raise_attention(w.domain_id, 'ClassAtRisk', case when v_urgent then 'Urgent' else 'Normal' end,
    'At risk: ' || private.mw_label(w.id) || ' — ' || v_reason,
    case when p_restart then 'Outreach has restarted automatically.' else 'Outreach is paused for this week — resume it in the class drawer when ready.' end || coalesce(' ' || p_note, ''),
    'atrisk:' || w.id, private.recipients_for_week(w.id, true), p_now,
    private.mw_refs(w.id, jsonb_build_object('instructor_id', b.instructor_id)), true, 'T5');
  perform private.log_event('Bookings', 'Booking released: ' || v_name, 'booking', b.id,
    jsonb_build_object('status', 'Active'), jsonb_build_object('status', 'Released', 'reason', p_kind), p_note,
    w.domain_id, w.module_id, w.id, null, b.instructor_id, null, v_test);
  if p_restart then
    perform private.ask_next(w.id, p_now);
  end if;
  return jsonb_build_object('ok', true, 'restarted', p_restart);
end;
$$;

create or replace function private.create_help_request(
  p_mw uuid, p_instructor uuid, p_member uuid, p_source text, p_categories text[], p_details text,
  p_urgency text, p_reply text, p_now timestamptz, p_booking uuid default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  h public.help_request;
  v_routing jsonb;
  v_routed uuid[] := '{}';
  v_owners uuid[];
  v_ops uuid[];
  v_leads uuid[];
  c text;
  v_rule text;
  v_days numeric;
  v_h int;
  v_sev text := 'Normal';
  v_name text;
  v_cats text[] := coalesce(p_categories, '{}');
  v_helper text;
begin
  select * into w from public.module_week where id = p_mw;
  if cardinality(v_cats) = 0 then v_cats := array['other']; end if;
  v_name := coalesce((select i.full_name from public.instructor i where i.id = p_instructor),
                     (select t.name from public.team_member t where t.id = p_member), 'Someone');

  -- Duplicates within 1 hour merge into one (PRD 10.6).
  select * into h from public.help_request
   where module_week_id = p_mw and merged_into is null
     and status in ('Open', 'InProgress', 'WaitingOnInstructor')
     and coalesce(requester_instructor_id::text, requester_team_member_id::text) = coalesce(p_instructor::text, p_member::text)
     and raised_at >= p_now - interval '1 hour'
   order by raised_at desc limit 1 for update;
  if h.id is not null then
    update public.help_request
       set categories = (select array_agg(distinct x) from unnest(categories || v_cats) x),
           details = left(concat_ws(E'\n---\n', nullif(details, ''), nullif(p_details, '')), 1000),
           urgency = case when p_urgency = 'Urgent' or urgency = 'Urgent' then 'Urgent'
                          when p_urgency = 'Within24h' or urgency = 'Within24h' then 'Within24h' else 'NoRush' end,
           status = 'Open'
     where id = h.id returning * into h;
    perform private.log_event('Help requests', 'Help request merged (same person within 1 hour)', 'help_request', h.id,
      null, jsonb_build_object('categories', v_cats), p_details, w.domain_id, w.module_id, p_mw, null, p_instructor);
    return jsonb_build_object('id', h.id, 'merged', true, 'target_at', h.response_target_at,
      'helper', private.team_names(coalesce(nullif(array[h.assigned_to], array[null]::uuid[]), h.routed_to[1:1])));
  end if;

  v_routing := private.get_setting(w.id, 'help_routing');
  v_owners := private.owners_or_leads(w.module_id);
  v_ops := private.ops_for_week(w.id);
  v_leads := private.domain_role_ids(w.domain_id, 'Lead');
  if p_source = 'Owner' then
    v_routed := v_ops || v_leads;
  else
    foreach c in array v_cats loop
      v_rule := coalesce(v_routing ->> c, 'Both');
      v_routed := v_routed || case v_rule when 'Owner' then v_owners when 'Ops' then v_ops else v_owners || v_ops end;
    end loop;
  end if;
  v_routed := private.uniq(v_routed);
  if cardinality(v_routed) = 0 then v_routed := private.uniq(v_ops || v_leads); end if;

  -- Response target: whichever is shorter, urgency or time to class (PRD 10.5).
  v_days := private.days_until(p_mw, p_now);
  v_h := case p_urgency when 'Urgent' then private.setting_int(w.id, 'help_target_urgent_h')
                        when 'Within24h' then private.setting_int(w.id, 'help_target_24h_h')
                        else private.setting_int(w.id, 'help_target_norush_h') end;
  if v_days < 2 then
    v_h := least(v_h, private.setting_int(w.id, 'help_target_urgent_h'));
  elsif v_days <= 7 then
    v_h := least(v_h, private.setting_int(w.id, 'help_target_24h_h'));
  end if;
  if p_urgency = 'Urgent' or v_days < 2 then v_sev := 'Urgent'; end if;

  insert into public.help_request (domain_id, module_week_id, booking_id, requester_instructor_id, requester_team_member_id,
    source, categories, details, urgency, reply_channel, routed_to, severity, raised_at, response_target_at, is_test)
  values (w.domain_id, p_mw, coalesce(p_booking, (select b.id from public.booking b where b.module_week_id = p_mw and b.status = 'Active')),
    p_instructor, p_member, p_source, v_cats, left(p_details, 1000), coalesce(p_urgency, 'NoRush'), coalesce(p_reply, 'Either'),
    v_routed, v_sev, p_now, p_now + make_interval(hours => v_h),
    private.is_test_domain(w.domain_id))
  returning * into h;

  v_helper := (select t.name from public.team_member t where t.id = v_routed[1]);
  perform private.raise_attention(w.domain_id, 'HelpRequest', v_sev,
    'Need help: ' || v_name || ' — ' || private.mw_label(p_mw),
    (select string_agg(private.help_category_label(x), ', ') from unnest(v_cats) x) || coalesce(E'\n' || p_details, '')
      || E'\nReply by ' || private.fmt_ist(h.response_target_at),
    'help:' || h.id, v_routed, p_now,
    private.mw_refs(p_mw, jsonb_build_object('help_request_id', h.id, 'instructor_id', p_instructor, 'due_at', h.response_target_at)),
    true, 'T7');
  if p_instructor is not null then
    perform private.queue_instructor_message('M13', p_instructor, p_mw, null, p_now, '[]',
      jsonb_build_object('helper', coalesce(v_helper, 'Our team'), 'by', private.fmt_pt(h.response_target_at)),
      v_sev = 'Urgent', 'help:' || h.id, h.id,
      case when coalesce(p_reply, 'Either') = 'Email' then 'Email' when p_reply = 'Discord' then 'Discord' end);
  end if;
  perform private.log_event('Help requests', 'Help requested by ' || v_name, 'help_request', h.id, null,
    jsonb_build_object('categories', v_cats, 'urgency', p_urgency, 'routed_to', private.team_names(v_routed)),
    p_details, w.domain_id, w.module_id, p_mw, null, p_instructor, null, h.is_test);
  return jsonb_build_object('id', h.id, 'merged', false, 'target_at', h.response_target_at, 'helper', coalesce(v_helper, 'Our team'));
end;
$$;

create or replace function public.record_response(p_token text, p_answer text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  lnk public.response_link;
  r public.request;
  w public.module_week;
  v_now timestamptz;
  v_res jsonb;
  v_name text;
  v_answer text;
  v_booking uuid;
  v_days numeric;
begin
  perform private.require_team();
  select * into lnk from public.response_link where token = p_token for update;
  if lnk.token is null then
    return jsonb_build_object('result', 'invalid', 'message', 'This link isn''t valid.');
  end if;
  v_answer := lnk.answer;
  if p_answer is not null and p_answer <> v_answer then
    return jsonb_build_object('result', 'invalid', 'message', 'This link isn''t valid.');
  end if;
  select * into r from public.request where id = lnk.request_id for update;
  select * into w from public.module_week where id = r.module_week_id;
  v_now := case when w.id is not null then private.domain_now(w.domain_id) else now() end;
  if r.instructor_id is not null then
    select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
    perform private.set_actor('Instructor', r.instructor_id, v_name);
  else
    select t.name into v_name from public.team_member t where t.id = r.team_member_id;
    perform private.set_actor('TeamMember', null, v_name);
  end if;
  if v_now <> now() then perform private.set_sim_now(v_now); end if;
  if lnk.used_at is not null then
    return jsonb_build_object('result', 'already_recorded', 'message', 'Already recorded — thank you!');
  end if;

  -- ---------- verification test message
  if r.kind = 'Test' then
    update public.response_link set used_at = now() where token = p_token;
    update public.request set status = 'Accepted', answer = v_answer, answered_at = v_now
     where id = r.id and status in ('Queued', 'Sent', 'Reminded');
    update public.instructor set verified_at = coalesce(verified_at, now()), last_response_at = v_now where id = r.instructor_id;
    perform private.log_event('Instructor responses', v_name || ' confirmed the test message (verified)', 'instructor',
      r.instructor_id, null, null, null, null, null, null, null, r.instructor_id);
    return jsonb_build_object('result', 'verified', 'message', 'Thanks! You''re all set to receive messages from us.');
  end if;

  -- ---------- confirmation links (Can't make it from M4) on an accepted outreach request
  if r.kind = 'Outreach' and v_answer = 'CantMakeIt' then
    select b.id into v_booking from public.booking b where b.request_id = r.id and b.status = 'Active';
    if v_booking is null then
      return jsonb_build_object('result', 'closed', 'message', 'This booking is no longer active, so nothing changed.');
    end if;
    update public.response_link set used_at = now() where token = p_token;
    perform private.log_event('Instructor responses', v_name || ': can''t make it', 'request', r.id, null, null, null,
      w.domain_id, w.module_id, w.id, null, r.instructor_id);
    v_res := private.release_booking_flow(v_booking, 'InstructorCancelled', v_now);
    return jsonb_build_object('result', 'cancelled', 'message', 'Thanks for letting us know — we''ll take it from here.', 'detail', v_res);
  end if;

  -- ---------- outreach Yes / No
  if r.kind = 'Outreach' then
    if r.status not in ('Sent', 'Reminded') then
      if r.status = 'Accepted' or (r.status = 'Declined' and r.answer is not null) then
        return jsonb_build_object('result', 'already_recorded', 'message', 'Already recorded — thank you!');
      end if;
      update public.response_link set used_at = now() where token = p_token;
      if v_answer = 'Yes' and w.status not in ('Cancelled', 'Completed') then
        v_days := private.days_until(w.id, v_now);
        perform private.raise_attention(w.domain_id, 'LateReply',
          case when v_days < private.setting_int(w.id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'Late "Yes" from ' || v_name || ' — ' || private.mw_label(w.id),
          'They said yes after the request closed (' || coalesce(r.close_reason, r.status) || '). Assign them manually if the slot is still free.',
          'late:' || r.id, private.ops_for_week(w.id), v_now,
          private.mw_refs(w.id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)));
      end if;
      perform private.log_event('Instructor responses', 'Late answer from ' || v_name || ': ' || v_answer, 'request', r.id,
        null, null, 'Request was ' || r.status, w.domain_id, w.module_id, w.id, null, r.instructor_id);
      return jsonb_build_object('result', 'closed', 'message',
        'This request has closed, so nothing changed. Thank you — we''ve let the team know you replied.');
    end if;

    if v_answer = 'Yes' then
      v_res := private.confirm_booking(w.id, r.instructor_id, r.id, 'Instructor', v_now);
      if (v_res ->> 'ok')::boolean then
        update public.response_link set used_at = now() where token = p_token;
        perform private.log_event('Instructor responses', v_name || ' said yes', 'request', r.id, null, null, null,
          w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
        return jsonb_build_object('result', 'confirmed', 'message', 'You''re confirmed — thank you! We''ve sent the details.');
      end if;
      if v_res ->> 'reason' in ('clash', 'ineligible', 'stale', 'already_booked', 'week_closed') then
        update public.response_link set used_at = now() where token = p_token;
        update public.request
           set status = case when v_res ->> 'reason' in ('week_closed', 'already_booked') then 'Withdrawn' else 'Declined' end,
               answer = 'Yes', answered_at = v_now,
               close_reason = case v_res ->> 'reason' when 'clash' then 'Clash' else v_res ->> 'message' end
         where id = r.id;
        perform private.log_event('Instructor responses', v_name || ' said yes, but it could not be booked', 'request', r.id,
          null, v_res, null, w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
        if v_res ->> 'reason' in ('clash', 'ineligible', 'stale') then
          perform private.raise_attention(w.domain_id, 'Other', 'Normal',
            v_name || ' said yes but couldn''t be booked — ' || private.mw_label(w.id),
            (v_res ->> 'message') || '. The next instructor is being asked.', 'yesfail:' || r.id,
            private.ops_for_week(w.id), v_now,
            private.mw_refs(w.id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)));
          perform private.ask_next(w.id, v_now);
        end if;
        return jsonb_build_object('result', 'not_booked', 'message',
          case when v_res ->> 'reason' = 'clash'
               then 'You''re already ' || lower(left(v_res ->> 'message', 1)) || substr(v_res ->> 'message', 2)
                    || ', so we''ll check with someone else. Thank you!'
               else 'We couldn''t book this one (' || (v_res ->> 'message') || '), so we''ll check with someone else. Thank you!' end);
      end if;
      return jsonb_build_object('result', 'error', 'message', coalesce(v_res ->> 'message', 'Something went wrong.'));
    elsif v_answer = 'No' then
      update public.response_link set used_at = now() where token = p_token;
      update public.request set status = 'Declined', answer = 'No', answered_at = v_now, close_reason = 'Declined' where id = r.id;
      update public.instructor set last_response_at = v_now where id = r.instructor_id;
      perform private.log_event('Instructor responses', v_name || ' said no', 'request', r.id, null, null, null,
        w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
      if private.band(w.id, v_now) <> 'Long' then
        perform private.queue_team_message('T3', w.domain_id, 'alert', null, private.owners_or_leads(w.module_id),
          'Declined: ' || private.mw_label(w.id), v_name || ' declined ' || private.mw_label(w.id) || ' — asking the next instructor.',
          'T3:' || r.id, v_now, false, null, w.id);
      end if;
      perform private.ask_next(w.id, v_now);
      return jsonb_build_object('result', 'declined', 'message', 'Thanks for letting us know — no problem!');
    end if;
  end if;

  -- ---------- check-ins
  if r.kind = 'CheckIn' then
    if v_answer = 'CantMakeIt' then
      if not exists (select 1 from public.booking b where b.id = r.booking_id and b.status = 'Active') then
        return jsonb_build_object('result', 'closed', 'message', 'This booking is no longer active, so nothing changed.');
      end if;
      update public.response_link set used_at = now() where token = p_token;
      update public.request set status = 'Accepted', answer = 'CantMakeIt', answered_at = v_now where id = r.id;
      v_res := private.release_booking_flow(r.booking_id, 'InstructorCancelled', v_now);
      return jsonb_build_object('result', 'cancelled', 'message', 'Thanks for letting us know — we''ll take it from here.');
    end if;
    if r.status not in ('Sent', 'Reminded') then
      return jsonb_build_object('result', 'already_recorded', 'message', 'Already recorded — thank you!');
    end if;
    if v_answer = 'AllSet' then
      update public.response_link set used_at = now() where token = p_token;
      update public.request set status = 'Accepted', answer = 'AllSet', answered_at = v_now where id = r.id;
      update public.instructor set last_response_at = v_now where id = r.instructor_id;
      perform private.resolve_attention('checkin_noreply:' || r.id, 'Instructor answered All set');
      perform private.log_event('Instructor responses', v_name || ': all set (' || r.check_in_days || '-day check-in)', 'request',
        r.id, null, null, null, w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
      return jsonb_build_object('result', 'all_set', 'message', 'Great — thanks! See you in class.');
    end if;
  end if;

  -- ---------- time change
  if r.kind = 'TimeChange' then
    if r.status not in ('Sent', 'Reminded') then
      return jsonb_build_object('result', 'already_recorded', 'message', 'Already recorded — thank you!');
    end if;
    update public.response_link set used_at = now() where token = p_token;
    if v_answer = 'StillWorks' then
      update public.request set status = 'Accepted', answer = 'StillWorks', answered_at = v_now where id = r.id;
      update public.booking set time_version_confirmed = r.time_version where id = r.booking_id;
      perform private.resolve_attention('timechange:' || w.id, 'Instructor confirmed the new time');
      perform private.log_event('Instructor responses', v_name || ': new time still works', 'request', r.id, null, null, null,
        w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
      return jsonb_build_object('result', 'still_works', 'message', 'Thanks — you''re still confirmed at the new time.');
    elsif v_answer = 'DoesntWork' then
      update public.request set status = 'Declined', answer = 'DoesntWork', answered_at = v_now where id = r.id;
      perform private.log_event('Instructor responses', v_name || ': new time doesn''t work', 'request', r.id, null, null, null,
        w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
      perform private.release_booking_flow(r.booking_id, 'TimeChangeDeclined', v_now);
      return jsonb_build_object('result', 'released', 'message', 'Thanks for letting us know — we''ll find someone for the new time.');
    end if;
  end if;

  -- ---------- owner check-in
  if r.kind = 'OwnerCheckIn' and v_answer = 'OwnerAllGood' then
    update public.response_link set used_at = now() where token = p_token;
    update public.request set status = 'Accepted', answer = 'OwnerAllGood', answered_at = v_now
     where id = r.id and status in ('Sent', 'Reminded');
    perform private.log_event('Team actions', v_name || ': all good for ' || private.mw_label(w.id), 'request', r.id,
      null, null, null, w.domain_id, w.module_id, w.id);
    return jsonb_build_object('result', 'owner_ok', 'message', 'Thanks — noted.');
  end if;

  return jsonb_build_object('result', 'invalid', 'message', 'This link isn''t valid.');
end;
$$;

create or replace function private.step_readiness(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  w record;
  v_probs jsonb;
  v_block boolean;
  v_days numeric;
  v_out int;
  n int := 0;
begin
  for w in select mw.* from public.module_week mw
            where mw.domain_id = p_domain and mw.status in ('Planned', 'NotReady', 'Ready') and not mw.paused
              and mw.first_class_at > p_now and mw.first_class_at - make_interval(days => private.setting_int(mw.id, 'readiness_days')) <= p_now
              and not exists (select 1 from public.booking b where b.module_week_id = mw.id and b.status = 'Active')
              and not exists (select 1 from public.request r where r.module_week_id = mw.id and r.kind = 'Outreach'
                                and r.status in ('Queued', 'Sent', 'Reminded'))
            for update skip locked loop
    v_probs := private.readiness_problems(w.id);
    v_block := exists (select 1 from jsonb_array_elements(v_probs) p where (p ->> 'blocking')::boolean);
    v_days := private.days_until(w.id, p_now);
    v_out := private.setting_int(w.id, 'outreach_days');
    update public.module_week set readiness_problems = v_probs, readiness_checked_at = p_now,
           status = case when v_block then 'NotReady' when status in ('Planned', 'NotReady') then 'Ready' else status end
     where id = w.id;
    if v_block then
      if w.status <> 'NotReady' then
        perform private.log_event('System', 'Readiness check failed', 'module_week', w.id, null, v_probs, null,
          w.domain_id, w.module_id, w.id);
      end if;
      perform private.raise_attention(p_domain, 'ReadinessFailed',
        case when v_days < v_out + 2 then 'Urgent' else 'Normal' end,
        'Readiness check failed: ' || private.mw_label(w.id),
        (select string_agg(p ->> 'text', '; ') from jsonb_array_elements(v_probs) p where (p ->> 'blocking')::boolean),
        'readiness:' || w.id, private.owners_or_leads(w.module_id), p_now, private.mw_refs(w.id), true, 'T8');
      if v_days <= v_out + 5 and w.readiness_escalated_at is null then
        perform private.queue_team_message('T13', p_domain, 'alert', null,
          private.uniq(private.owners_or_leads(w.module_id) || private.domain_role_ids(p_domain, 'Lead')),
          'Escalation: readiness still failing — ' || private.mw_label(w.id),
          '⚠️ Escalation: readiness check still failing for ' || private.mw_label(w.id) || ' and outreach starts in '
            || greatest(0, round(v_days - v_out)) || ' days. '
            || (select string_agg(p ->> 'text', '; ') from jsonb_array_elements(v_probs) p where (p ->> 'blocking')::boolean),
          'T13:readiness:' || w.id, p_now, false, null, w.id);
        update public.module_week set readiness_escalated_at = p_now where id = w.id;
      end if;
    elsif w.status in ('Planned', 'NotReady') then
      perform private.resolve_attention('readiness:' || w.id, 'Readiness check passed');
      perform private.log_event('System', 'Readiness check passed', 'module_week', w.id, null, v_probs, null,
        w.domain_id, w.module_id, w.id);
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

create or replace function private.step_outreach(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare w record; n int := 0; 
begin
  for w in select mw.* from public.module_week mw
            where mw.domain_id = p_domain and not mw.paused and mw.first_class_at > p_now
              and (mw.status = 'Ready'
                   or (mw.status = 'NeedsInstructor'
                       and exists (select 1 from private.build_line(mw.id) l where l.reason is null)))
              and (mw.first_class_at - make_interval(days => private.setting_int(mw.id, 'outreach_days')) <= p_now or mw.at_risk)
              and not exists (select 1 from public.booking b where b.module_week_id = mw.id and b.status = 'Active')
              and not exists (select 1 from public.request r where r.module_week_id = mw.id and r.kind = 'Outreach'
                                and r.status in ('Queued', 'Sent', 'Reminded'))
            order by mw.first_class_at
            for update skip locked loop
    if w.status = 'Ready' and w.readiness_checked_at is null then
      -- Created after the readiness point: run the check now (OUT-10).
      if exists (select 1 from jsonb_array_elements(private.readiness_problems(w.id)) p where (p ->> 'blocking')::boolean) then
        continue;
      end if;
    end if;
    if private.ask_next(w.id, p_now) is not null then n := n + 1; end if;
  end loop;
  return n;
end;
$$;

create or replace function private.step_requests(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  n int := 0;
  v_reason text;
  v_urgent boolean;
  v_name text;
begin
  for r in select q.*, mw.module_id, mw.first_class_at
             from public.request q join public.module_week mw on mw.id = q.module_week_id
            where mw.domain_id = p_domain and not mw.paused
              and q.kind in ('Outreach', 'TimeChange') and q.status in ('Sent', 'Reminded')
            for update of q skip locked loop
    select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
    v_urgent := private.band(r.module_week_id, p_now) = 'Short';
    if r.kind = 'Outreach' then
      v_reason := private.eligibility(r.instructor_id, r.module_week_id);
      if v_reason is not null and (v_reason in ('Inactive', 'Archived') or v_reason like 'Unavailable%') then
        perform private.withdraw_open_request(r.module_week_id, 'No longer available: ' || v_reason, p_now, true);
        perform private.ask_next(r.module_week_id, p_now);
        n := n + 1;
        continue;
      end if;
    end if;
    if r.deadline_at <= p_now then
      if r.kind = 'Outreach' then
        update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
        perform private.queue_instructor_message('M3', r.instructor_id, r.module_week_id, r.id, p_now);
        perform private.log_event('Messages', 'No reply from ' || v_name || ' — moving on', 'request', r.id, null, null,
          null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
        if private.band(r.module_week_id, p_now) <> 'Long' then
          perform private.queue_team_message('T3', p_domain, 'alert', null, private.owners_or_leads(r.module_id),
            'No reply: ' || private.mw_label(r.module_week_id),
            'No reply from ' || v_name || ' for ' || private.mw_label(r.module_week_id) || ' — asking the next instructor.',
            'T3:' || r.id, p_now, false, null, r.module_week_id);
        end if;
        perform private.ask_next(r.module_week_id, p_now);
      else
        update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
        perform private.raise_attention(p_domain, 'TimeChangeNotConfirmed',
          case when private.days_until(r.module_week_id, p_now) < private.setting_int(r.module_week_id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'New time not confirmed: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'No reply to the time-change message. The booking is kept; please check with them.',
          'timechange:' || r.module_week_id, private.recipients_for_week(r.module_week_id, true), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)), true);
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now then
      update public.request set status = 'Reminded', reminded_at = p_now where id = r.id;
      if r.kind = 'Outreach' then
        perform private.queue_instructor_message('M2', r.instructor_id, r.module_week_id, r.id, p_now,
          private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_pt(r.deadline_at)), v_urgent);
      else
        perform private.queue_instructor_message('M5', r.instructor_id, r.module_week_id, r.id, p_now,
          private.buttons(r.id, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_pt(r.deadline_at)),
          v_urgent, 'reminder');
      end if;
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

create or replace function private.step_checkins(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  b record;
  r record;
  n int := 0;
  v_days int[];
  v_last int;
  v_due int;
  v_req uuid;
  v_rem int;
  v_send timestamptz;
  v_deadline timestamptz;
  v_tpl text;
  v_urgent_band int;
  v_name text;
begin

  for b in select bk.*, mw.first_class_at, mw.module_id
             from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and not mw.paused and mw.first_class_at > p_now
            for update of bk skip locked loop
    v_days := private.checkin_days_for(b.module_week_id);
    v_last := private.last_checkin_day(b.module_week_id);
    v_urgent_band := private.setting_int(b.module_week_id, 'urgent_band_days');
    select min(d) into v_due from unnest(v_days) d
     where b.first_class_at - make_interval(days => d) <= p_now
       and b.confirmed_at < b.first_class_at - make_interval(days => d);
    continue when v_due is null;
    continue when exists (select 1 from public.request q where q.booking_id = b.id and q.kind = 'CheckIn' and q.check_in_days <= v_due);
    v_rem := case when v_due > v_urgent_band then 24 else 12 end;
    v_send := private.instructor_send_time(p_domain, p_now, v_due <= v_urgent_band);
    v_deadline := least(private.instructor_send_time(p_domain, v_send + make_interval(hours => 2 * v_rem), v_due <= v_urgent_band), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, check_in_days, status, sent_at,
      reminder_at, deadline_at, is_test, time_version)
    values (b.module_week_id, b.instructor_id, b.id, 'CheckIn', v_due, 'Sent', v_send,
      least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_rem), v_due <= v_urgent_band), v_deadline),
      v_deadline, b.is_test, (select mw.time_version from public.module_week mw where mw.id = b.module_week_id))
    returning id into v_req;
    v_tpl := case when v_due = v_last then 'M7' when v_due = 14 and v_due <> all (array(select x::int from jsonb_array_elements_text(private.get_setting(b.module_week_id, 'checkin_days')) x)) then 'M8' else 'M6' end;
    perform private.queue_instructor_message(v_tpl, b.instructor_id, b.module_week_id, v_req, p_now,
      private.buttons(v_req, case when v_tpl = 'M8' then array['AllSet', 'NeedHelp'] else array['AllSet', 'NeedHelp', 'CantMakeIt'] end),
      jsonb_build_object('days', v_due), v_due <= v_urgent_band);
    perform private.log_event('Messages', v_due || '-day check-in sent', 'request', v_req, null, null, null,
      p_domain, b.module_id, b.module_week_id, null, b.instructor_id, null, b.is_test);
    n := n + 1;
  end loop;

  for r in select q.*, mw.module_id from public.request q join public.module_week mw on mw.id = q.module_week_id
            where mw.domain_id = p_domain and q.kind = 'CheckIn' and q.status in ('Sent', 'Reminded') and not mw.paused
            for update of q skip locked loop
    select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
    v_last := private.last_checkin_day(r.module_week_id);
    v_urgent_band := private.setting_int(r.module_week_id, 'urgent_band_days');
    if r.deadline_at <= p_now then
      update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
      perform private.log_event('Messages', 'No reply to the ' || r.check_in_days || '-day check-in from ' || v_name, 'request', r.id,
        null, null, null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
      if r.check_in_days = v_last and private.setting_text(r.module_week_id, 'last_checkin_no_reply') = 'Release' then
        perform private.release_booking_flow(r.booking_id, 'NoReplyRelease', p_now);
      else
        perform private.raise_attention(p_domain, 'CheckInNoReply',
          case when r.check_in_days = v_last then 'Urgent' else 'Normal' end,
          'No reply to the ' || r.check_in_days || '-day check-in: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'The booking is kept. Please check with them.', 'checkin_noreply:' || r.id,
          private.ops_for_week(r.module_week_id), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)));
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now then
      update public.request set status = 'Reminded', reminded_at = p_now where id = r.id;
      perform private.queue_instructor_message('M9', r.instructor_id, r.module_week_id, r.id, p_now,
        private.buttons(r.id, array['AllSet', 'NeedHelp', 'CantMakeIt']), '{}', r.check_in_days <= v_urgent_band);
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

create or replace function private.step_owner_checkins(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  v_days int := private.setting_int(p_domain, 'owner_checkin_days');
  v_due uuid[];
  o uuid;
  w record;
  v_req uuid;
  v_text text;
  v_status text;
  n int := 0;
begin
  select coalesce(array_agg(mw.id), '{}') into v_due from public.module_week mw
   where mw.domain_id = p_domain and mw.status not in ('Cancelled', 'Completed') and mw.owner_checkin_sent_at is null
     and mw.first_class_at > p_now and mw.first_class_at - make_interval(days => private.setting_int(mw.id, 'owner_checkin_days')) <= p_now;
  if cardinality(v_due) = 0 then return 0; end if;

  for o in select distinct x from public.module_week mw, unnest(private.owners_or_leads(mw.module_id)) x where mw.id = any (v_due) loop
    v_text := 'Coming up in the next ' || v_days || ' days — please check these module weeks:';
    for w in select mw.* from public.module_week mw
              where mw.id = any (v_due) and o = any (private.owners_or_leads(mw.module_id))
              order by mw.first_class_at loop
      insert into public.request (module_week_id, team_member_id, kind, status, sent_at, is_test)
      values (w.id, o, 'OwnerCheckIn', 'Sent', p_now,
              private.is_test_domain(p_domain))
      on conflict (module_week_id, team_member_id) where kind = 'OwnerCheckIn' do nothing
      returning id into v_req;
      if v_req is null then
        select q.id into v_req from public.request q where q.module_week_id = w.id and q.team_member_id = o and q.kind = 'OwnerCheckIn';
      end if;
      v_status := case
        when exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Active')
          then 'Confirmed: ' || (select i.full_name from public.booking b join public.instructor i on i.id = b.instructor_id
                                  where b.module_week_id = w.id and b.status = 'Active')
        when w.status = 'Asking' then 'Asking ' || coalesce((select i.full_name from public.request q join public.instructor i on i.id = q.instructor_id
                                  where q.module_week_id = w.id and q.kind = 'Outreach' and q.status in ('Sent', 'Reminded')), 'an instructor')
        when w.status = 'NeedsInstructor' then 'Needs instructor'
        else w.status end || case when w.at_risk then ' (at risk: ' || coalesce(w.at_risk_reason, '') || ')' else '' end;
      v_text := v_text || E'\n\n• ' || private.mw_label(w.id) || ' — ' || v_status
        || E'\n  👍 All good: ' || private.link_for(v_req, 'OwnerAllGood')
        || E'\n  🙋 Need help: ' || private.link_for(v_req, 'OwnerNeedHelp');
    end loop;
    perform private.queue_team_message('T11', p_domain, 'person', o, '{}',
      'Owner check-in: your next ' || v_days || ' days', v_text,
      'T11:' || o || ':' || md5(array_to_string(array(select x::text from unnest(v_due) x order by 1), ',')), p_now, true);
    n := n + 1;
  end loop;
  update public.module_week set owner_checkin_sent_at = p_now where id = any (v_due);
  return n;
end;
$$;

create or replace function private.step_checklist(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  b record;
  n int := 0;
  v_missing text;
  v_nudge int;
  v_due int;
  v_id uuid;
begin
  for b in select bk.*, mw.first_class_at, mw.module_id from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and mw.first_class_at > p_now loop
    select string_agg(distinct ci.label, ', ') into v_missing
      from public.checklist_item ci join public.class_session c on c.id = ci.class_id
     where c.module_week_id = b.module_week_id and c.status = 'Planned' and not ci.done;
    v_nudge := private.setting_int(b.module_week_id, 'checklist_nudge_days');
    v_due := private.setting_int(b.module_week_id, 'checklist_due_days');
    if v_missing is null then
      perform private.resolve_attention('checklist:' || b.module_week_id, 'Checklist complete');
      continue;
    end if;
    if b.first_class_at - make_interval(days => v_due) <= p_now then
      v_id := private.raise_attention(p_domain, 'ChecklistOverdue', 'Urgent',
        'Checklist overdue: ' || private.mw_label(b.module_week_id), 'Not done: ' || v_missing,
        'checklist:' || b.module_week_id, private.ops_for_week(b.module_week_id), p_now, private.mw_refs(b.module_week_id), false, 'T9');
      if (select a.escalated_at from public.attention_item a where a.id = v_id) is null then
        perform private.queue_team_message('T13', p_domain, 'alert', null,
          private.uniq(private.ops_for_week(b.module_week_id) || private.domain_role_ids(p_domain, 'Lead')),
          'Escalation: checklist not done — ' || private.mw_label(b.module_week_id),
          '⚠️ Escalation: checklist must be complete ' || v_due || ' days before ' || private.mw_label(b.module_week_id) || '. Not done: ' || v_missing,
          'T13:checklist:' || b.module_week_id, p_now, false, v_id, b.module_week_id);
        update public.attention_item set escalated_at = p_now where id = v_id;
      end if;
      n := n + 1;
    elsif b.confirmed_at + make_interval(days => v_nudge) <= p_now then
      perform private.raise_attention(p_domain, 'ChecklistOverdue', 'Normal',
        'Checklist pending: ' || private.mw_label(b.module_week_id), 'Not done: ' || v_missing,
        'checklist:' || b.module_week_id, private.ops_for_week(b.module_week_id), p_now, private.mw_refs(b.module_week_id), false, 'T9');
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

create or replace function private.step_health(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  m record;
  i record;
  v_min int;
  v_weeks int := private.setting_int(p_domain, 'schedule_low_weeks');
  v_last date;
  v_cnt int;
  v_live boolean := (select d.status = 'Live' from public.domain d where d.id = p_domain);
  n int := 0;
begin
  for m in select * from public.module where domain_id = p_domain and status = 'Active' loop
    v_min := private.setting_int(m.id, 'min_active_instructors');
    select count(*) into v_cnt from public.module_ranking k join public.instructor ins on ins.id = k.instructor_id
     where k.module_id = m.id and ins.status = 'Active' and (not v_live or not ins.is_test);
    if v_cnt < v_min then
      perform private.raise_attention(p_domain, 'ThinBench', 'Normal',
        'Thin bench: ' || m.name || ' has ' || v_cnt || ' active instructor' || case when v_cnt = 1 then '' else 's' end || ' (minimum ' || v_min || ')',
        'Add instructors to the ranking.', 'thinbench:' || m.id, private.owners_or_leads(m.id), p_now,
        jsonb_build_object('module_id', m.id));
      n := n + 1;
    else
      perform private.resolve_attention('thinbench:' || m.id, 'Enough active instructors');
    end if;
  end loop;

  for i in select distinct ins.id, ins.full_name, ins.verified_at, min(k.created_at) over (partition by ins.id) as ranked_at
             from public.module_ranking k join public.module mo on mo.id = k.module_id
             join public.instructor ins on ins.id = k.instructor_id
            where mo.domain_id = p_domain and ins.status = 'Active' loop
    if i.verified_at is null and i.ranked_at + interval '2 days' <= greatest(p_now, now()) then
      perform private.raise_attention(p_domain, 'UnverifiedInRanking', 'Normal',
        'Not verified: ' || i.full_name, 'They are in a ranking but haven''t confirmed the test message. Send a test message from Instructors.',
        'unverified:' || p_domain || ':' || i.id, private.domain_role_ids(p_domain, 'Ops'), p_now,
        jsonb_build_object('instructor_id', i.id));
    elsif i.verified_at is not null then
      perform private.resolve_attention('unverified:' || p_domain || ':' || i.id, 'Verified');
    end if;
  end loop;

  select max(mw.week_start_date) into v_last from public.module_week mw where mw.domain_id = p_domain and mw.status <> 'Cancelled';
  if v_last is null or v_last < (p_now at time zone 'America/Los_Angeles')::date + v_weeks * 7 then
    perform private.raise_attention(p_domain, 'ScheduleLow', 'Normal',
      'Schedule running low: classes planned only until ' || coalesce(to_char(v_last, 'Mon FMDD, YYYY'), 'nothing planned'),
      'Plan at least ' || v_weeks || ' weeks ahead (Schedule → Plan classes).', 'schedulelow:' || p_domain,
      private.uniq(private.domain_role_ids(p_domain, 'Ops') || private.domain_role_ids(p_domain, 'Lead')), p_now);
  else
    perform private.resolve_attention('schedulelow:' || p_domain, 'Enough weeks planned');
  end if;
  return n;
end;
$$;

create or replace function public.report_message_result(p_message_id uuid, p_ok boolean, p_external_id text default null,
  p_error text default null, p_permanent boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  m public.message;
  q public.request;
  v_urgent boolean := false;
  v_now timestamptz;
begin
  perform private.require_team();
  perform private.set_actor('System', null, 'System');
  select * into m from public.message where id = p_message_id for update;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'unknown message'); end if;
  v_now := case when m.domain_id is not null then private.domain_now(m.domain_id) else now() end;
  if p_ok then
    update public.message set status = 'Sent', sent_at = now(), external_id = p_external_id, last_error = null where id = m.id;
    perform private.log_event('Messages', m.template_id || ' sent to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
      'message', m.id, null, null, null, m.domain_id, null, m.module_week_id, null, m.instructor_id, null, m.is_test);
    return jsonb_build_object('ok', true, 'status', 'Sent');
  end if;
  if m.attempts < 3 and not p_permanent then
    update public.message set status = 'Pending', last_error = p_error where id = m.id;
    return jsonb_build_object('ok', true, 'status', 'Retry');
  end if;
  update public.message set status = 'Failed', last_error = p_error where id = m.id;
  if m.instructor_id is not null and m.channel = 'Discord' and not m.is_test then
    update public.instructor set discord_failed_at = now() where id = m.instructor_id;
  end if;
  if m.request_id is not null then
    select * into q from public.request where id = m.request_id;
    v_urgent := q.kind in ('Outreach', 'CheckIn', 'TimeChange') and q.status in ('Sent', 'Reminded')
                and private.days_until(q.module_week_id, v_now) < private.setting_int(q.module_week_id, 'short_notice_days');
  end if;
  perform private.log_event('Messages', m.template_id || ' failed to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
    'message', m.id, null, null, p_error, m.domain_id, null, m.module_week_id, null, m.instructor_id, null, m.is_test);
  if m.audience <> 'Admin' then
    perform private.raise_attention(m.domain_id, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
      'Message failed: ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
      coalesce(p_error, 'Unknown error') || case when m.channel = 'Discord' then ' (email is still sent)' else ' (Discord is still used)' end,
      'msgfail:' || m.id,
      coalesce(nullif(private.domain_role_ids(m.domain_id, 'Ops'), '{}'),
               private.all_operations_ids()),
      v_now, jsonb_build_object('module_week_id', m.module_week_id, 'instructor_id', m.instructor_id, 'message_id', m.id), true, 'T14');
    perform private.queue_team_message('T14', m.domain_id, 'admin', null, '{}', 'Message failed',
      '❗ ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel || ' failed: ' || coalesce(p_error, '?'),
      'T14:' || m.id, now());
  end if;
  return jsonb_build_object('ok', true, 'status', 'Failed');
end;
$$;

create or replace function public.record_inbound_message(p_channel text, p_from text, p_subject text, p_body text,
  p_external_id text, p_received_at timestamptz default null, p_summary text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_key text := 'in:' || p_channel || ':' || coalesce(p_external_id, md5(coalesce(p_from, '') || coalesce(p_body, '')));
  i public.instructor;
  q public.request;
  h public.help_request;
  v_mw uuid;
  v_dom uuid;
  v_msg uuid;
  v_now timestamptz;
  v_sev text := 'Normal';
begin
  perform private.require_team();
  if exists (select 1 from public.message where unique_key = v_key) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  if p_channel = 'Email' then
    select ins.* into i from public.instructor_email e join public.instructor ins on ins.id = e.instructor_id
     where lower(e.email) = lower(trim(regexp_replace(coalesce(p_from, ''), '^.*<([^>]+)>.*$', '\1')));
  else
    select * into i from public.instructor where discord_user_id = p_from;
  end if;
  if i.id is not null then
    perform private.set_actor('Instructor', i.id, i.full_name);
    select * into q from public.request
     where instructor_id = i.id and status in ('Sent', 'Reminded') order by created_at desc limit 1;
    v_mw := coalesce(q.module_week_id,
      (select b.module_week_id from public.booking b join public.module_week w on w.id = b.module_week_id
        where b.instructor_id = i.id and b.status = 'Active' order by w.first_class_at limit 1));
    v_dom := (select w.domain_id from public.module_week w where w.id = v_mw);
  end if;
  v_now := case when v_dom is not null then private.domain_now(v_dom) else now() end;
  insert into public.message (domain_id, direction, audience, template_id, channel, unique_key, status, instructor_id,
    module_week_id, request_id, from_address, subject, body_text, summary, external_id, recipient_label)
  values (v_dom, 'Inbound', 'Instructor', 'IN', p_channel, v_key, 'Received', i.id, v_mw, q.id, p_from, p_subject,
    left(p_body, 5000), p_summary, p_external_id, coalesce(i.full_name, p_from))
  returning id into v_msg;

  if i.id is null then
    perform private.raise_attention(null, 'TypedReply', 'Normal', 'Message from an unknown sender: ' || coalesce(p_from, '?'),
      coalesce(p_summary, left(p_body, 300)), 'typed:' || v_msg,
      private.all_operations_ids(), v_now,
      jsonb_build_object('message_id', v_msg));
    return jsonb_build_object('ok', true, 'matched', false);
  end if;
  update public.instructor set last_response_at = v_now where id = i.id;

  select * into h from public.help_request
   where requester_instructor_id = i.id and merged_into is null and status in ('Open', 'InProgress', 'WaitingOnInstructor')
   order by raised_at desc limit 1;
  if h.id is not null then
    update public.message set help_request_id = h.id where id = v_msg;
    update public.help_request set status = 'Open' where id = h.id and status = 'WaitingOnInstructor';
    update public.attention_item set status = 'Open', detail = coalesce(detail, '') || E'\nFollow-up: ' || coalesce(p_summary, left(p_body, 300))
     where dedupe_key = 'help:' || h.id and status <> 'Done';
    perform private.log_event('Help requests', 'Follow-up from ' || i.full_name, 'help_request', h.id, null, null,
      left(p_body, 500), h.domain_id, null, h.module_week_id, null, i.id);
    return jsonb_build_object('ok', true, 'matched', true, 'attached_to_help', h.id);
  end if;

  if v_mw is not null and private.days_until(v_mw, v_now) < private.setting_int(v_mw, 'short_notice_days') then
    v_sev := 'Urgent';
  end if;
  perform private.raise_attention(v_dom, 'TypedReply', v_sev,
    'Typed reply from ' || i.full_name || coalesce(' — ' || private.mw_label(v_mw), ''),
    coalesce('Summary: ' || p_summary || E'\n', '') || left(coalesce(p_body, ''), 500)
      || E'\nNothing was changed automatically. Read it and decide.',
    'typed:' || v_msg, coalesce(nullif(private.domain_role_ids(v_dom, 'Ops'), '{}'),
      private.all_operations_ids()), v_now,
    coalesce(private.mw_refs(v_mw, jsonb_build_object('instructor_id', i.id, 'request_id', q.id, 'message_id', v_msg)),
             jsonb_build_object('instructor_id', i.id, 'message_id', v_msg)));
  perform private.log_event('Instructor responses', 'Typed reply from ' || i.full_name, 'message', v_msg, null, null,
    left(p_body, 500), v_dom, null, v_mw, null, i.id);
  return jsonb_build_object('ok', true, 'matched', true);
end;
$$;

create or replace function public.record_bounce(p_email text, p_external_id text default null, p_detail text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  q record;
  v_urgent boolean := false;
  v_dom uuid;
begin
  perform private.require_team();
  perform private.set_actor('System', null, 'System');
  select ins.* into i from public.instructor_email e join public.instructor ins on ins.id = e.instructor_id
   where lower(e.email) = lower(trim(p_email));
  if i.id is null then
    return jsonb_build_object('ok', true, 'matched', false);
  end if;
  update public.instructor set email_bounced_at = now() where id = i.id;
  select r.*, w.domain_id as dom into q from public.request r join public.module_week w on w.id = r.module_week_id
   where r.instructor_id = i.id and r.status in ('Sent', 'Reminded') order by r.created_at desc limit 1;
  v_dom := q.dom;
  if q.id is not null then
    v_urgent := private.days_until(q.module_week_id, private.domain_now(v_dom)) < private.setting_int(q.module_week_id, 'short_notice_days');
  end if;
  perform private.raise_attention(v_dom, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
    'Email bounced: ' || i.full_name || ' (' || p_email || ')',
    coalesce(p_detail, 'The email address may be wrong.') || ' Discord is still used. Fix the email in Instructors.',
    'bounce:' || i.id, coalesce(nullif(private.domain_role_ids(v_dom, 'Ops'), '{}'),
      private.all_operations_ids()),
    coalesce(private.domain_now(v_dom), now()), jsonb_build_object('instructor_id', i.id), true, 'T14');
  perform private.log_event('Messages', 'Email bounced: ' || i.full_name, 'instructor', i.id, null, null, p_detail,
    v_dom, null, null, null, i.id);
  return jsonb_build_object('ok', true, 'matched', true);
end;
$$;


-- Check-in days for a class week (sorted, plus 14 when the extra check-in is on), and the last one.
create or replace function private.checkin_days_for(p_mw uuid)
returns int[] language sql stable security definer set search_path = ''
as $$
  select array(select distinct d from (
      select x::int as d from jsonb_array_elements_text(private.get_setting(p_mw, 'checkin_days')) x
      union all select 14 where private.setting_bool(p_mw, 'checkin_14_enabled')) y order by d);
$$;

create or replace function private.last_checkin_day(p_mw uuid)
returns int language sql stable security definer set search_path = ''
as $$ select min(x::int) from jsonb_array_elements_text(private.get_setting(p_mw, 'checkin_days')) x; $$;

