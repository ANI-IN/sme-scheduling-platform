-- Release 3, M7b part 2 (decision 299): Reset to standard, and updating cohorts when their standard changes.
--
-- One plan per class week says how to bring it back to its standard: move a class, add one, cancel one, or put the
-- standard's module and week back. Every change is checked first (holidays, unusual hours, the cohort's other
-- classes, the confirmed instructor's day, and a clash for the person being asked); a Block keeps the week as it is
-- with the reason, and warnings need a reason when it is saved. The plan is applied through the existing actions, so
-- a confirmed instructor hears about a new time through the usual time change flow and is never changed otherwise.
--
-- * Reset to standard (one class week, or every future class week of a cohort): customized weeks come back; a
--   confirmed week only when its classes just move (adding or removing a class there stays on the class week).
-- * Updating from the standard (all cohorts that follow it, or the ones chosen): only future weeks with no confirmed
--   instructor and no change of their own are updated; the others are listed as "Not updated" with the reason. A
--   module added to the standard adds its class week to each cohort.
-- Both have a preview (nothing saved) and are logged in Activity history.

-- The class week as its standard has it now, or null.
create or replace function private.standard_target(p_mw uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare w public.module_week; c public.cohort; sw record;
begin
  select * into w from public.module_week where id = p_mw;
  select * into c from public.cohort where id = w.cohort_id;
  if w.standard_position is null or c.standard_schedule_id is null or c.start_date is null then return null; end if;
  select * into sw from private.standard_weeks(c.standard_schedule_id, c.start_date) x where x.pos = w.standard_position;
  if sw.pos is null then return null; end if;
  return private.plan_week_row(c.domain_id, sw.module_id, sw.week_start, private.standard_patterns(c.standard_schedule_id, sw.module_id),
                               c.region, c.id, c.name) || jsonb_build_object('standard_position', sw.pos);
end;
$$;

-- How to bring one class week back to its standard, with every check. p_allow_confirmed: Reset may move the classes
-- of a confirmed week (time change flow); updating from the standard leaves confirmed weeks alone.
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

-- Carry out one plan through the existing actions. Not counted as a change of its own (app.standard_apply).
create or replace function private.apply_week_plan(p_plan jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  o jsonb;
  v_clash boolean := false;
  v_times boolean := false;
  v_class uuid;
  v_booking uuid;
  v_prev text := current_setting('app.standard_apply', true);
begin
  select * into w from public.module_week where id = (p_plan ->> 'module_week_id')::uuid for update;
  perform set_config('app.standard_apply', 'on', true);
  select id into v_booking from public.booking where module_week_id = w.id and status = 'Active';
  for o in select * from jsonb_array_elements(coalesce(p_plan -> 'ops', '[]')) where value ->> 'op' = 'week' loop
    update public.module_week set module_id = (o ->> 'module_id')::uuid, week_start_date = (o ->> 'week_start_date')::date where id = w.id;
  end loop;
  -- Adds before cancels, so a class week never runs out of classes on the way.
  for o in select * from jsonb_array_elements(coalesce(p_plan -> 'ops', '[]')) where value ->> 'op' = 'add' loop
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region)
    values (w.id, o ->> 'class_type', o ->> 'title', (o ->> 'starts_at')::timestamptz, (o ->> 'ends_at')::timestamptz, o ->> 'region')
    returning id into v_class;
    v_times := true;
  end loop;
  for o in select * from jsonb_array_elements(coalesce(p_plan -> 'ops', '[]')) where value ->> 'op' = 'move' loop
    update public.class_session set region = o ->> 'region' where id = (o ->> 'class_id')::uuid and region is distinct from o ->> 'region';
    v_clash := private.move_class((o ->> 'class_id')::uuid, (o ->> 'starts_at')::timestamptz, (o ->> 'ends_at')::timestamptz) or v_clash;
    v_times := true;
  end loop;
  for o in select * from jsonb_array_elements(coalesce(p_plan -> 'ops', '[]')) where value ->> 'op' = 'cancel' loop
    perform public.cancel_class((o ->> 'class_id')::uuid, 'Back to the standard');
    v_times := true;
  end loop;
  if v_times then
    perform private.week_times_changed(w.id, private.mw_now(w.id), v_clash);
  end if;
  update public.module_week set customized_at = null where id = w.id;
  perform set_config('app.standard_apply', coalesce(v_prev, ''), true);
end;
$$;

-- Plans for many class weeks: what changes, what is not updated and why, and the checks.
create or replace function private.standard_plans(p_plans jsonb)
returns jsonb language sql immutable set search_path = ''
as $$
  select jsonb_build_object(
    'changes', coalesce((select jsonb_agg(p) from jsonb_array_elements(p_plans) p
                          where p ->> 'not_updated' is null and jsonb_array_length(coalesce(p -> 'actions', '[]')) > 0), '[]'),
    'not_updated', coalesce((select jsonb_agg(jsonb_build_object('module_week_id', p -> 'module_week_id', 'label', p -> 'label',
                                                                 'reason', p -> 'not_updated'))
                               from jsonb_array_elements(p_plans) p where p ->> 'not_updated' is not null), '[]'),
    'warnings', coalesce((select jsonb_agg(x) from jsonb_array_elements(p_plans) p, jsonb_array_elements(coalesce(p -> 'warnings', '[]')) x
                           where p ->> 'not_updated' is null), '[]'));
$$;

-- Apply previewed plans, or say what needs a decision first.
create or replace function private.save_standard_plans(p_result jsonb, p_accept_warnings boolean, p_reason text, p_domain uuid,
  p_action text, p_ref jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare p jsonb; n int := 0;
begin
  if jsonb_array_length(p_result -> 'warnings') > 0 and not p_accept_warnings then
    return p_result || jsonb_build_object('ok', false, 'needs_confirmation', true);
  end if;
  for p in select * from jsonb_array_elements(p_result -> 'changes') loop
    perform private.apply_week_plan(p);
    n := n + 1;
  end loop;
  perform private.log_accepted_warnings(p_result -> 'warnings', p_reason, p_domain);
  perform private.log_event('Team actions', p_action, 'domain', p_domain, null,
    p_ref || jsonb_build_object('class_weeks_changed', n, 'not_updated', jsonb_array_length(p_result -> 'not_updated')),
    nullif(trim(coalesce(p_reason, '')), ''), p_domain);
  perform private.queue_deliver('standard');
  return p_result || jsonb_build_object('ok', true, 'saved', n);
end;
$$;

-- Reset to standard: chosen class weeks, or every future class week of a cohort. Preview unless p_save.
create or replace function public.reset_to_standard(p_module_week_ids uuid[] default null, p_cohort_id uuid default null,
  p_save boolean default false, p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_ids uuid[];
  v_domain uuid;
  v jsonb;
begin
  perform private.require_team();
  if p_cohort_id is not null then
    if not exists (select 1 from public.cohort where id = p_cohort_id and standard_schedule_id is not null) then
      raise exception 'This cohort does not follow a standard schedule.' using errcode = '22023';
    end if;
    select array_agg(w.id order by w.first_class_at) into v_ids from public.module_week w
     where w.cohort_id = p_cohort_id and w.standard_position is not null and w.status not in ('Cancelled', 'Completed')
       and w.first_class_at > private.domain_now(w.domain_id);
  else
    v_ids := p_module_week_ids;
  end if;
  if coalesce(cardinality(v_ids), 0) = 0 then raise exception 'There is no future class week to reset.' using errcode = '22023'; end if;
  if cardinality(v_ids) > 500 then raise exception 'Reset at most 500 class weeks at a time.' using errcode = '22023'; end if;
  select domain_id into v_domain from public.module_week where id = v_ids[1];
  if exists (select 1 from public.module_week where id = any (v_ids) and domain_id <> v_domain) then
    raise exception 'Reset the class weeks of one domain at a time.' using errcode = '22023';
  end if;
  -- One reset at a time per domain, so two people cannot reset the same weeks at once.
  if p_save then perform pg_advisory_xact_lock(hashtext('standard:' || v_domain::text)); end if;
  v := private.standard_plans((select jsonb_agg(private.standard_week_plan(x, true)) from unnest(v_ids) x));
  if not p_save then return v; end if;
  return private.save_standard_plans(v, p_accept_warnings, p_reason, v_domain, 'Reset to standard',
    jsonb_build_object('cohort_id', p_cohort_id));
end;
$$;

-- Updating from the standard: its cohorts (all, or the chosen ones). Preview unless p_save.
create or replace function public.apply_standard(p_schedule_id uuid, p_cohort_ids uuid[] default null,
  p_save boolean default false, p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  s public.standard_schedule;
  c record;
  w record;
  sw record;
  v_plans jsonb := '[]';
  v_add jsonb := '[]';
  v_row jsonb;
  v jsonb;
  v_res jsonb;
  v_now timestamptz;
begin
  perform private.require_team();
  select * into s from public.standard_schedule where id = p_schedule_id;
  if s.id is null then raise exception 'Choose a standard schedule.' using errcode = '22023'; end if;
  if s.archived_at is not null then raise exception 'This standard schedule is archived. Restore it first.' using errcode = '22023'; end if;
  if p_save then perform pg_advisory_xact_lock(hashtext('standard:' || s.domain_id::text)); end if;
  v_now := private.domain_now(s.domain_id);
  for c in select * from public.cohort x where x.standard_schedule_id = s.id and x.archived_at is null
              and (p_cohort_ids is null or x.id = any (p_cohort_ids)) order by x.name loop
    for w in select * from public.module_week x where x.cohort_id = c.id and x.standard_position is not null
                and x.status not in ('Cancelled', 'Completed') and x.first_class_at > v_now order by x.first_class_at loop
      if w.customized_at is not null then
        v_plans := v_plans || jsonb_build_object('module_week_id', w.id, 'label', private.mw_label(w.id), 'not_updated',
          'Changed for this cohort on ' || to_char(w.customized_at at time zone private.region_tz(c.region), 'Mon FMDD')
          || '. Use Reset to standard on the class week to bring it back.');
      else
        v_plans := v_plans || private.standard_week_plan(w.id, false);
      end if;
    end loop;
    -- A module added to the standard: its class week for this cohort, if it is still ahead.
    if c.start_date is not null then
      for sw in select * from private.standard_weeks(s.id, c.start_date) x
                 where x.week_start > v_now::date
                   and not exists (select 1 from public.module_week m where m.cohort_id = c.id and m.standard_position = x.pos) loop
        v_row := private.plan_week_row(s.domain_id, sw.module_id, sw.week_start, private.standard_patterns(s.id, sw.module_id),
                                       c.region, c.id, c.name) || jsonb_build_object('standard_position', sw.pos, 'cohort_id', c.id);
        if v_row ->> 'problem' is null and not (v_row ->> 'duplicate')::boolean then
          v_add := v_add || v_row;
        end if;
      end loop;
    end if;
  end loop;
  v := private.standard_plans(v_plans);
  v := v || jsonb_build_object('new_class_weeks', (select coalesce(jsonb_agg(jsonb_build_object('cohort', r ->> 'cohort',
           'module', r ->> 'module_name', 'week_start_date', r ->> 'week_start_date')), '[]') from jsonb_array_elements(v_add) r),
         'warnings', (v -> 'warnings') || coalesce((select jsonb_agg(x) from jsonb_array_elements(v_add) r,
                                                    jsonb_array_elements(r -> 'warnings') x), '[]'));
  if not p_save then return v; end if;
  if jsonb_array_length(v -> 'warnings') > 0 and not p_accept_warnings then
    return v || jsonb_build_object('ok', false, 'needs_confirmation', true);
  end if;
  if jsonb_array_length(v_add) > 0 then
    perform set_config('app.standard_apply', 'on', true);
    v_res := public.create_module_weeks(s.domain_id, v_add, true, p_reason, null);
    if coalesce((v_res ->> 'needs_confirmation')::boolean, false) then
      raise exception 'The new class weeks need a decision first. Update from the preview again.' using errcode = '22023';
    end if;
    update public.module_week mw set standard_position = (r ->> 'standard_position')::int
      from jsonb_array_elements(v_add) r
     where mw.cohort_id = (r ->> 'cohort_id')::uuid and mw.module_id = (r ->> 'module_id')::uuid
       and mw.week_start_date = (r ->> 'week_start_date')::date and mw.standard_position is null;
    perform set_config('app.standard_apply', 'off', true);
  end if;
  -- The warnings were accepted above (a reason is still required for them).
  return private.save_standard_plans(v, true, p_reason, s.domain_id, 'Standard applied: ' || s.name,
    jsonb_build_object('schedule', s.name, 'new_class_weeks', jsonb_array_length(v_add)));
end;
$$;

-- The standard version of a class week next to the current one, for the class drawer and the Schedule board.
create or replace function public.standard_compare(p_module_week_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare t jsonb; v_cur jsonb; p jsonb;
begin
  perform private.require_team();
  t := private.standard_target(p_module_week_id);
  if t is null then return jsonb_build_object('follows_standard', false); end if;
  select coalesce(jsonb_agg(jsonb_build_object('title', k.title, 'shown', private.fmt_class_range(k.starts_at, k.ends_at, k.region))
           order by k.starts_at), '[]') into v_cur
    from public.class_session k where k.module_week_id = p_module_week_id and k.status = 'Planned';
  p := private.standard_week_plan(p_module_week_id, true);
  return jsonb_build_object('follows_standard', true,
    'standard', jsonb_build_object('module', t ->> 'module_name', 'week_start_date', t ->> 'week_start_date',
      'classes', (select coalesce(jsonb_agg(jsonb_build_object('title', x ->> 'title', 'shown', x ->> 'shown')
                    order by x ->> 'starts_at'), '[]') from jsonb_array_elements(t -> 'classes') x)),
    'current', jsonb_build_object('classes', v_cur),
    'differs', jsonb_array_length(coalesce(p -> 'actions', '[]')) > 0,
    'customized_at', (select customized_at from public.module_week where id = p_module_week_id),
    'reset', jsonb_build_object('actions', coalesce(p -> 'actions', '[]'), 'not_updated', p -> 'not_updated'));
end;
$$;

revoke execute on function private.standard_target(uuid) from public, anon, authenticated;
revoke execute on function private.standard_week_plan(uuid, boolean) from public, anon, authenticated;
revoke execute on function private.apply_week_plan(jsonb) from public, anon, authenticated;
revoke execute on function private.standard_plans(jsonb) from public, anon, authenticated;
revoke execute on function private.save_standard_plans(jsonb, boolean, text, uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public.reset_to_standard(uuid[], uuid, boolean, boolean, text) from public, anon;
revoke execute on function public.apply_standard(uuid, uuid[], boolean, boolean, text) from public, anon;
revoke execute on function public.standard_compare(uuid) from public, anon;
grant execute on function public.reset_to_standard(uuid[], uuid, boolean, boolean, text) to authenticated, service_role;
grant execute on function public.apply_standard(uuid, uuid[], boolean, boolean, text) to authenticated, service_role;
grant execute on function public.standard_compare(uuid) to authenticated, service_role;
