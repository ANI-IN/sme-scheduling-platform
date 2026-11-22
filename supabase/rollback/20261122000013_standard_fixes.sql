-- Rollback of 20261122000013_standard_fixes.sql (decision 300): the functions and limits as they were, copied byte for
-- byte from the migrations that defined them last.

alter table public.standard_schedule_class drop constraint standard_schedule_class_day_offset_check,
  drop constraint standard_schedule_class_duration_minutes_check;
alter table public.standard_schedule_class add constraint standard_schedule_class_day_offset_check check (day_offset between 0 and 6),
  add constraint standard_schedule_class_duration_minutes_check check (duration_minutes between 15 and 600);

create or replace function private.ambiguous_warning(p_date date, p_time time, p_region text, p_label text default null)
returns jsonb language sql immutable set search_path = ''
as $$
  select case when cardinality(v) = 2 then jsonb_build_object('code', 'ambiguous_time',
    'text', coalesce(p_label || ': ', '') || to_char(p_time, 'FMHH12:MI AM') || ' on ' || to_char(p_date, 'Dy, Mon FMDD, YYYY')
            || ' happens twice in US Pacific time, because the clocks move back one hour that night. Choose which one you mean.',
    'options', jsonb_build_array(
      jsonb_build_object('fold', 1, 'label', 'The first time: ' || to_char(p_time, 'FMHH12:MI AM') || ' ' || private.tz_abbrev(v[1], p_region)
                                             || ' (' || private.fmt_local(v[1], 'India') || ')'),
      jsonb_build_object('fold', 2, 'label', 'The second time: ' || to_char(p_time, 'FMHH12:MI AM') || ' ' || private.tz_abbrev(v[2], p_region)
                                             || ' (' || private.fmt_local(v[2], 'India') || ')'))) end
    from (select private.local_candidates(p_date, p_time, p_region) v) x;
$$;

create or replace function public.save_standard_schedule(p_id uuid, p_domain_id uuid, p_name text, p_module_ids uuid[],
  p_breaks jsonb default '[]', p_notes text default null, p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  s public.standard_schedule;
  v_name text := trim(coalesce(p_name, ''));
  v_n int := coalesce(cardinality(p_module_ids), 0);
  b jsonb;
  v_after int[] := '{}';
  i int;
begin
  perform private.require_team();
  if p_id is not null then
    select * into s from public.standard_schedule where id = p_id for update;
    if s.id is null then raise exception 'This standard schedule no longer exists.' using errcode = '22023'; end if;
    if p_expected_version is not null and s.version <> p_expected_version then
      raise exception 'Someone else saved this standard schedule after you opened it. Reload the page to see their changes, then try again.' using errcode = '40001';
    end if;
  elsif not exists (select 1 from public.domain where id = p_domain_id) then
    raise exception 'Choose a domain.' using errcode = '22023';
  end if;
  if v_name = '' then raise exception 'Give the standard schedule a name.' using errcode = '22023'; end if;
  if exists (select 1 from public.standard_schedule x where x.domain_id = coalesce(s.domain_id, p_domain_id)
              and lower(x.name) = lower(v_name) and x.id is distinct from p_id) then
    raise exception 'This domain already has a standard schedule named %.', v_name using errcode = '23505';
  end if;
  if v_n = 0 then raise exception 'Add at least one module to the standard schedule.' using errcode = '22023'; end if;
  if (select count(distinct x) from unnest(p_module_ids) x) <> v_n then
    raise exception 'Each module can be in a standard schedule once.' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_module_ids) x left join public.module m on m.id = x
              where m.id is null or m.domain_id <> coalesce(s.domain_id, p_domain_id) or m.status <> 'Active') then
    raise exception 'Only active modules of this domain can be in its standard schedules.' using errcode = '22023';
  end if;
  for b in select * from jsonb_array_elements(coalesce(p_breaks, '[]')) loop
    if coalesce((b ->> 'after_position')::int, 0) not between 1 and v_n - 1 then
      raise exception 'A break goes between two modules of the standard schedule.' using errcode = '22023';
    end if;
    if coalesce((b ->> 'weeks')::int, 0) not between 1 and 8 then
      raise exception 'A break lasts 1 to 8 weeks.' using errcode = '22023';
    end if;
    if (b ->> 'after_position')::int = any (v_after) then
      raise exception 'There is already a break after module %.', b ->> 'after_position' using errcode = '22023';
    end if;
    v_after := v_after || (b ->> 'after_position')::int;
  end loop;

  if s.id is null then
    insert into public.standard_schedule (domain_id, name, notes) values (p_domain_id, v_name, nullif(trim(coalesce(p_notes, '')), ''))
    returning * into s;
  elsif s.name is distinct from v_name or s.notes is distinct from nullif(trim(coalesce(p_notes, '')), '') then
    update public.standard_schedule set name = v_name, notes = nullif(trim(coalesce(p_notes, '')), '') where id = s.id returning * into s;
  end if;
  -- Only what changed is saved, so Activity history shows only real changes.
  if array(select module_id from public.standard_schedule_module where schedule_id = s.id order by position) is distinct from p_module_ids then
    delete from public.standard_schedule_module where schedule_id = s.id;
    for i in 1 .. v_n loop
      insert into public.standard_schedule_module (schedule_id, module_id, position) values (s.id, p_module_ids[i], i);
    end loop;
  end if;
  if (select coalesce(jsonb_agg(jsonb_build_object('after_position', after_position, 'weeks', weeks) order by after_position), '[]')
        from public.standard_schedule_break where schedule_id = s.id)
     is distinct from
     (select coalesce(jsonb_agg(jsonb_build_object('after_position', (x ->> 'after_position')::int, 'weeks', (x ->> 'weeks')::int)
                                order by (x ->> 'after_position')::int), '[]')
        from jsonb_array_elements(coalesce(p_breaks, '[]')) x) then
    delete from public.standard_schedule_break where schedule_id = s.id;
    insert into public.standard_schedule_break (schedule_id, after_position, weeks)
    select s.id, (x ->> 'after_position')::int, (x ->> 'weeks')::int from jsonb_array_elements(coalesce(p_breaks, '[]')) x;
  end if;
  return jsonb_build_object('id', s.id, 'version', (select version from public.standard_schedule where id = s.id));
