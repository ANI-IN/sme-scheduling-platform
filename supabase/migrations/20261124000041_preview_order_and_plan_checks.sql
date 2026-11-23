-- Release 3 review: previews in date order, and the Plan classes dialog checked after every change.
--
-- 1. Add a break and Remove a break: the class weeks that move are listed in date order, earliest first, and so are
--    the classes of each week (the classes are moved latest first, so the list came out latest first).
-- 2. Reset to standard (chosen class weeks) and Update cohorts from a standard: the class weeks in date order across
--    every cohort, and the new class weeks too.
-- 3. A proposed time lists its classes in the order of the proposed times.
-- 4. public.check_plan: the checks of a plan before it is saved, one result per class week, so a change in the Plan
--    classes dialog shows its warnings at once.
-- Functions are copied from the migrations that defined them last (20261122000014, 20261122000012, 20261122000015)
-- with only the lines above changed.

create or replace function private.break_preview(p_cohort uuid, p_from date, p_offset int, p_new_start date,
  p_new_weeks int, p_new_reason text, p_ignore uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_before jsonb := '{}';
  v_out jsonb;
  v_moved jsonb;
  v_weeks jsonb := '[]';
  x jsonb;
  w record;
  v_person record;
  v_keys text[];
  v_prob jsonb;
  v_rules text[] := private.break_rule_blocks(p_cohort, p_from, p_offset, p_new_start, p_new_weeks, p_ignore);
begin
  for w in select mw.id from public.module_week mw
            where mw.cohort_id = p_cohort and mw.status not in ('Completed', 'Cancelled') and mw.week_start_date >= p_from loop
    v_before := v_before || jsonb_build_object(w.id::text, private.week_problems(w.id));
  end loop;
  begin
    if p_ignore is not null then
      update public.cohort_break set status = 'Removed' where id = p_ignore;
    end if;
    v_moved := private.move_cohort_weeks(p_cohort, p_from, p_offset);
    if p_new_start is not null then
      begin
        insert into public.cohort_break (cohort_id, domain_id, starts_on, weeks, reason)
        values (p_cohort, (select domain_id from public.cohort where id = p_cohort), p_new_start, p_new_weeks, p_new_reason);
      exception when exclusion_violation then
        null; -- it overlaps another break: already a Block above
      end;
    end if;
    -- In date order, earliest first (the classes move latest first, so two weeks never meet on the way).
    for x in select e from jsonb_array_elements(v_moved -> 'weeks') e order by (e ->> 'from')::date, e ->> 'label' loop
      select b.instructor_id as id, i.full_name as name, 'Confirmed' as status into v_person
        from public.booking b join public.instructor i on i.id = b.instructor_id
       where b.module_week_id = (x ->> 'module_week_id')::uuid and b.status = 'Active';
      if v_person.id is null then
        select r.instructor_id as id, i.full_name as name, 'Asked' as status into v_person
          from public.request r join public.instructor i on i.id = r.instructor_id
         where r.module_week_id = (x ->> 'module_week_id')::uuid and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded');
      end if;
      v_keys := array(select (p ->> 'code') || ':' || coalesce(p ->> 'class_id', '') || ':' || coalesce(p ->> 'instructor_id', '')
                        from jsonb_array_elements(coalesce(v_before -> (x ->> 'module_week_id'), '[]')) p);
      select coalesce(jsonb_agg(p || jsonb_build_object('module_week_id', x ->> 'module_week_id',
               'new', not ((p ->> 'code') || ':' || coalesce(p ->> 'class_id', '') || ':' || coalesce(p ->> 'instructor_id', '') = any (v_keys)))), '[]')
        into v_prob from jsonb_array_elements(private.week_problems((x ->> 'module_week_id')::uuid)) p;
      v_weeks := v_weeks || (x - 'slot_clash' - 'classes' || jsonb_build_object(
        'classes', (select coalesce(jsonb_agg(c order by k.starts_at, k.id), '[]') from jsonb_array_elements(x -> 'classes') c
                      join public.class_session k on k.id = (c ->> 'class_id')::uuid),
        'instructor', case when v_person.id is not null then jsonb_build_object('id', v_person.id, 'name', v_person.name, 'status', v_person.status) end,
        'problems', v_prob));
    end loop;
    v_out := jsonb_build_object('cohort_id', p_cohort, 'cohort', (select name from public.cohort where id = p_cohort),
      'weeks', v_weeks,
      'blocks', to_jsonb(v_rules) || (v_moved -> 'blocks'));
    raise exception 'break preview' using errcode = 'P0B01';
  exception when sqlstate 'P0B01' then
    null;
  end;
  return v_out;
end;
$$;

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
    -- In date order, earliest first, whatever order they were chosen in.
    v_ids := array(select x from unnest(p_module_week_ids) x left join public.module_week w on w.id = x
                    order by w.first_class_at nulls last, x);
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
  -- Every cohort's class weeks together, in date order, earliest first.
  v_plans := coalesce((select jsonb_agg(p order by mw.first_class_at, mw.id) from jsonb_array_elements(v_plans) p
                         join public.module_week mw on mw.id = (p ->> 'module_week_id')::uuid), '[]');
  v_add := coalesce((select jsonb_agg(r order by (r ->> 'week_start_date')::date, r ->> 'cohort', r ->> 'module_name')
                       from jsonb_array_elements(v_add) r), '[]');
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

create or replace function private.proposal_check(p_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  p public.time_proposal;
  r public.request;
  w public.module_week;
  x jsonb;
  v_before jsonb;
  v_keys text[];
  v_problems jsonb;
  v_blocks text[] := '{}';
  v_out jsonb;
  v_clash boolean := false;
begin
  select * into p from public.time_proposal where id = p_id;
  select * into r from public.request where id = p.request_id;
  select * into w from public.module_week where id = p.module_week_id;
  if p.status <> 'Pending' then v_blocks := v_blocks || 'This proposal was already decided.'::text; end if;
  if w.status in ('Cancelled', 'Completed') then v_blocks := v_blocks || 'This class week is no longer scheduled.'::text; end if;
  if r.status not in ('Sent', 'Reminded') then
    v_blocks := v_blocks || ('This request has closed (' || coalesce(r.close_reason, r.status) || '), so the proposal can''t be accepted. Reject it to tell them.');
  end if;
  if w.time_version <> p.time_version then
    v_blocks := v_blocks || 'The class times changed after this proposal was made, so it can''t be accepted. Reject it, or change the times on the class week.'::text;
  end if;
  if r.kind = 'TimeChange' and not exists (select 1 from public.booking b where b.id = r.booking_id and b.status = 'Active') then
    v_blocks := v_blocks || 'They are no longer confirmed for this class week.'::text;
  end if;
  v_before := private.week_problems(w.id);
  v_keys := array(select (e ->> 'code') || ':' || coalesce(e ->> 'class_id', '') || ':' || coalesce(e ->> 'instructor_id', '')
                    from jsonb_array_elements(v_before) e);
  begin
    for x in select * from jsonb_array_elements(p.proposed) loop
      if exists (select 1 from public.class_session c where c.id = (x ->> 'class_id')::uuid and c.status = 'Planned') then
        v_clash := private.move_class((x ->> 'class_id')::uuid, (x ->> 'starts_at')::timestamptz, (x ->> 'ends_at')::timestamptz) or v_clash;
      else
        v_blocks := v_blocks || ((x ->> 'title') || ' was cancelled after this proposal was made.');
      end if;
    end loop;
    if exists (select 1 from public.class_session a join public.class_session b on a.module_week_id = b.module_week_id and a.id < b.id
                where a.module_week_id = w.id and a.status = 'Planned' and b.status = 'Planned'
                  and tstzrange(a.starts_at, a.ends_at, '[)') && tstzrange(b.starts_at, b.ends_at, '[)')) then
      v_blocks := v_blocks || 'Two classes of this class week would overlap at the proposed times.'::text;
    end if;
    select coalesce(jsonb_agg(e || jsonb_build_object('new',
             not ((e ->> 'code') || ':' || coalesce(e ->> 'class_id', '') || ':' || coalesce(e ->> 'instructor_id', '') = any (v_keys)))), '[]')
      into v_problems from jsonb_array_elements(private.week_problems(w.id)) e
     where e ->> 'code' not in ('proposed_time', 'waiting_new_time');
    v_out := jsonb_build_object('problems', v_problems, 'slot_clash', v_clash);
    raise exception 'proposal check' using errcode = 'P0B02';
  exception when sqlstate 'P0B02' then
    null;
  end;
  if (v_out ->> 'slot_clash')::boolean and not exists (select 1 from jsonb_array_elements(v_out -> 'problems') e where e ->> 'code' = 'clash') then
    v_blocks := v_blocks || 'The proposed time clashes with another class of the instructor.'::text;
  end if;
  return jsonb_build_object('id', p.id, 'status', p.status, 'note', p.note,
    'proposed', (select coalesce(jsonb_agg(e order by (e ->> 'starts_at')::timestamptz), '[]') from jsonb_array_elements(p.proposed) e),
    'kind', case when r.kind = 'TimeChange' then 'Confirmed' else 'Asked' end,
    'instructor', (select full_name from public.instructor where id = p.instructor_id),
    'blocks', to_jsonb(v_blocks) || coalesce((select jsonb_agg(e ->> 'text') from jsonb_array_elements(v_out -> 'problems') e
                                               where e ->> 'level' = 'Block' and (e ->> 'new')::boolean), '[]'),
    'warnings', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_out -> 'problems') e
                           where e ->> 'level' in ('Warning', 'Information') and (e ->> 'new')::boolean), '[]'));
