-- =====================================================================================
-- Milestone 2d — Actions used by the app (and n8n). Same rules as the engine (BR-14).
-- Every function checks the caller is a company user, records the actor and logs History.
-- Errors are raised with plain-language messages the app shows as-is.
-- =====================================================================================

create or replace function private.queue_deliver(p_reason text)
returns void language sql security definer set search_path = ''
as $$
  insert into public.action_queue (action, payload, requested_by)
  values ('deliver', jsonb_build_object('reason', p_reason), private.current_team_member_id());
$$;

create or replace function private.mw_now(p_mw uuid)
returns timestamptz language sql stable security definer set search_path = ''
as $$ select private.domain_now((select w.domain_id from public.module_week w where w.id = p_mw)); $$;

-- -------------------------------------------------------------------------------------
-- Instructors (INS-3, INS-5)
-- -------------------------------------------------------------------------------------
create or replace function public.send_test_message(p_instructor_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_req uuid; v_n int; v_name text;
begin
  perform private.require_team();
  select full_name into v_name from public.instructor where id = p_instructor_id;
  if v_name is null then raise exception 'Instructor not found.'; end if;
  update public.request set status = 'Superseded', close_reason = 'New test message'
   where instructor_id = p_instructor_id and kind = 'Test' and status in ('Queued', 'Sent', 'Reminded');
  insert into public.request (instructor_id, kind, status, sent_at) values (p_instructor_id, 'Test', 'Sent', now())
  returning id into v_req;
  v_n := private.queue_instructor_message('M15', p_instructor_id, null, v_req, now(), private.buttons(v_req, array['GotIt']));
  perform private.queue_deliver('test message');
  perform private.log_event('Team actions', 'Test message sent to ' || v_name, 'instructor', p_instructor_id, null,
    jsonb_build_object('messages', v_n), null, null, null, null, null, p_instructor_id);
  return jsonb_build_object('ok', true, 'messages', v_n);
end;
$$;

create or replace function public.mark_verified_manually(p_instructor_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  update public.instructor set verified_at = now() where id = p_instructor_id;
  perform private.log_event('Team actions', 'Marked verified ("Seen manually")', 'instructor', p_instructor_id, null, null, p_note,
    null, null, null, null, p_instructor_id);
end;
$$;

-- Deactivate (or archive) an instructor. With upcoming bookings, ops chooses per class: keep or release.
-- p_decisions: {"<booking_id>": "keep" | "release"}
create or replace function public.deactivate_instructor(p_instructor_id uuid, p_decisions jsonb default null, p_status text default 'Inactive')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  b record;
  v_list jsonb := '[]';
  q record;
  v_name text;
begin
  perform private.require_team();
  if p_status not in ('Inactive', 'Archived') then raise exception 'Status must be Inactive or Archived.'; end if;
  select full_name into v_name from public.instructor where id = p_instructor_id;
  for b in select bk.id, bk.module_week_id from public.booking bk join public.module_week w on w.id = bk.module_week_id
            where bk.instructor_id = p_instructor_id and bk.status = 'Active' and w.first_class_at > now() order by w.first_class_at loop
    v_list := v_list || jsonb_build_object('booking_id', b.id, 'module_week_id', b.module_week_id, 'label', private.mw_label(b.module_week_id));
  end loop;
  if jsonb_array_length(v_list) > 0 and p_decisions is null then
    return jsonb_build_object('needs_decision', true, 'bookings', v_list);
  end if;
  update public.instructor set status = p_status where id = p_instructor_id;
  for b in select x.value as e from jsonb_array_elements(v_list) x loop
    if coalesce(p_decisions ->> (b.e ->> 'booking_id'), 'keep') = 'release' then
      perform private.release_booking_flow((b.e ->> 'booking_id')::uuid, 'Deactivated',
        private.mw_now((b.e ->> 'module_week_id')::uuid));
    else
      perform private.log_event('Team actions', 'Kept booking after deactivation: ' || (b.e ->> 'label'), 'booking',
        (b.e ->> 'booking_id')::uuid, null, null, null, null, null, (b.e ->> 'module_week_id')::uuid, null, p_instructor_id);
    end if;
  end loop;
  for q in select r.module_week_id from public.request r
            where r.instructor_id = p_instructor_id and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded') loop
    perform private.withdraw_open_request(q.module_week_id, 'Instructor deactivated', private.mw_now(q.module_week_id), true);
    perform private.ask_next(q.module_week_id, private.mw_now(q.module_week_id));
  end loop;
  perform private.queue_deliver('deactivation');
  perform private.log_event('Team actions', v_name || ' set to ' || p_status, 'instructor', p_instructor_id,
    null, jsonb_build_object('status', p_status, 'decisions', p_decisions), null, null, null, null, null, p_instructor_id);
  return jsonb_build_object('ok', true);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Rankings (RANK-1..4)
-- -------------------------------------------------------------------------------------
create or replace function public.save_ranking(p_module_id uuid, p_instructor_ids uuid[], p_expected_ids uuid[] default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_before uuid[];
  v_dom uuid;
  i int;
begin
  perform private.require_team();
  select domain_id into v_dom from public.module where id = p_module_id;
  select coalesce(array_agg(instructor_id order by rank), '{}') into v_before from public.module_ranking where module_id = p_module_id;
  if p_expected_ids is not null and v_before is distinct from p_expected_ids then
    raise exception 'This changed — reload. Someone else saved this ranking after you opened it.' using errcode = '40001';
  end if;
  if (select count(distinct x) from unnest(p_instructor_ids) x) <> cardinality(p_instructor_ids) then
    raise exception 'An instructor appears twice in the ranking.';
  end if;
  perform set_config('app.suppress_setup_log', 'on', true);
  delete from public.module_ranking where module_id = p_module_id;
  for i in 1 .. coalesce(cardinality(p_instructor_ids), 0) loop
    insert into public.module_ranking (module_id, instructor_id, rank) values (p_module_id, p_instructor_ids[i], i);
  end loop;
  perform set_config('app.suppress_setup_log', 'off', true);
  perform private.log_event('Setup changes', 'Ranking saved', 'module_ranking', p_module_id,
    jsonb_build_object('instructor_ids', to_jsonb(v_before),
      'names', (select jsonb_agg(ins.full_name order by o) from unnest(v_before) with ordinality u(x, o) join public.instructor ins on ins.id = u.x)),
    jsonb_build_object('instructor_ids', to_jsonb(p_instructor_ids),
      'names', (select jsonb_agg(ins.full_name order by o) from unnest(p_instructor_ids) with ordinality u(x, o) join public.instructor ins on ins.id = u.x)),
    null, v_dom, p_module_id);
end;
$$;

create or replace function private.next_name(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$ select (select l.full_name from private.build_line(p_mw) l where l.reason is null order by l.pos limit 1); $$;

-- "Affects N upcoming unconfirmed module weeks" + who would be asked next before/after (RANK-3).
create or replace function public.ranking_impact(p_module_id uuid, p_instructor_ids uuid[])
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
            and mw.status not in ('Confirmed', 'Completed', 'Cancelled') and mw.first_class_at > now()
            order by mw.first_class_at loop
    v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id, 'label', private.mw_label(w.id), 'next_now', private.next_name(w.id));
  end loop;
  begin
    perform set_config('app.suppress_setup_log', 'on', true);
    delete from public.module_ranking where module_id = p_module_id;
    for i in 1 .. coalesce(cardinality(p_instructor_ids), 0) loop
      insert into public.module_ranking (module_id, instructor_id, rank) values (p_module_id, p_instructor_ids[i], i);
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

-- Who is being asked now and the line after them, with skip reasons (RANK-4, Outreach Section A).
create or replace function public.preview_next(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  perform private.require_team();
  select q.*, i.full_name into r from public.request q join public.instructor i on i.id = q.instructor_id
   where q.module_week_id = p_module_week_id and q.kind = 'Outreach' and q.status in ('Queued', 'Sent', 'Reminded');
  return jsonb_build_object(
    'asking', case when r.id is not null then jsonb_build_object('request_id', r.id, 'instructor_id', r.instructor_id,
      'name', r.full_name, 'sent_at', r.sent_at, 'reminded', r.status = 'Reminded', 'deadline_at', r.deadline_at) end,
    'next', private.next_name(p_module_week_id),
    'line', (select coalesce(jsonb_agg(jsonb_build_object('instructor_id', l.instructor_id, 'name', l.full_name, 'source', l.source,
               'reason', l.reason, 'warning', l.warning) order by l.pos), '[]') from private.build_line(p_module_week_id) l));
end;
$$;

-- Every active (non-archived) instructor for the manual selection panel, with the reason they can't be ticked.
create or replace function public.week_eligibility(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_module uuid;
begin
  perform private.require_team();
  select module_id into v_module from public.module_week where id = p_module_week_id;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'instructor_id', i.id, 'name', i.full_name, 'rank', k.rank, 'in_ranking', k.rank is not null,
            'reason', private.eligibility(i.id, p_module_week_id),
            'warning', private.week_history_reason(i.id, p_module_week_id), 'is_test', i.is_test)
          order by k.rank nulls last, i.full_name), '[]')
     from public.instructor i left join public.module_ranking k on k.instructor_id = i.id and k.module_id = v_module
    where i.status <> 'Archived');
end;
$$;

-- -------------------------------------------------------------------------------------
-- Outreach controls (OUT-3, OUT-8, OUT-9)
-- -------------------------------------------------------------------------------------
-- p_decision when a request is open: null → returns needs_decision; 'keep' → keep waiting; 'withdraw' → withdraw politely.
create or replace function public.set_outreach_queue(p_module_week_id uuid, p_mode text, p_instructor_ids uuid[] default null,
  p_end_behaviour text default null, p_decision text default null, p_start_now boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  r record;
  v_now timestamptz := private.mw_now(p_module_week_id);
  v_pos int;
  i int;
  v_req uuid;
begin
  perform private.require_team();
  if p_mode not in ('Sequential', 'Manual') then raise exception 'Mode must be Sequential or Manual.'; end if;
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.status in ('Cancelled', 'Completed') then raise exception 'This module week is %.', lower(w.status); end if;
  select q.id, ins.full_name into r from public.request q join public.instructor ins on ins.id = q.instructor_id
   where q.module_week_id = p_module_week_id and q.kind = 'Outreach' and q.status in ('Queued', 'Sent', 'Reminded');
  if r.id is not null and p_decision is null then
    return jsonb_build_object('needs_decision', true, 'asking', r.full_name);
  end if;
  if r.id is not null and p_decision = 'withdraw' then
    perform private.withdraw_open_request(p_module_week_id, 'Outreach changed by ops', v_now, true);
  end if;

  update public.module_week
     set outreach_mode = p_mode,
         manual_end_behaviour = coalesce(p_end_behaviour, manual_end_behaviour),
         status = case when status = 'NeedsInstructor' then 'Ready' else status end
   where id = p_module_week_id;
  if p_mode = 'Manual' then
    delete from public.manual_queue_item where module_week_id = p_module_week_id and asked_request_id is null;
    select coalesce(max(position), 0) into v_pos from public.manual_queue_item where module_week_id = p_module_week_id;
    for i in 1 .. coalesce(cardinality(p_instructor_ids), 0) loop
      insert into public.manual_queue_item (module_week_id, instructor_id, position) values (p_module_week_id, p_instructor_ids[i], v_pos + i);
    end loop;
  end if;
  perform private.log_event('Team actions', 'Outreach set to ' || p_mode, 'module_week', p_module_week_id,
    jsonb_build_object('mode', w.outreach_mode), jsonb_build_object('mode', p_mode, 'queue', to_jsonb(p_instructor_ids),
      'end', p_end_behaviour, 'decision', p_decision), null, w.domain_id, w.module_id, p_module_week_id);
  if p_start_now and (r.id is null or p_decision = 'withdraw') then
    v_req := private.ask_next(p_module_week_id, v_now);
  end if;
  perform private.queue_deliver('outreach change');
  return jsonb_build_object('ok', true, 'request_id', v_req);
end;
$$;

create or replace function public.pause_outreach(p_module_week_id uuid, p_paused boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare w public.module_week;
begin
  perform private.require_team();
  update public.module_week set paused = p_paused where id = p_module_week_id returning * into w;
  perform private.log_event('Team actions', case when p_paused then 'Outreach paused' else 'Outreach resumed' end,
    'module_week', p_module_week_id, null, null, null, w.domain_id, w.module_id, p_module_week_id);
end;
$$;

create or replace function public.skip_to_next(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_now timestamptz := private.mw_now(p_module_week_id); v_who uuid; v_req uuid;
begin
  perform private.require_team();
  v_who := private.withdraw_open_request(p_module_week_id, 'Skipped', v_now, true);
  if v_who is null then raise exception 'Nobody is being asked right now.'; end if;
  v_req := private.ask_next(p_module_week_id, v_now);
  perform private.queue_deliver('skip');
  return jsonb_build_object('ok', true, 'request_id', v_req);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Booking actions (SCH-6, CNF-5)
-- -------------------------------------------------------------------------------------
create or replace function private.manual_booking(p_mw uuid, p_instructor uuid, p_via text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  perform private.require_team();
  v := private.confirm_booking(p_mw, p_instructor, null, p_via, private.mw_now(p_mw), p_note);
  if not (v ->> 'ok')::boolean then
    raise exception 'Can''t book: %', v ->> 'message' using errcode = '22023';
  end if;
  perform private.queue_deliver('manual booking');
  return v;
end;
$$;

create or replace function public.assign_manually(p_module_week_id uuid, p_instructor_id uuid, p_note text default null)
returns jsonb language sql security definer set search_path = ''
as $$ select private.manual_booking(p_module_week_id, p_instructor_id, 'Manual', p_note); $$;

create or replace function public.record_offline_confirmation(p_module_week_id uuid, p_instructor_id uuid, p_note text default null)
returns jsonb language sql security definer set search_path = ''
as $$ select private.manual_booking(p_module_week_id, p_instructor_id, 'Offline', p_note); $$;

create or replace function public.release_booking(p_module_week_id uuid, p_reason text default null, p_restart boolean default true)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_b uuid; v jsonb;
begin
  perform private.require_team();
  select id into v_b from public.booking where module_week_id = p_module_week_id and status = 'Active';
  if v_b is null then raise exception 'There is no confirmed instructor to release.'; end if;
  v := private.release_booking_flow(v_b, 'OpsReleased', private.mw_now(p_module_week_id), p_restart, p_reason);
  perform private.queue_deliver('release');
  return v;
end;
$$;

-- -------------------------------------------------------------------------------------
-- Class changes (PRD 9.9)
-- -------------------------------------------------------------------------------------
-- Move one class to a new start/end and recalculate (used by change time and shift).
create or replace function private.apply_class_time(p_class uuid, p_start timestamptz, p_end timestamptz, p_now timestamptz)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  c public.class_session;
  w public.module_week;
  b public.booking;
  r public.request;
  v_res jsonb := '{}';
begin
  select * into c from public.class_session where id = p_class for update;
  if p_end <= p_start then raise exception 'The class must end after it starts.' using errcode = '22023'; end if;
  if c.starts_at = p_start and c.ends_at = p_end then return jsonb_build_object('unchanged', true); end if;
  update public.class_session set starts_at = p_start, ends_at = p_end where id = p_class;
  update public.module_week set time_version = time_version + 1 where id = c.module_week_id returning * into w;
  perform private.log_event('Team actions', 'Class time changed', 'class_session', p_class,
    jsonb_build_object('starts_at', c.starts_at, 'ends_at', c.ends_at, 'shown', private.fmt_pt_range(c.starts_at, c.ends_at)),
    jsonb_build_object('starts_at', p_start, 'ends_at', p_end, 'shown', private.fmt_pt_range(p_start, p_end)), null,
    w.domain_id, w.module_id, w.id, p_class);

  select * into b from public.booking where module_week_id = w.id and status = 'Active';
  if b.id is not null then
    begin
      update public.booking_slot set time_range = tstzrange(p_start, p_end, '[)') where booking_id = b.id and class_id = p_class;
    exception when exclusion_violation then
      v_res := private.release_booking_flow(b.id, 'TimeClash', p_now, true);
      return jsonb_build_object('released', true, 'reason', 'clash');
    end;
    -- The time-change request (M5) goes out from the engine; run that step now.
    perform private.step_time_changes(w.domain_id, p_now);
    return jsonb_build_object('time_change_request', true);
  end if;

  select * into r from public.request
   where module_week_id = w.id and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded') for update;
  if r.id is not null then
    update public.request set time_version = w.time_version where id = r.id;
    perform private.queue_instructor_message('M5', r.instructor_id, w.id, r.id, p_now,
      private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_pt(r.deadline_at)));
    return jsonb_build_object('updated_request', true);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Change one class's date/time, given in Pacific Time (DST-safe conversion here).
create or replace function public.change_class_time(p_class_id uuid, p_date date, p_start time, p_end time, p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c public.class_session; v jsonb;
begin
  perform private.require_team();
  select * into c from public.class_session where id = p_class_id;
  if p_expected_version is not null and c.version <> p_expected_version then
    raise exception 'This changed — reload. Someone else saved this class after you opened it.' using errcode = '40001';
  end if;
  if c.status <> 'Planned' then raise exception 'Only planned classes can be moved.'; end if;
  v := private.apply_class_time(p_class_id, private.pt_to_utc(p_date, p_start),
         private.pt_to_utc(p_date + case when p_end <= p_start then 1 else 0 end, p_end), private.mw_now(c.module_week_id));
  perform private.queue_deliver('time change');
  return v;
end;
$$;

create or replace function public.update_class_details(p_class_id uuid, p_title text, p_class_type text, p_notes text,
  p_problem_flag boolean, p_expected_version int default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare c public.class_session; w public.module_week;
begin
  perform private.require_team();
  select * into c from public.class_session where id = p_class_id for update;
  if p_expected_version is not null and c.version <> p_expected_version then
    raise exception 'This changed — reload. Someone else saved this class after you opened it.' using errcode = '40001';
  end if;
  update public.class_session set title = coalesce(nullif(trim(p_title), ''), title), class_type = coalesce(p_class_type, class_type),
         notes = p_notes, problem_flag = coalesce(p_problem_flag, problem_flag)
   where id = p_class_id;
  select * into w from public.module_week where id = c.module_week_id;
  perform private.log_event('Team actions', 'Class details edited', 'class_session', p_class_id,
    jsonb_build_object('title', c.title, 'class_type', c.class_type, 'notes', c.notes, 'problem_flag', c.problem_flag),
    jsonb_build_object('title', p_title, 'class_type', p_class_type, 'notes', p_notes, 'problem_flag', p_problem_flag), null,
    w.domain_id, w.module_id, w.id, p_class_id);
end;
$$;

-- Shift this module week (and optionally all later ones in the same domain and cohort) by N weeks (SCH-3).
create or replace function public.shift_classes(p_module_week_id uuid, p_weeks int, p_include_later boolean default true)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w0 public.module_week;
  w record;
  c record;
  n int := 0;
  v_now timestamptz;
begin
  perform private.require_team();
  if p_weeks = 0 or abs(p_weeks) > 26 then raise exception 'Shift by 1 to 26 weeks.'; end if;
  select * into w0 from public.module_week where id = p_module_week_id;
  v_now := private.domain_now(w0.domain_id);
  for w in select mw.* from public.module_week mw
            where mw.domain_id = w0.domain_id and mw.cohort = w0.cohort and mw.status not in ('Completed', 'Cancelled')
              and (mw.id = w0.id or (p_include_later and mw.week_start_date > w0.week_start_date))
            order by case when p_weeks > 0 then mw.week_start_date end desc, case when p_weeks < 0 then mw.week_start_date end asc loop
    update public.module_week set week_start_date = week_start_date + 7 * p_weeks where id = w.id;
    for c in select * from public.class_session where module_week_id = w.id and status = 'Planned' loop
      -- keep the same Pacific wall-clock time across daylight saving changes
      perform private.apply_class_time(c.id,
        private.pt_to_utc((c.starts_at at time zone 'America/Los_Angeles')::date + 7 * p_weeks, (c.starts_at at time zone 'America/Los_Angeles')::time),
        private.pt_to_utc((c.ends_at at time zone 'America/Los_Angeles')::date + 7 * p_weeks, (c.ends_at at time zone 'America/Los_Angeles')::time),
        v_now);
    end loop;
    n := n + 1;
  end loop;
  perform private.log_event('Team actions', 'Shifted ' || n || ' module week(s) by ' || p_weeks || ' week(s)', 'module_week',
    p_module_week_id, null, null, null, w0.domain_id, w0.module_id, w0.id);
  perform private.queue_deliver('shift');
  return jsonb_build_object('ok', true, 'weeks_shifted', n);
end;
$$;

create or replace function public.cancel_module_week(p_module_week_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare w public.module_week; b public.booking; v_now timestamptz;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.status in ('Cancelled', 'Completed') then raise exception 'This module week is already %.', lower(w.status); end if;
  v_now := private.domain_now(w.domain_id);
  perform private.withdraw_open_request(w.id, 'Class cancelled', v_now, true);
  select * into b from public.booking where module_week_id = w.id and status = 'Active' for update;
  if b.id is not null then
    perform private.queue_instructor_message('M11', b.instructor_id, w.id, null, v_now, '[]', '{}', false, 'cancel:' || b.id);
    update public.booking set status = 'Cancelled', released_at = v_now, release_reason = 'Class cancelled' where id = b.id;
  end if;
  update public.request set status = 'Superseded', close_reason = 'Class cancelled'
   where module_week_id = w.id and status in ('Queued', 'Sent', 'Reminded');
  update public.class_session set status = 'Cancelled', cancelled_reason = p_reason where module_week_id = w.id and status = 'Planned';
  update public.module_week set status = 'Cancelled', at_risk = false where id = w.id;
  update public.attention_item set status = 'Done', done_at = now(), done_note = 'Module week cancelled'
   where module_week_id = w.id and status <> 'Done';
  perform private.log_event('Team actions', 'Module week cancelled', 'module_week', w.id, null, null, p_reason,
    w.domain_id, w.module_id, w.id);
  perform private.queue_deliver('cancel');
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.cancel_class(p_class_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c public.class_session; w public.module_week; b public.booking; v_now timestamptz;
begin
  perform private.require_team();
  select * into c from public.class_session where id = p_class_id for update;
  if c.status <> 'Planned' then raise exception 'Only planned classes can be cancelled.'; end if;
  if not exists (select 1 from public.class_session x where x.module_week_id = c.module_week_id and x.status = 'Planned' and x.id <> c.id) then
    return public.cancel_module_week(c.module_week_id, p_reason);
  end if;
  select * into w from public.module_week where id = c.module_week_id;
  v_now := private.domain_now(w.domain_id);
  update public.class_session set status = 'Cancelled', cancelled_reason = p_reason where id = p_class_id;
  select * into b from public.booking where module_week_id = w.id and status = 'Active';
  if b.id is not null then
    update public.booking_slot set active = false where booking_id = b.id and class_id = p_class_id;
    perform private.queue_instructor_message('M11', b.instructor_id, w.id, null, v_now, '[]',
      jsonb_build_object('what', c.title, 'classes', '• ' || c.class_type || ': ' || private.fmt_pt_range(c.starts_at, c.ends_at)),
      false, 'cancelclass:' || c.id);
  end if;
  perform private.log_event('Team actions', 'Class cancelled: ' || c.title, 'class_session', c.id, null, null, p_reason,
    w.domain_id, w.module_id, w.id, c.id);
  perform private.queue_deliver('cancel class');
  return jsonb_build_object('ok', true);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Planning (SCH-1, SCH-4, SCH-5)
-- -------------------------------------------------------------------------------------
-- Propose module weeks for the given Sundays, rotating through the domain's active modules
-- starting with p_start_module_id. Nothing is saved.
create or replace function public.generate_classes(p_domain_id uuid, p_start_module_id uuid, p_week_starts date[], p_cohort text default '')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_mods uuid[];
  v_start int;
  v_out jsonb := '[]';
  i int;
  v_mod uuid;
  v_d date;
  v_classes jsonb;
begin
  perform private.require_team();
  select array_agg(id order by rotation_order, name) into v_mods from public.module where domain_id = p_domain_id and status = 'Active';
  if v_mods is null then raise exception 'This domain has no active modules yet.'; end if;
  v_start := coalesce(array_position(v_mods, p_start_module_id), 1);
  for i in 1 .. coalesce(cardinality(p_week_starts), 0) loop
    v_d := p_week_starts[i];
    v_mod := v_mods[((v_start - 1 + i - 1) % cardinality(v_mods)) + 1];
    select coalesce(jsonb_agg(jsonb_build_object(
             'pattern_item_id', p.id, 'class_type', p.class_type,
             'title', replace(replace(p.title_template, '{module}', m.name), '{class_type}', p.class_type),
             'date', v_d + p.weekday_offset, 'start_time', to_char(p.start_time_pt, 'HH24:MI'),
             'end_time', to_char(p.start_time_pt + make_interval(mins => p.duration_minutes), 'HH24:MI'),
             'starts_at', private.pt_to_utc(v_d + p.weekday_offset, p.start_time_pt),
             'ends_at', private.pt_to_utc(v_d + p.weekday_offset, p.start_time_pt) + make_interval(mins => p.duration_minutes),
             'shown', private.fmt_pt_range(private.pt_to_utc(v_d + p.weekday_offset, p.start_time_pt),
                        private.pt_to_utc(v_d + p.weekday_offset, p.start_time_pt) + make_interval(mins => p.duration_minutes)),
             'holiday', (select h.name from public.holiday h where h.date = v_d + p.weekday_offset))
           order by p.weekday_offset, p.start_time_pt), '[]')
      into v_classes
      from public.class_pattern_item p join public.module m on m.id = p.module_id where p.module_id = v_mod;
    v_out := v_out || jsonb_build_object('week_start_date', v_d, 'module_id', v_mod,
      'module_name', (select name from public.module where id = v_mod), 'cohort', coalesce(p_cohort, ''),
      'classes', v_classes,
      'duplicate', exists (select 1 from public.module_week w where w.module_id = v_mod and w.week_start_date = v_d and w.cohort = coalesce(p_cohort, '')),
      'holidays', (select coalesce(jsonb_agg(h.name), '[]') from public.holiday h where h.date between v_d and v_d + 6));
  end loop;
  return v_out;
end;
$$;

-- Save reviewed module weeks. Duplicates and overlapping classes are refused with a message (SCH-4).
-- p_rows: [{module_id, week_start_date, cohort, classes: [{class_type, title, date, start_time, end_time}]}]
create or replace function public.create_module_weeks(p_domain_id uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  c jsonb;
  v_mw uuid;
  v_ids uuid[] := '{}';
  v_problems text[] := '{}';
  v_start timestamptz;
  v_end timestamptz;
  v_mode text := private.setting_text(p_domain_id, 'default_outreach_mode');
  v_end_b text := private.setting_text(p_domain_id, 'manual_end_behaviour');
begin
  perform private.require_team();
  for r in select * from jsonb_array_elements(p_rows) loop
    if exists (select 1 from public.module_week w where w.module_id = (r ->> 'module_id')::uuid
                and w.week_start_date = (r ->> 'week_start_date')::date and w.cohort = coalesce(r ->> 'cohort', '')) then
      v_problems := v_problems || ('Already planned: ' || (select name from public.module where id = (r ->> 'module_id')::uuid)
        || ' for the week of ' || to_char((r ->> 'week_start_date')::date, 'Mon FMDD, YYYY') || coalesce(' (cohort ' || nullif(r ->> 'cohort', '') || ')', ''));
    end if;
    if (select domain_id from public.module where id = (r ->> 'module_id')::uuid) is distinct from p_domain_id then
      v_problems := v_problems || 'A module does not belong to this domain.'::text;
    end if;
  end loop;
  if cardinality(v_problems) > 0 then
    raise exception '%', array_to_string(v_problems, E'\n') using errcode = '23505';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    insert into public.module_week (module_id, week_start_date, cohort, outreach_mode, manual_end_behaviour)
    values ((r ->> 'module_id')::uuid, (r ->> 'week_start_date')::date, coalesce(r ->> 'cohort', ''), v_mode, v_end_b)
    returning id into v_mw;
    v_ids := v_ids || v_mw;
    for c in select * from jsonb_array_elements(r -> 'classes') loop
      v_start := private.pt_to_utc((c ->> 'date')::date, (c ->> 'start_time')::time);
      v_end := private.pt_to_utc((c ->> 'date')::date + case when (c ->> 'end_time')::time <= (c ->> 'start_time')::time then 1 else 0 end,
                                 (c ->> 'end_time')::time);
      if exists (select 1 from public.class_session x join public.module_week xw on xw.id = x.module_week_id
                  where xw.domain_id = p_domain_id and xw.cohort = coalesce(r ->> 'cohort', '') and x.status = 'Planned'
                    and xw.id <> v_mw and tstzrange(x.starts_at, x.ends_at, '[)') && tstzrange(v_start, v_end, '[)')) then
        v_problems := v_problems || ('Overlaps an existing class: ' || coalesce(c ->> 'title', '') || ' on ' || private.fmt_pt_range(v_start, v_end));
      end if;
      insert into public.class_session (module_week_id, pattern_item_id, class_type, title, starts_at, ends_at)
      values (v_mw, nullif(c ->> 'pattern_item_id', '')::uuid, coalesce(c ->> 'class_type', 'Other'),
              coalesce(nullif(c ->> 'title', ''), 'Class'), v_start, v_end);
    end loop;
  end loop;
  if cardinality(v_problems) > 0 then
    raise exception '%', array_to_string(v_problems, E'\n') using errcode = '23P01';
  end if;
  perform private.log_event('Team actions', 'Planned ' || cardinality(v_ids) || ' module week(s)', 'domain', p_domain_id,
    null, jsonb_build_object('module_week_ids', to_jsonb(v_ids)), null, p_domain_id);
  return jsonb_build_object('ok', true, 'created', cardinality(v_ids), 'module_week_ids', to_jsonb(v_ids));
end;
$$;

create or replace function public.set_checklist_item(p_item_id uuid, p_done boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare ci public.checklist_item; w public.module_week;
begin
  perform private.require_team();
  update public.checklist_item set done = p_done, done_by = case when p_done then private.current_team_member_id() end,
         done_at = case when p_done then now() end
   where id = p_item_id returning * into ci;
  select mw.* into w from public.class_session c join public.module_week mw on mw.id = c.module_week_id where c.id = ci.class_id;
  perform private.log_event('Team actions', 'Checklist: ' || ci.label || case when p_done then ' done' else ' not done' end,
    'checklist_item', ci.id, null, null, null, w.domain_id, w.module_id, w.id, ci.class_id);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Attention items (PRD 7.3)
-- -------------------------------------------------------------------------------------
create or replace function public.attention_ack(p_item_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare a public.attention_item; v_me uuid := private.current_team_member_id();
begin
  perform private.require_team();
  update public.attention_item set status = 'Acknowledged', acknowledged_by = v_me,
         ack_until = coalesce(private.domain_now(domain_id), now()) + interval '24 hours',
         assigned_to = coalesce(assigned_to, v_me)
   where id = p_item_id and status <> 'Done' returning * into a;
  perform private.log_event('Team actions', 'I''m on it: ' || a.title, 'attention_item', a.id, null, null, null,
    a.domain_id, a.module_id, a.module_week_id);
end;
$$;

create or replace function public.attention_assign(p_item_id uuid, p_team_member_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare a public.attention_item;
begin
  perform private.require_team();
  update public.attention_item set assigned_to = p_team_member_id where id = p_item_id returning * into a;
  perform private.log_event('Team actions', 'Assigned to ' || private.team_names(array[p_team_member_id]) || ': ' || a.title,
    'attention_item', a.id, null, null, null, a.domain_id, a.module_id, a.module_week_id);
end;
$$;

create or replace function public.attention_done(p_item_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare a public.attention_item;
begin
  perform private.require_team();
  update public.attention_item set status = 'Done', done_at = now(), done_by = private.current_team_member_id(), done_note = p_note
   where id = p_item_id returning * into a;
  perform private.log_event('Team actions', 'Marked done: ' || a.title, 'attention_item', a.id, null, null, p_note,
    a.domain_id, a.module_id, a.module_week_id);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Help requests in the app (PRD 10.6)
-- -------------------------------------------------------------------------------------
create or replace function public.create_help_request(p_module_week_id uuid, p_categories text[], p_details text,
  p_urgency text default 'NoRush', p_reply_channel text default 'Either')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_instr uuid;
begin
  perform private.require_team();
  select instructor_id into v_instr from public.booking where module_week_id = p_module_week_id and status = 'Active';
  return private.create_help_request(p_module_week_id, v_instr, case when v_instr is null then private.current_team_member_id() end,
    'Ops', p_categories, p_details, p_urgency, p_reply_channel, private.mw_now(p_module_week_id));
end;
$$;

create or replace function public.help_ack(p_help_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare h public.help_request; v_me uuid := private.current_team_member_id();
begin
  perform private.require_team();
  update public.help_request set status = 'InProgress', assigned_to = coalesce(v_me, assigned_to)
   where id = p_help_id and status in ('Open', 'WaitingOnInstructor') returning * into h;
  update public.attention_item set status = 'Acknowledged', acknowledged_by = v_me, assigned_to = coalesce(v_me, assigned_to),
         ack_until = now() + interval '24 hours'
   where dedupe_key = 'help:' || p_help_id and status <> 'Done';
  perform private.log_event('Help requests', 'I''m on it', 'help_request', p_help_id, null, null, null,
    h.domain_id, null, h.module_week_id);
end;
$$;

create or replace function public.help_reply(p_help_id uuid, p_text text, p_resolves boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  h public.help_request;
  v_now timestamptz;
  v_req uuid;
  v_from text := coalesce((select t.name from public.team_member t where t.id = private.current_team_member_id()), 'SME Scheduling');
begin
  perform private.require_team();
  if coalesce(trim(p_text), '') = '' then raise exception 'Write a reply first.'; end if;
  select * into h from public.help_request where id = p_help_id for update;
  v_now := private.mw_now(h.module_week_id);
  if h.requester_instructor_id is not null then
    select r.id into v_req from public.request r join public.booking b on b.request_id = r.id
     where b.module_week_id = h.module_week_id and b.status = 'Active' and b.instructor_id = h.requester_instructor_id;
    perform private.queue_instructor_message('M14', h.requester_instructor_id, h.module_week_id, null, v_now,
      case when v_req is not null then private.buttons(v_req, array['NeedMoreHelp']) else '[]'::jsonb end,
      jsonb_build_object('text', p_text, 'from', v_from), false, 'reply:' || h.id || ':' || extract(epoch from clock_timestamp())::bigint,
      h.id, case h.reply_channel when 'Discord' then 'Discord' when 'Email' then 'Email' end);
  elsif h.requester_team_member_id is not null then
    perform private.queue_team_message('M14', h.domain_id, 'person', h.requester_team_member_id, '{}',
      'Reply to your help request', p_text || E'\n— ' || v_from,
      'M14:' || h.id || ':' || extract(epoch from clock_timestamp())::bigint, v_now, false, null, h.module_week_id, h.id);
  end if;
  update public.help_request
     set status = case when p_resolves then 'Resolved' else 'WaitingOnInstructor' end,
         first_response_at = coalesce(first_response_at, v_now),
         resolved_at = case when p_resolves then v_now end,
         assigned_to = coalesce(assigned_to, private.current_team_member_id())
   where id = h.id;
  if p_resolves then
    perform private.resolve_attention('help:' || h.id, 'Resolved with a reply');
  else
    update public.attention_item set status = 'Acknowledged', ack_until = now() + interval '24 hours'
     where dedupe_key = 'help:' || h.id and status <> 'Done';
  end if;
  perform private.log_event('Help requests', 'Replied' || case when p_resolves then ' and resolved' else '' end, 'help_request', h.id,
    null, jsonb_build_object('text', p_text), null, h.domain_id, null, h.module_week_id);
  perform private.queue_deliver('help reply');
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.help_set_status(p_help_id uuid, p_status text, p_note text)
returns void language plpgsql security definer set search_path = ''
as $$
declare h public.help_request;
begin
  perform private.require_team();
  if p_status not in ('Resolved', 'Closed') then raise exception 'Status must be Resolved or Closed.'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Add a short note.'; end if;
  update public.help_request set status = p_status, resolved_at = now(), resolution_note = p_note
   where id = p_help_id returning * into h;
  perform private.resolve_attention('help:' || p_help_id, p_status || ': ' || p_note);
  perform private.log_event('Help requests', p_status, 'help_request', p_help_id, null, null, p_note, h.domain_id, null, h.module_week_id);
end;
$$;

create or replace function public.help_reassign(p_help_id uuid, p_team_member_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare h public.help_request;
begin
  perform private.require_team();
  update public.help_request set assigned_to = p_team_member_id where id = p_help_id returning * into h;
  update public.attention_item set assigned_to = p_team_member_id where dedupe_key = 'help:' || p_help_id and status <> 'Done';
  perform private.log_event('Help requests', 'Reassigned to ' || private.team_names(array[p_team_member_id]), 'help_request',
    p_help_id, null, null, null, h.domain_id, null, h.module_week_id);
end;
$$;

create or replace function public.help_convert_to_cancellation(p_help_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare h public.help_request; v_b uuid; v jsonb;
begin
  perform private.require_team();
  select * into h from public.help_request where id = p_help_id for update;
  select id into v_b from public.booking where module_week_id = h.module_week_id and status = 'Active';
  if v_b is null then raise exception 'There is no active booking to cancel.'; end if;
  update public.help_request set status = 'ConvertedToCancellation', resolved_at = now(), resolution_note = 'Converted to cancellation'
   where id = h.id;
  perform private.resolve_attention('help:' || h.id, 'Converted to cancellation');
  perform private.log_event('Help requests', 'Converted to cancellation', 'help_request', h.id, null, null, null,
    h.domain_id, null, h.module_week_id);
  v := private.release_booking_flow(v_b, 'InstructorCancelled', private.mw_now(h.module_week_id));
  perform private.queue_deliver('help cancellation');
  return v;
end;
$$;

-- -------------------------------------------------------------------------------------
-- Settings, system switches, test mode (PRD 7.8, TST, SYS)
-- -------------------------------------------------------------------------------------
create or replace function public.set_setting(p_domain_id uuid, p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  insert into public.setting (scope, domain_id, key, value)
  values (case when p_domain_id is null then 'Global' else 'Domain' end, p_domain_id, p_key, p_value)
  on conflict (key, coalesce(domain_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set value = excluded.value;
end;
$$;

create or replace function public.reset_setting(p_domain_id uuid, p_key text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  delete from public.setting where key = p_key and domain_id is not distinct from p_domain_id;
end;
$$;

-- Effective settings for a domain, with defaults, for the Settings tab.
create or replace function public.effective_settings(p_domain_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', d.key, 'group', d.group_name, 'label', d.label, 'type', d.value_type,
           'value', private.get_setting(p_domain_id, d.key), 'default', d.default_value, 'min', d.min_value, 'max', d.max_value,
           'allowed', d.allowed, 'help', d.help,
           'overridden', exists (select 1 from public.setting s where s.key = d.key and s.domain_id = p_domain_id))
         order by d.sort_order), '[]')
    from public.setting_definition d
   where private.is_team_user() or private.is_service();
$$;

create or replace function public.set_kill_switch(p_outreach_enabled boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  update public.system_state set outreach_enabled = p_outreach_enabled, kill_switch_changed_at = now(),
         kill_switch_changed_by = private.current_team_member_id()
   where id = 1;
  perform private.log_event('System', case when p_outreach_enabled then 'Kill switch OFF — outreach resumed'
                                           else 'Kill switch ON — all instructor messages paused' end);
  if p_outreach_enabled then perform private.queue_deliver('kill switch off'); end if;
end;
$$;

create or replace function public.set_domain_status(p_domain_id uuid, p_status text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  update public.domain set status = p_status,
         test_clock_at = case when p_status = 'Test' then test_clock_at end
   where id = p_domain_id;
end;
$$;

create or replace function private.require_test_domain(p_domain uuid)
returns void language plpgsql stable security definer set search_path = ''
as $$
begin
  if (select status from public.domain where id = p_domain) is distinct from 'Test' then
    raise exception 'The test clock only works while the domain is in test mode.';
  end if;
end;
$$;

create or replace function public.set_test_clock(p_domain_id uuid, p_at timestamptz)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  perform private.require_test_domain(p_domain_id);
  update public.domain set test_clock_at = p_at where id = p_domain_id;
  perform private.log_event('System', case when p_at is null then 'Test clock cleared (real time)' else 'Test clock set to ' || private.fmt_pt(p_at) end,
    'domain', p_domain_id, null, null, null, p_domain_id, null, null, null, null, null, true);
end;
$$;

-- Advance the test clock and run the hourly check once (TST-2).
create or replace function public.advance_test_clock(p_domain_id uuid, p_hours int)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_at timestamptz;
begin
  perform private.require_team();
  perform private.require_test_domain(p_domain_id);
  v_at := coalesce((select test_clock_at from public.domain where id = p_domain_id), now()) + make_interval(hours => p_hours);
  perform public.set_test_clock(p_domain_id, v_at);
  return public.run_check_now(p_domain_id);
end;
$$;

-- "Jump to: readiness / 30 / 14 / 10 / 2 days before" a module week, then run the check.
create or replace function public.jump_test_clock(p_domain_id uuid, p_module_week_id uuid, p_days_before int)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_first timestamptz;
begin
  perform private.require_team();
  perform private.require_test_domain(p_domain_id);
  select first_class_at into v_first from public.module_week where id = p_module_week_id and domain_id = p_domain_id;
  if v_first is null then raise exception 'Pick a module week with classes in this domain.'; end if;
  perform public.set_test_clock(p_domain_id, v_first - make_interval(days => p_days_before));
  return public.run_check_now(p_domain_id);
end;
$$;

create or replace function public.run_check_now(p_domain_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  perform private.require_team();
  v := public.engine_tick(p_domain_id, null);
  perform private.queue_deliver('run check now');
  return v;
end;
$$;

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

-- -------------------------------------------------------------------------------------
-- Undo for setup changes (HIS-3) — only when still safe; never recalls messages already sent.
-- -------------------------------------------------------------------------------------
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
       'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'setting', 'holiday') then
    raise exception 'This kind of change can''t be undone.';
  end if;

  if e.action = 'Ranking saved' then
    select coalesce(jsonb_agg(instructor_id order by rank), '[]') into v_cur from public.module_ranking where module_id = e.entity_id;
    if v_cur <> (e.after -> 'instructor_ids') then
      raise exception 'The ranking changed again since then, so undo isn''t safe. Edit it directly instead.';
    end if;
    perform public.save_ranking(e.entity_id, array(select (x #>> '{}')::uuid from jsonb_array_elements(e.before -> 'instructor_ids') x));
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

-- -------------------------------------------------------------------------------------
-- Grants: app functions for signed-in company users (checked inside) and n8n.
-- -------------------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'send_test_message(uuid)', 'mark_verified_manually(uuid, text)', 'deactivate_instructor(uuid, jsonb, text)',
    'save_ranking(uuid, uuid[], uuid[])', 'ranking_impact(uuid, uuid[])', 'preview_next(uuid)', 'week_eligibility(uuid)',
    'set_outreach_queue(uuid, text, uuid[], text, text, boolean)', 'pause_outreach(uuid, boolean)', 'skip_to_next(uuid)',
    'assign_manually(uuid, uuid, text)', 'record_offline_confirmation(uuid, uuid, text)', 'release_booking(uuid, text, boolean)',
    'change_class_time(uuid, date, time, time, int)', 'update_class_details(uuid, text, text, text, boolean, int)',
    'shift_classes(uuid, int, boolean)', 'cancel_module_week(uuid, text)', 'cancel_class(uuid, text)',
    'generate_classes(uuid, uuid, date[], text)', 'create_module_weeks(uuid, jsonb)', 'set_checklist_item(uuid, boolean)',
    'attention_ack(uuid)', 'attention_assign(uuid, uuid)', 'attention_done(uuid, text)',
    'create_help_request(uuid, text[], text, text, text)', 'help_ack(uuid)', 'help_reply(uuid, text, boolean)',
    'help_set_status(uuid, text, text)', 'help_reassign(uuid, uuid)', 'help_convert_to_cancellation(uuid)',
    'set_setting(uuid, text, jsonb)', 'reset_setting(uuid, text)', 'effective_settings(uuid)', 'set_kill_switch(boolean)',
    'set_domain_status(uuid, text)', 'set_test_clock(uuid, timestamptz)', 'advance_test_clock(uuid, int)',
    'jump_test_clock(uuid, uuid, int)', 'run_check_now(uuid)', 'send_test_alert(uuid)', 'undo_history_event(bigint)',
    'engine_tick(uuid, timestamptz)']
  loop
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end;
$$;
