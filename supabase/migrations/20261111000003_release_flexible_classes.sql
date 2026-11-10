-- Release Milestone 2, part 3: flexible classes. Planning on any day with cohort patterns,
-- "same instructor for the whole class week" (split and merge), "Add one class", and warnings
-- (unusual but allowed; accepted with an optional reason that goes into Activity history).

-- -------------------------------------------------------------------------------------
-- A class week starts on the date of its first class (kept in step with its classes)
-- -------------------------------------------------------------------------------------
create or replace function private.refresh_module_week_times(p_mw uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.module_week w
     set first_class_at = s.first_at,
         last_class_end_at = s.last_end
    from (select min(c.starts_at) filter (where c.status <> 'Cancelled') as first_at,
                 max(c.ends_at) filter (where c.status <> 'Cancelled') as last_end
            from public.class_session c where c.module_week_id = p_mw) s
   where w.id = p_mw
     and (w.first_class_at is distinct from s.first_at or w.last_class_end_at is distinct from s.last_end);
  update public.module_week w
     set week_start_date = (w.first_class_at at time zone 'America/Los_Angeles')::date
   where w.id = p_mw and w.first_class_at is not null
     and w.week_start_date <> (w.first_class_at at time zone 'America/Los_Angeles')::date
     and not exists (select 1 from public.module_week x
                      where x.module_id = w.module_id and x.cohort_id = w.cohort_id and x.seq = w.seq and x.id <> w.id
                        and x.week_start_date = (w.first_class_at at time zone 'America/Los_Angeles')::date);
$$;

-- -------------------------------------------------------------------------------------
-- Warnings: unusual but allowed
-- -------------------------------------------------------------------------------------
-- For one class (Pacific date and times): holiday, before 6 AM or after 10 PM, overlap with another
-- planned class of the same cohort, short notice. Returns [{code, text}].
create or replace function private.class_warnings(p_domain uuid, p_cohort uuid, p_start timestamptz, p_end timestamptz,
  p_exclude_week uuid default null, p_label text default null)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with t as (
    select (p_start at time zone 'America/Los_Angeles') as s, (p_end at time zone 'America/Los_Angeles') as e,
           coalesce(p_label || ' on ', '') || private.fmt_pt_range(p_start, p_end) as what)
  select coalesce(jsonb_agg(x.w), '[]') from (
    select jsonb_build_object('code', 'holiday', 'text', t.what || ' is on a holiday (' || h.name || ').') as w
      from t join public.holiday h on h.date = t.s::date
    union all
    select jsonb_build_object('code', 'unusual_hours', 'text', t.what || ' is outside 6 AM to 10 PM Pacific.')
      from t where t.s::time < '06:00' or t.e::time > '22:00' or t.e::date > t.s::date
    union all
    select jsonb_build_object('code', 'cohort_overlap', 'text',
             t.what || ' overlaps ' || c.title || ' (' || private.fmt_pt_range(c.starts_at, c.ends_at) || ') in the same cohort.')
      from t, public.class_session c join public.module_week w on w.id = c.module_week_id
     where p_cohort is not null and w.cohort_id = p_cohort and c.status = 'Planned'
       and (p_exclude_week is null or w.id <> p_exclude_week)
       and tstzrange(c.starts_at, c.ends_at, '[)') && tstzrange(p_start, p_end, '[)')
    union all
    select jsonb_build_object('code', 'short_notice', 'text',
             t.what || ' is only ' || greatest(0, floor(extract(epoch from (p_start - private.domain_now(p_domain))) / 86400))::int
             || ' days away, so instructors are asked straight away with short reply times.')
      from t where p_start - private.domain_now(p_domain) < make_interval(days => private.setting_int(p_domain, 'outreach_days'))
                and p_start > private.domain_now(p_domain)
  ) x;
$$;

-- An instructor over their preferred monthly class limit in the month of this class week (warning only).
create or replace function private.instructor_soft_warning(p_instructor uuid, p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select 'Over their preferred limit of ' || i.monthly_class_limit || ' classes a month.'
    from public.instructor i, public.module_week w
   where i.id = p_instructor and w.id = p_mw and i.monthly_class_limit is not null
     and (select count(*) from public.booking_slot s join public.class_session c on c.id = s.class_id
           where s.instructor_id = i.id and s.active and c.status <> 'Cancelled'
             and date_trunc('month', c.starts_at at time zone 'America/Los_Angeles')
               = date_trunc('month', w.first_class_at at time zone 'America/Los_Angeles'))
         + (select count(*) from public.class_session c where c.module_week_id = w.id and c.status = 'Planned')
         > i.monthly_class_limit;
$$;

-- Record warnings the user accepted (with their reason) in Activity history.
create or replace function private.log_accepted_warnings(p_warnings jsonb, p_reason text, p_domain uuid,
  p_module uuid default null, p_mw uuid default null, p_class uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(jsonb_array_length(p_warnings), 0) = 0 then return; end if;
  perform private.log_event('Team actions', 'Warnings accepted', 'domain', p_domain, null,
    jsonb_build_object('warnings', p_warnings), nullif(trim(coalesce(p_reason, '')), ''), p_domain, p_module, p_mw, p_class);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Cohorts
-- -------------------------------------------------------------------------------------
create or replace function private.cohort_by_name(p_domain uuid, p_name text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v uuid; v_name text := coalesce(nullif(trim(p_name), ''), 'Main cohort');
begin
  select id into v from public.cohort where domain_id = p_domain and lower(name) = lower(v_name);
  if v is null then
    insert into public.cohort (domain_id, name) values (p_domain, v_name) returning id into v;
  end if;
  return v;
end;
$$;

-- A suggested name for a new cohort: "<Mon YYYY> cohort", made unique.
create or replace function public.suggest_cohort_name(p_domain_id uuid, p_first_date date)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare v_base text := to_char(coalesce(p_first_date, current_date), 'FMMonth YYYY') || ' cohort'; v text := v_base; n int := 1;
begin
  perform private.require_team();
  while exists (select 1 from public.cohort where domain_id = p_domain_id and lower(name) = lower(v)) loop
    n := n + 1; v := v_base || ' ' || n;
  end loop;
  return v;
end;
$$;

-- Class times for a module in a cohort: the cohort's own pattern when it has one, else the module's.
create or replace function private.pattern_for(p_module uuid, p_cohort uuid)
returns setof public.class_pattern_item language sql stable security definer set search_path = ''
as $$
  select p.* from public.class_pattern_item p
   where p.module_id = p_module
     and p.cohort_id is not distinct from (
       case when p_cohort is not null and exists (select 1 from public.class_pattern_item x where x.module_id = p_module and x.cohort_id = p_cohort)
            then p_cohort end)
   order by p.day_offset, p.start_time_pt, p.sort_order;
$$;

-- -------------------------------------------------------------------------------------
-- Planning on any day
-- -------------------------------------------------------------------------------------
-- p_week_starts: the date of the first class of each class week (any weekday). Modules rotate from
-- p_start_module_id. Each row lists its classes, warnings, and a problem when it cannot be planned.
create or replace function public.generate_classes(p_domain_id uuid, p_start_module_id uuid, p_week_starts date[], p_cohort text default '')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_mods uuid[];
  v_start int;
  v_out jsonb := '[]';
  i int;
  v_mod uuid;
  m public.module;
  v_d date;
  v_cohort uuid;
  v_min int;
  v_classes jsonb;
  v_warn jsonb;
  p record;
  v_s timestamptz;
  v_e timestamptz;
begin
  perform private.require_team();
  select array_agg(id order by rotation_order, name) into v_mods from public.module where domain_id = p_domain_id and status = 'Active';
  if v_mods is null then raise exception 'This domain has no active modules yet.'; end if;
  v_start := coalesce(array_position(v_mods, p_start_module_id), 1);
  select id into v_cohort from public.cohort where domain_id = p_domain_id and lower(name) = lower(coalesce(nullif(trim(p_cohort), ''), 'Main cohort'));
  for i in 1 .. coalesce(cardinality(p_week_starts), 0) loop
    v_d := p_week_starts[i];
    v_mod := v_mods[((v_start - 1 + i - 1) % cardinality(v_mods)) + 1];
    select * into m from public.module where id = v_mod;
    select min(day_offset) into v_min from private.pattern_for(v_mod, v_cohort);
    v_classes := '[]';
    v_warn := '[]';
    for p in select * from private.pattern_for(v_mod, v_cohort) loop
      v_s := private.pt_to_utc(v_d + (p.day_offset - v_min), p.start_time_pt);
      v_e := v_s + make_interval(mins => p.duration_minutes);
      v_classes := v_classes || jsonb_build_object(
        'pattern_item_id', p.id, 'class_type', p.class_type,
        'title', replace(replace(p.title_template, '{module}', m.name), '{class_type}', p.class_type),
        'date', v_d + (p.day_offset - v_min), 'start_time', to_char(p.start_time_pt, 'HH24:MI'),
        'end_time', to_char(p.start_time_pt + make_interval(mins => p.duration_minutes), 'HH24:MI'),
        'starts_at', v_s, 'ends_at', v_e, 'shown', private.fmt_pt_range(v_s, v_e),
        'holiday', (select h.name from public.holiday h where h.date = v_d + (p.day_offset - v_min)));
      v_warn := v_warn || private.class_warnings(p_domain_id, v_cohort, v_s, v_e, null,
        replace(replace(p.title_template, '{module}', m.name), '{class_type}', p.class_type));
    end loop;
    v_out := v_out || jsonb_build_object('week_start_date', v_d, 'module_id', v_mod, 'module_name', m.name,
      'cohort', coalesce(nullif(trim(p_cohort), ''), 'Main cohort'), 'same_instructor', m.same_instructor_for_module_week,
      'classes', v_classes, 'warnings', v_warn,
      'problem', case when jsonb_array_length(v_classes) = 0
                      then m.name || ' has no class times yet. Add them on the module page before planning.' end,
      'duplicate', v_cohort is not null and exists (select 1 from public.module_week w where w.module_id = v_mod and w.cohort_id = v_cohort
                                                      and w.week_start_date = v_d and w.status <> 'Cancelled'),
      'holidays', (select coalesce(jsonb_agg(h.name), '[]') from public.holiday h where h.date between v_d and v_d + 6));
  end loop;
  return v_out;
end;
$$;

-- Save reviewed class weeks.
-- p_rows: [{module_id, cohort | cohort_id, classes: [{class_type, title, date, start_time, end_time, pattern_item_id}]}]
-- Blocks (nothing is saved): module of another domain, no classes, a class that ends before it starts,
-- a class week that already exists. Warnings (holiday, unusual hours, overlap in the cohort, short
-- notice) come back as {ok: false, needs_confirmation: true, warnings: [...]} unless p_accept_warnings.
drop function public.create_module_weeks(uuid, jsonb);
create or replace function public.create_module_weeks(p_domain_id uuid, p_rows jsonb, p_accept_warnings boolean default false,
  p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  c jsonb;
  m public.module;
  v_mw uuid;
  v_group uuid;
  v_cohort uuid;
  v_ids uuid[] := '{}';
  v_problems text[] := '{}';
  v_warn jsonb := '[]';
  v_start timestamptz;
  v_end timestamptz;
  v_first date;
  v_seq int;
  v_batch jsonb := '[]';
  v_mode text := private.setting_text(p_domain_id, 'default_outreach_mode');
  v_end_b text := private.setting_text(p_domain_id, 'manual_end_behaviour');
begin
  perform private.require_team();
  -- Checks first: nothing is saved when anything is blocked or warnings need confirming.
  for r in select * from jsonb_array_elements(p_rows) loop
    select * into m from public.module where id = (r ->> 'module_id')::uuid;
    if m.domain_id is distinct from p_domain_id then
      v_problems := v_problems || 'A module does not belong to this domain.'::text;
      continue;
    end if;
    if jsonb_array_length(coalesce(r -> 'classes', '[]')) = 0 then
      v_problems := v_problems || (m.name || ' has no classes in this plan. Add class times on the module page first.');
      continue;
    end if;
    v_cohort := coalesce((r ->> 'cohort_id')::uuid,
                         (select id from public.cohort where domain_id = p_domain_id and lower(name) = lower(coalesce(nullif(trim(r ->> 'cohort'), ''), 'Main cohort'))));
    select min((x ->> 'date')::date) into v_first from jsonb_array_elements(r -> 'classes') x;
    if v_cohort is not null and m.same_instructor_for_module_week and exists (
         select 1 from public.module_week w where w.module_id = m.id and w.cohort_id = v_cohort and w.week_start_date = v_first
                                              and w.status <> 'Cancelled') then
      v_problems := v_problems || ('Already planned: ' || m.name || ' starting ' || to_char(v_first, 'Dy, Mon FMDD, YYYY')
        || ' in ' || (select name from public.cohort where id = v_cohort) || '.');
    end if;
    for c in select * from jsonb_array_elements(r -> 'classes') loop
      v_start := private.pt_to_utc((c ->> 'date')::date, (c ->> 'start_time')::time);
      v_end := private.pt_to_utc((c ->> 'date')::date + case when (c ->> 'end_time')::time <= (c ->> 'start_time')::time then 1 else 0 end,
                                 (c ->> 'end_time')::time);
      if (c ->> 'end_time')::time = (c ->> 'start_time')::time then
        v_problems := v_problems || (coalesce(c ->> 'title', 'A class') || ' must end after it starts.');
      end if;
      v_warn := v_warn || private.class_warnings(p_domain_id, v_cohort, v_start, v_end, null, c ->> 'title');
      -- Overlaps inside this plan (same cohort).
      if exists (select 1 from jsonb_array_elements(v_batch) b
                  where (b ->> 'cohort') = coalesce(v_cohort::text, lower(coalesce(r ->> 'cohort', '')))
                    and tstzrange((b ->> 's')::timestamptz, (b ->> 'e')::timestamptz, '[)') && tstzrange(v_start, v_end, '[)')) then
        v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'cohort_overlap',
          'text', coalesce(c ->> 'title', 'A class') || ' on ' || private.fmt_pt_range(v_start, v_end) || ' overlaps another class in this plan for the same cohort.'));
      end if;
      v_batch := v_batch || jsonb_build_object('cohort', coalesce(v_cohort::text, lower(coalesce(r ->> 'cohort', ''))), 's', v_start, 'e', v_end);
    end loop;
  end loop;
  if cardinality(v_problems) > 0 then
    raise exception '%', array_to_string(v_problems, E'\n') using errcode = '23505';
  end if;
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    select * into m from public.module where id = (r ->> 'module_id')::uuid;
    v_cohort := coalesce((r ->> 'cohort_id')::uuid, private.cohort_by_name(p_domain_id, r ->> 'cohort'));
    v_mw := null;
    v_group := null;
    for c in select * from jsonb_array_elements(r -> 'classes') x order by (x ->> 'date')::date, (x ->> 'start_time')::time loop
      v_start := private.pt_to_utc((c ->> 'date')::date, (c ->> 'start_time')::time);
      v_end := private.pt_to_utc((c ->> 'date')::date + case when (c ->> 'end_time')::time <= (c ->> 'start_time')::time then 1 else 0 end,
                                 (c ->> 'end_time')::time);
      if v_mw is null or not m.same_instructor_for_module_week then
        select coalesce(max(seq), 0) + 1 into v_seq from public.module_week
         where module_id = m.id and cohort_id = v_cohort and week_start_date = (c ->> 'date')::date;
        insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour,
                                        same_instructor, split_group)
        values (m.id, v_cohort, (c ->> 'date')::date, v_seq, v_mode, v_end_b, m.same_instructor_for_module_week, v_group)
        returning id into v_mw;
        if not m.same_instructor_for_module_week then
          v_group := coalesce(v_group, v_mw);
          update public.module_week set split_group = v_group where id = v_mw;
        end if;
        v_ids := v_ids || v_mw;
      end if;
      insert into public.class_session (module_week_id, pattern_item_id, class_type, title, starts_at, ends_at)
      values (v_mw, nullif(c ->> 'pattern_item_id', '')::uuid, coalesce(nullif(c ->> 'class_type', ''), 'Other'),
              coalesce(nullif(c ->> 'title', ''), 'Class'), v_start, v_end);
    end loop;
  end loop;
  perform private.log_accepted_warnings(v_warn, p_reason, p_domain_id);
  perform private.log_event('Team actions', 'Planned ' || cardinality(v_ids) || ' class week(s)', 'domain', p_domain_id,
    null, jsonb_build_object('module_week_ids', to_jsonb(v_ids)), nullif(trim(coalesce(p_reason, '')), ''), p_domain_id);
  return jsonb_build_object('ok', true, 'created', cardinality(v_ids), 'module_week_ids', to_jsonb(v_ids), 'warnings', v_warn);
end;
$$;
grant execute on function public.create_module_weeks(uuid, jsonb, boolean, text) to authenticated;
revoke execute on function public.create_module_weeks(uuid, jsonb, boolean, text) from anon;
grant execute on function public.suggest_cohort_name(uuid, date) to authenticated;
revoke execute on function public.suggest_cohort_name(uuid, date) from anon;

-- -------------------------------------------------------------------------------------
-- Add one class (extra, makeup or moved), with the same checks
-- -------------------------------------------------------------------------------------
-- Into an existing class week (when its classes share one instructor), or as a new class week of a
-- module and cohort. A confirmed instructor is asked to confirm the new time, like any time change.
create or replace function public.add_one_class(p_module_week_id uuid, p_module_id uuid, p_cohort_id uuid,
  p_date date, p_start time, p_end time, p_class_type text, p_title text default null,
  p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  m public.module;
  v_cohort uuid := p_cohort_id;
  v_start timestamptz;
  v_end timestamptz;
  v_warn jsonb;
  v_class uuid;
  v_booking public.booking;
  v_clash boolean := false;
  v_title text;
  v_seq int;
  v jsonb := '{}';
begin
  perform private.require_team();
  if p_module_week_id is not null then
    select * into w from public.module_week where id = p_module_week_id;
    if w.status in ('Cancelled', 'Completed') then raise exception 'This class week is already finished or cancelled.' using errcode = '22023'; end if;
    select * into m from public.module where id = w.module_id;
    v_cohort := w.cohort_id;
  else
    select * into m from public.module where id = p_module_id;
    if m.id is null then raise exception 'Choose a module.' using errcode = '22023'; end if;
    if v_cohort is null then raise exception 'Choose a cohort.' using errcode = '22023'; end if;
    if (select domain_id from public.cohort where id = v_cohort) <> m.domain_id then
      raise exception 'The cohort belongs to another domain.' using errcode = '22023';
    end if;
  end if;
  if p_start is null or p_end is null or p_date is null then raise exception 'Choose a date, a start time and an end time.' using errcode = '22023'; end if;
  if p_end = p_start then raise exception 'The class must end after it starts.' using errcode = '22023'; end if;
  if coalesce(trim(p_class_type), '') = '' then raise exception 'Choose a class type.' using errcode = '22023'; end if;
  v_start := private.pt_to_utc(p_date, p_start);
  v_end := private.pt_to_utc(p_date + case when p_end <= p_start then 1 else 0 end, p_end);
  v_title := coalesce(nullif(trim(p_title), ''), m.name || ': ' || trim(p_class_type));
  v_warn := private.class_warnings(m.domain_id, v_cohort, v_start, v_end, null, v_title);
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;

  if w.id is null or not w.same_instructor then
    select coalesce(max(seq), 0) + 1 into v_seq from public.module_week where module_id = m.id and cohort_id = v_cohort and week_start_date = p_date;
    insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour, same_instructor)
    values (m.id, v_cohort, p_date, v_seq, private.setting_text(m.id, 'default_outreach_mode'),
            private.setting_text(m.id, 'manual_end_behaviour'), coalesce(w.same_instructor, m.same_instructor_for_module_week))
    returning * into w;
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at)
    values (w.id, trim(p_class_type), v_title, v_start, v_end) returning id into v_class;
    v := jsonb_build_object('new_class_week', true);
  else
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at)
    values (w.id, trim(p_class_type), v_title, v_start, v_end) returning id into v_class;
    select * into v_booking from public.booking where module_week_id = w.id and status = 'Active';
    if v_booking.id is not null then
      begin
        insert into public.booking_slot (booking_id, class_id, instructor_id, time_range)
        values (v_booking.id, v_class, v_booking.instructor_id, tstzrange(v_start, v_end, '[)'));
      exception when exclusion_violation then
        v_clash := true;
      end;
    end if;
    v := private.week_times_changed(w.id, private.mw_now(w.id), v_clash);
  end if;
  perform private.log_event('Team actions', 'Class added', 'class_session', v_class, null,
    jsonb_build_object('title', v_title, 'shown', private.fmt_pt_range(v_start, v_end)), nullif(trim(coalesce(p_reason, '')), ''),
    m.domain_id, m.id, w.id, v_class);
  perform private.log_accepted_warnings(v_warn, p_reason, m.domain_id, m.id, w.id, v_class);
  perform private.queue_deliver('class added');
  return jsonb_build_object('ok', true, 'class_id', v_class, 'module_week_id', w.id, 'warnings', v_warn) || v;