end;
$$;

-- The checks of a plan that is not saved yet, one result per class week: the same checks as Create (it really plans
-- each class week inside a block that is always rolled back), so the Plan classes dialog shows the warnings and
-- blocks of the times as they are now, after every change.
create or replace function public.check_plan(p_domain_id uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  v jsonb;
  v_out jsonb := '[]';
begin
  perform private.require_team();
  if jsonb_array_length(coalesce(p_rows, '[]')) > 104 then
    raise exception 'Check at most 104 class weeks at a time.' using errcode = '22023';
  end if;
  for r in select e from jsonb_array_elements(coalesce(p_rows, '[]')) with ordinality as t (e, n) order by n loop
    begin
      v := public.create_module_weeks(p_domain_id, jsonb_build_array(r), false);
      v := jsonb_build_object('blocks', '[]'::jsonb, 'warnings', coalesce(v -> 'warnings', '[]'::jsonb));
      raise exception 'plan check' using errcode = 'P0B03';
    exception
      when sqlstate 'P0B03' then
        null;
      when others then
        v := jsonb_build_object('blocks', to_jsonb(string_to_array(sqlerrm, E'\n')), 'warnings', '[]'::jsonb);
    end;
    v_out := v_out || jsonb_build_array(v);
  end loop;
  return jsonb_build_object('rows', v_out);
end;
$$;
revoke execute on function public.check_plan(uuid, jsonb) from public, anon;
grant execute on function public.check_plan(uuid, jsonb) to authenticated, service_role;
