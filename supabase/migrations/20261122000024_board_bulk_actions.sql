-- Release 3, M12b (decision 314): bulk move and bulk cancel from the Schedule board, with one combined preview.
--
-- The board lets Ops select several class weeks. Add a break and Make one shared class already have combined
-- previews (add_break, share_class_weeks). This adds the other two: move several class weeks by whole weeks, and
-- cancel several class weeks. bulk_change_weeks really makes the change inside a block that is always rolled back,
-- with the same functions as one class week at a time (shift_classes, cancel_module_week), then reads
-- private.week_problems, so every check is the usual one and each problem says whether the change creates it. Saving
-- makes the same calls for real, in one transaction: a Block stops all of them; a new Warning needs a reason, kept in
-- Activity history.

create or replace function public.bulk_change_weeks(p_action text, p_week_ids uuid[], p_weeks int default null,
  p_reason text default null, p_save boolean default false, p_accept_warnings boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_ids uuid[] := array(select distinct x from unnest(coalesce(p_week_ids, '{}')) x);
  v_domain uuid;
  v_blocks jsonb := '[]';
  v_before jsonb := '{}';
  v_weeks jsonb := '[]';
  v_warn jsonb := '[]';
  v_keys text[];
  v_prob jsonb;
  v_person record;
  v_out jsonb;
  w record;
  v_id uuid;
  v_skip uuid[] := '{}';
  v_people jsonb := '{}';
  v_labels jsonb := '{}';
begin
  perform private.require_team();
  if p_action not in ('move', 'cancel') then
    raise exception 'Choose move or cancel.' using errcode = '22023';
  end if;
  if cardinality(v_ids) = 0 then raise exception 'Select at least one class week.' using errcode = '22023'; end if;
  if cardinality(v_ids) > 60 then raise exception 'Select at most 60 class weeks at once.' using errcode = '22023'; end if;
  if p_action = 'move' and (p_weeks is null or p_weeks = 0 or abs(p_weeks) > 26) then
    raise exception 'Move by 1 to 26 weeks, earlier or later.' using errcode = '22023';
  end if;
  if p_action = 'cancel' and p_save and coalesce(trim(p_reason), '') = '' then
    raise exception 'Say why these class weeks are cancelled. The reason is kept in Activity history.' using errcode = '22023';
  end if;
  if (select count(distinct mw.domain_id) from public.module_week mw where mw.id = any (v_ids)) > 1 then
    raise exception 'Select class weeks of one domain at a time.' using errcode = '22023';
  end if;
  select mw.domain_id into v_domain from public.module_week mw where mw.id = any (v_ids) limit 1;
  if v_domain is null or (select count(*) from public.module_week mw where mw.id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'One of the class weeks no longer exists. Reload the board.' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('plan:' || v_domain));

  -- Rules that stop the change for one class week, in plain words.
  for w in select mw.*, private.mw_label(mw.id) as label from public.module_week mw where mw.id = any (v_ids) order by mw.week_start_date loop
    if w.status in ('Completed', 'Cancelled') then
      v_blocks := v_blocks || to_jsonb(w.label || ' is ' || lower(w.status) || ' already.');
      v_skip := v_skip || w.id;
    elsif w.first_class_at is not null and w.first_class_at <= now() then
      v_blocks := v_blocks || to_jsonb(w.label || ' has started, so it can''t be ' || case when p_action = 'move' then 'moved' else 'cancelled' end || ' from here.');
      v_skip := v_skip || w.id;
    elsif w.shared_with is not null then
      v_blocks := v_blocks || to_jsonb(w.label || ' is taught in another cohort''s class. Change the shared class, or stop sharing first.');
      v_skip := v_skip || w.id;
    end if;
    v_before := v_before || jsonb_build_object(w.id::text, private.week_problems(w.id));
    -- The name and times as they are now: a cancelled week has no classes left to name afterwards.
    v_labels := v_labels || jsonb_build_object(w.id::text, w.label);
    -- Who is confirmed (or being asked) now, before anything changes.
    select x.id, x.name, x.status into v_person from (
      select b.instructor_id as id, i.full_name as name, 'Confirmed' as status, 1 as o
        from public.booking b join public.instructor i on i.id = b.instructor_id
       where b.module_week_id = w.id and b.status = 'Active'
      union all
      select r.instructor_id, i.full_name, 'Asked', 2
        from public.request r join public.instructor i on i.id = r.instructor_id
       where r.module_week_id = w.id and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')
      order by o limit 1) x;
    if v_person.id is not null then
      v_people := v_people || jsonb_build_object(w.id::text, jsonb_build_object('id', v_person.id, 'name', v_person.name, 'status', v_person.status));
    end if;
  end loop;

  -- The change, really made, then always rolled back.
  begin
    perform set_config('app.suppress_setup_log', 'on', true);
    for v_id in select mw.id from public.module_week mw where mw.id = any (v_ids) and not (mw.id = any (v_skip))
                 order by case when coalesce(p_weeks, 0) > 0 then mw.week_start_date end desc, mw.week_start_date loop
      begin
        if p_action = 'move' then
          perform public.shift_classes(v_id, p_weeks, false);
        else
          perform public.cancel_module_week(v_id, coalesce(nullif(trim(p_reason), ''), 'Cancelled from the Schedule board'));
        end if;
      exception when sqlstate 'P0B02' then raise;
      when others then
        v_blocks := v_blocks || to_jsonb(private.mw_label(v_id) || ': ' || sqlerrm);
      end;
    end loop;
    for w in select mw.*, private.mw_label(mw.id) as label, c.name as cohort from public.module_week mw
               left join public.cohort c on c.id = mw.cohort_id where mw.id = any (v_ids) order by mw.week_start_date loop
      v_keys := array(select (p ->> 'code') || ':' || coalesce(p ->> 'class_id', '') || ':' || coalesce(p ->> 'instructor_id', '')
                        from jsonb_array_elements(coalesce(v_before -> w.id::text, '[]')) p);
      if p_action = 'move' then
        select coalesce(jsonb_agg(p || jsonb_build_object('module_week_id', w.id,
                 'new', not ((p ->> 'code') || ':' || coalesce(p ->> 'class_id', '') || ':' || coalesce(p ->> 'instructor_id', '') = any (v_keys)))), '[]')
          into v_prob from jsonb_array_elements(private.week_problems(w.id)) p;
      else
        v_prob := '[]';
      end if;
      v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id,
        'label', case when p_action = 'cancel' then coalesce(v_labels ->> w.id::text, w.label) else w.label end,
        'cohort', w.cohort,
        'week_start_date', w.week_start_date,
        'instructor', v_people -> w.id::text,
        'told', case when v_people ? w.id::text then
                  (v_people -> w.id::text ->> 'name') || case
                    when p_action = 'cancel' then ' is told the class week is cancelled.'
                    when v_people -> w.id::text ->> 'status' = 'Confirmed' then ' is asked whether the new time still works.'
                    else ' is asked again with the new time.' end end,
        'problems', v_prob);
      v_blocks := v_blocks || coalesce((select jsonb_agg(to_jsonb(w.label || ': ' || (p ->> 'text')))
                                          from jsonb_array_elements(v_prob) p where (p ->> 'new')::boolean and p ->> 'level' = 'Block'), '[]');
      v_warn := v_warn || coalesce((select jsonb_agg(jsonb_build_object('code', p ->> 'code', 'level', 'Warning',
                                            'text', w.label || ': ' || (p ->> 'text')))
                                      from jsonb_array_elements(v_prob) p where (p ->> 'new')::boolean and p ->> 'level' = 'Warning'), '[]');
    end loop;
    v_out := jsonb_build_object('action', p_action, 'weeks', v_weeks, 'blocks', v_blocks, 'warnings', v_warn);
    raise exception 'bulk preview' using errcode = 'P0B02';
  exception when sqlstate 'P0B02' then
    perform set_config('app.suppress_setup_log', 'off', true);
  end;

  if not p_save then
    return v_out || jsonb_build_object('ok', jsonb_array_length(v_out -> 'blocks') = 0, 'preview', true);
  end if;
  if jsonb_array_length(v_out -> 'blocks') > 0 then
    return v_out || jsonb_build_object('ok', false);
  end if;
  if jsonb_array_length(v_out -> 'warnings') > 0 and not p_accept_warnings then
    return v_out || jsonb_build_object('ok', false, 'needs_confirmation', true);
  end if;
  if jsonb_array_length(v_out -> 'warnings') > 0 and coalesce(trim(p_reason), '') = '' then
    raise exception 'Say why you go ahead despite the warnings. The reason is kept in Activity history.' using errcode = '22023';
  end if;
  for v_id in select mw.id from public.module_week mw where mw.id = any (v_ids)
               order by case when coalesce(p_weeks, 0) > 0 then mw.week_start_date end desc, mw.week_start_date loop
    if p_action = 'move' then
      perform public.shift_classes(v_id, p_weeks, false);
    else
      perform public.cancel_module_week(v_id, trim(p_reason));
    end if;
  end loop;
  if jsonb_array_length(v_out -> 'warnings') > 0 then
    perform private.log_accepted_warnings(v_out -> 'warnings', trim(p_reason), v_domain);
  end if;
  perform private.log_event('Team actions',
    case when p_action = 'move' then 'Class weeks moved from the Schedule board: ' || cardinality(v_ids)
         else 'Class weeks cancelled from the Schedule board: ' || cardinality(v_ids) end,
    'module_week', null, null,
    jsonb_build_object('weeks', (select jsonb_agg(x ->> 'label') from jsonb_array_elements(v_out -> 'weeks') x),
                       'by_weeks', p_weeks),
    nullif(trim(coalesce(p_reason, '')), ''), v_domain);
  return v_out || jsonb_build_object('ok', true, 'saved', cardinality(v_ids));
end;
$$;
revoke execute on function public.bulk_change_weeks(text, uuid[], int, text, boolean, boolean) from public, anon;
grant execute on function public.bulk_change_weeks(text, uuid[], int, text, boolean, boolean) to authenticated, service_role;