end;
$$;
grant execute on function public.add_one_class(uuid, uuid, uuid, date, time, time, text, text, boolean, text) to authenticated;
revoke execute on function public.add_one_class(uuid, uuid, uuid, date, time, time, text, text, boolean, text) from anon;

-- -------------------------------------------------------------------------------------
-- "Same instructor for the whole class week" for a single class week
-- -------------------------------------------------------------------------------------
-- Off: every class becomes its own class week (own request, own instructor). On: class weeks that
-- were split from the same week are merged back. Only while nobody is confirmed or being asked.
create or replace function public.set_week_same_instructor(p_module_week_id uuid, p_on boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  c record;
  v_new uuid;
  v_group uuid;
  v_weeks uuid[];
  n int := 0;
  v_seq int;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.id is null then raise exception 'Class week not found.' using errcode = '22023'; end if;
  v_group := coalesce(w.split_group, w.id);
  v_weeks := case when p_on then array(select id from public.module_week where split_group = v_group order by first_class_at)
                  else array[w.id] end;
  if exists (select 1 from public.booking b where b.module_week_id = any (v_weeks) and b.status = 'Active')
     or exists (select 1 from public.request r where r.module_week_id = any (v_weeks) and r.kind = 'Outreach'
                   and r.status in ('Queued', 'Sent', 'Reminded')) then
    raise exception 'Someone is confirmed or being asked for this class week. Release them or pause requests first.' using errcode = '22023';
  end if;

  if not p_on then
    if not w.same_instructor then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update public.module_week set same_instructor = false, split_group = v_group where id = w.id;
    for c in select * from public.class_session where module_week_id = w.id and status = 'Planned' order by starts_at offset 1 loop
      select coalesce(max(seq), 0) + 1 into v_seq from public.module_week
       where module_id = w.module_id and cohort_id = w.cohort_id and week_start_date = (c.starts_at at time zone 'America/Los_Angeles')::date;
      insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour, paused,
                                      same_instructor, split_group, status)
      values (w.module_id, w.cohort_id, (c.starts_at at time zone 'America/Los_Angeles')::date, v_seq, w.outreach_mode,
              w.manual_end_behaviour, w.paused, false, v_group,
              case when w.status in ('Planned', 'NotReady', 'Ready') then w.status else 'Planned' end)
      returning id into v_new;
      update public.class_session set module_week_id = v_new where id = c.id;
      n := n + 1;
    end loop;
  else
    if w.same_instructor and coalesce(array_length(v_weeks, 1), 0) <= 1 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update public.class_session set module_week_id = v_weeks[1] where module_week_id = any (v_weeks[2:]);
    update public.module_week set status = 'Cancelled', same_instructor = true where id = any (v_weeks[2:]);
    delete from public.module_week x where x.id = any (v_weeks[2:])
       and not exists (select 1 from public.request r where r.module_week_id = x.id)
       and not exists (select 1 from public.booking b where b.module_week_id = x.id)
       and not exists (select 1 from public.help_request h where h.module_week_id = x.id)
       and not exists (select 1 from public.attention_item a where a.module_week_id = x.id)
       and not exists (select 1 from public.message g where g.module_week_id = x.id)
       and not exists (select 1 from public.manual_queue_item q where q.module_week_id = x.id);
    update public.module_week set same_instructor = true, split_group = null where id = v_weeks[1];
    n := coalesce(array_length(v_weeks, 1), 1) - 1;
    w.id := v_weeks[1];
  end if;
  perform private.log_event('Team actions', case when p_on then 'Same instructor turned on for the class week'
                                                 else 'Same instructor turned off for the class week' end,
    'module_week', w.id, null, jsonb_build_object('class_weeks_changed', n), nullif(trim(coalesce(p_reason, '')), ''),
    w.domain_id, w.module_id, w.id);
  return jsonb_build_object('ok', true, 'changed', n, 'module_week_id', w.id);