end;
$$;

create or replace function private.standard_week_plan(p_mw uuid, p_allow_confirmed boolean)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  w public.module_week;
  t jsonb;
  v_label text := private.mw_label(p_mw);
  v_booked uuid;
  v_asked uuid;
  v_cur jsonb;
  v_tgt jsonb;
  v_ops jsonb := '[]';
  v_actions jsonb := '[]';
  v_warn jsonb := '[]';
  i int;
  a jsonb;
  b jsonb;
  v_s timestamptz;
  v_e timestamptz;
  v_block text;
  v_iw jsonb;
  v_name text;
  v_clash text;
  v_out jsonb;
begin
  select * into w from public.module_week where id = p_mw;
  v_out := jsonb_build_object('module_week_id', p_mw, 'label', v_label);
  if w.standard_position is null then
    return v_out || jsonb_build_object('not_updated', 'It was added outside the standard.');
  end if;
  if w.status = 'Cancelled' then return v_out || jsonb_build_object('not_updated', 'It is cancelled.'); end if;
  if w.status = 'Completed' or w.first_class_at <= private.domain_now(w.domain_id) then
    return v_out || jsonb_build_object('not_updated', 'It has already started or taken place.');
  end if;
  t := private.standard_target(p_mw);
  if t is null then
    return v_out || jsonb_build_object('not_updated', 'Its module is no longer in the standard. Cancel the class week if it is not needed.');
  end if;
  select b2.instructor_id into v_booked from public.booking b2 where b2.module_week_id = p_mw and b2.status = 'Active';
  select r.instructor_id into v_asked from public.request r
   where r.module_week_id = p_mw and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded');
  if v_booked is not null and not p_allow_confirmed then
    return v_out || jsonb_build_object('not_updated',
      'An instructor is confirmed. Change the time on the class week, so they are asked about the new time.');
  end if;
  if t ->> 'problem' is not null then return v_out || jsonb_build_object('not_updated', t ->> 'problem'); end if;
  if (w.module_id <> (t ->> 'module_id')::uuid) then
    if v_booked is not null or v_asked is not null then
      return v_out || jsonb_build_object('not_updated',
        'Its module was changed for this cohort, and an instructor is confirmed or being asked.');
    end if;
  end if;
  if w.module_id <> (t ->> 'module_id')::uuid or w.week_start_date <> (t ->> 'week_start_date')::date then
    v_ops := v_ops || jsonb_build_object('op', 'week', 'module_id', t ->> 'module_id', 'week_start_date', t ->> 'week_start_date');
    if w.module_id <> (t ->> 'module_id')::uuid then
      v_actions := v_actions || to_jsonb('The module goes back to ' || (t ->> 'module_name') || '.');
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'title', k.title, 'starts_at', k.starts_at, 'ends_at', k.ends_at,
           'region', k.region, 'shown', private.fmt_class_range(k.starts_at, k.ends_at, k.region)) order by k.starts_at, k.id), '[]')
    into v_cur from public.class_session k where k.module_week_id = p_mw and k.status = 'Planned';
  select coalesce(jsonb_agg(x order by x ->> 'starts_at'), '[]') into v_tgt from jsonb_array_elements(t -> 'classes') x;
  if v_booked is not null and jsonb_array_length(v_cur) <> jsonb_array_length(v_tgt) then
    return v_out || jsonb_build_object('not_updated',
      'The standard has a different number of classes and an instructor is confirmed. Add or cancel the class on the class week itself.');
  end if;
  select full_name into v_name from public.instructor where id = coalesce(v_booked, v_asked);

  for i in 0 .. greatest(jsonb_array_length(v_cur), jsonb_array_length(v_tgt)) - 1 loop
    a := v_cur -> i;
    b := v_tgt -> i;
    if b is not null then
      v_s := (b ->> 'starts_at')::timestamptz;
      v_e := (b ->> 'ends_at')::timestamptz;
    end if;
    if a is not null and b is not null and (a ->> 'starts_at')::timestamptz = v_s and (a ->> 'ends_at')::timestamptz = v_e
       and a ->> 'region' = b ->> 'region' then
      continue;
    end if;
    if b is not null then
      -- Checks for the class at its standard time.
      v_warn := v_warn || coalesce((select jsonb_agg(x) from jsonb_array_elements(private.class_warnings(w.domain_id, w.cohort_id, v_s, v_e,
                  p_mw, b ->> 'title', b ->> 'region')) x where x ->> 'code' <> 'short_notice'), '[]');
      if v_booked is not null then
        v_iw := private.instructor_warnings(w.domain_id, v_booked, v_s, v_e, b ->> 'region', (a ->> 'id')::uuid, b ->> 'title');
        v_block := (select x ->> 'text' from jsonb_array_elements(v_iw) x where x ->> 'level' = 'Block' limit 1);
        if v_block is null then
          v_block := private.clash_text(v_booked, v_s, v_e, b ->> 'region', p_mw);
          if v_block is not null then v_block := v_name || ': ' || v_block || '.'; end if;
        end if;
        if v_block is not null then return v_out || jsonb_build_object('not_updated', v_block); end if;
        v_warn := v_warn || v_iw;
      elsif v_asked is not null then
        v_clash := private.clash_text(v_asked, v_s, v_e, b ->> 'region', p_mw);
        if v_clash is not null then
          v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'asked_clash', 'level', 'Warning', 'module_week_id', p_mw,
            'text', v_name || ', who is being asked for ' || v_label || ', already teaches at the new time: ' || v_clash || '.'));
        end if;
      end if;
    end if;
    if a is not null and b is not null then
      v_ops := v_ops || jsonb_build_object('op', 'move', 'class_id', a ->> 'id', 'starts_at', v_s, 'ends_at', v_e, 'region', b ->> 'region');
      v_actions := v_actions || to_jsonb('Move ' || (a ->> 'title') || ' from ' || (a ->> 'shown') || ' to ' || (b ->> 'shown') || '.');
    elsif b is not null then
      v_ops := v_ops || jsonb_build_object('op', 'add', 'class_type', b ->> 'class_type', 'title', b ->> 'title',
                                           'starts_at', v_s, 'ends_at', v_e, 'region', b ->> 'region');
      v_actions := v_actions || to_jsonb('Add ' || (b ->> 'title') || ' on ' || (b ->> 'shown') || '.');
    else
      v_ops := v_ops || jsonb_build_object('op', 'cancel', 'class_id', a ->> 'id');
      v_actions := v_actions || to_jsonb('Cancel ' || (a ->> 'title') || ' (' || (a ->> 'shown') || ').');
    end if;
  end loop;
  return v_out || jsonb_build_object('actions', v_actions, 'ops', v_ops, 'warnings', v_warn,
    'confirmed', v_booked is not null, 'customized_at', w.customized_at);
end;
$$;