end;
$$;
grant execute on function public.set_week_same_instructor(uuid, boolean, text) to authenticated;
revoke execute on function public.set_week_same_instructor(uuid, boolean, text) from anon;


create or replace function public.shift_classes(p_module_week_id uuid, p_weeks int, p_include_later boolean default true)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w0 public.module_week;
  w record;
  c record;
  n int := 0;
  v_now timestamptz;
  v_msg text;
  v_clash boolean;
begin
  perform private.require_team();
  if p_weeks = 0 or abs(p_weeks) > 26 then raise exception 'Shift by 1 to 26 weeks.'; end if;
  select * into w0 from public.module_week where id = p_module_week_id;
  v_now := private.domain_now(w0.domain_id);
  -- Refuse (in plain words) a shift that would land on a week the same module already has.
  select m.name || ' already has a week starting ' || to_char(t.week_start_date, 'Mon FMDD, YYYY')
    into v_msg
    from public.module_week mw
    join public.module_week t on t.module_id = mw.module_id and t.cohort_id = mw.cohort_id and t.seq = mw.seq
                             and t.week_start_date = mw.week_start_date + 7 * p_weeks
    join public.module m on m.id = mw.module_id
   where mw.domain_id = w0.domain_id and mw.cohort_id = w0.cohort_id and mw.status not in ('Completed', 'Cancelled')
     and (mw.id = w0.id or (p_include_later and mw.week_start_date > w0.week_start_date))
     and not (t.id = w0.id or (p_include_later and t.week_start_date > w0.week_start_date and t.status not in ('Completed', 'Cancelled')))
   limit 1;
  if v_msg is not null then
    raise exception 'Can''t shift: %. Move or cancel that week first, or shift all later weeks too.', v_msg;
  end if;
  for w in select mw.* from public.module_week mw
            where mw.domain_id = w0.domain_id and mw.cohort_id = w0.cohort_id and mw.status not in ('Completed', 'Cancelled')
              and (mw.id = w0.id or (p_include_later and mw.week_start_date > w0.week_start_date))
            order by case when p_weeks > 0 then mw.week_start_date end desc, case when p_weeks < 0 then mw.week_start_date end asc loop
    update public.module_week set week_start_date = week_start_date + 7 * p_weeks where id = w.id;
    v_clash := false;
    -- Move every class of the week first (latest first when moving forward), then recalculate once,
    -- so the instructor gets one message with the final times.
    for c in select * from public.class_session where module_week_id = w.id and status = 'Planned'
              order by case when p_weeks > 0 then starts_at end desc, case when p_weeks < 0 then starts_at end asc loop
      -- keep the same Pacific wall-clock time across daylight saving changes
      v_clash := private.move_class(c.id,
        private.pt_to_utc((c.starts_at at time zone 'America/Los_Angeles')::date + 7 * p_weeks, (c.starts_at at time zone 'America/Los_Angeles')::time),
        private.pt_to_utc((c.ends_at at time zone 'America/Los_Angeles')::date + 7 * p_weeks, (c.ends_at at time zone 'America/Los_Angeles')::time))
        or v_clash;
    end loop;
    perform private.week_times_changed(w.id, v_now, v_clash);
    n := n + 1;
  end loop;
  perform private.log_event('Team actions', 'Shifted ' || n || ' module week(s) by ' || p_weeks || ' week(s)', 'module_week',
    p_module_week_id, null, null, null, w0.domain_id, w0.module_id, w0.id);
  perform private.queue_deliver('shift');
  return jsonb_build_object('ok', true, 'weeks_shifted', n);
end;
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
      warning := coalesce(case when v_hist <> 'Being asked now' then v_hist end, private.instructor_soft_warning(r.iid, p_mw));
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
    pos := n; instructor_id := r.iid; full_name := r.nm; source := 'Ranking'; queue_item_id := null; warning := private.instructor_soft_warning(r.iid, p_mw);
    reason := coalesce(private.eligibility(r.iid, p_mw), private.week_history_reason(r.iid, p_mw));
    return next;
  end loop;
end;
$$;

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
            'warning', coalesce(private.week_history_reason(i.id, p_module_week_id), private.instructor_soft_warning(i.id, p_module_week_id)), 'is_test', i.is_test)
          order by k.rank nulls last, i.full_name), '[]')
     from public.instructor i left join public.module_ranking k on k.instructor_id = i.id and k.module_id = v_module and k.cohort_id is not distinct from v_cohort
    where i.status <> 'Archived');
end;
$$;
