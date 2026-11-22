-- Rollback of 20261122000009_sooner_class_first.sql: the previous asking rules (decision 296).
-- The functions below are copied byte for byte from the migrations that defined them last before M7, line endings
-- included, so the rollback check compares like with like (Git stores both files with plain line endings).

create or replace function private.week_history_reason(p_instructor uuid, p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select case
              when r.status in ('Sent', 'Reminded', 'Queued') then 'Being asked now'
              when r.status = 'Declined' and r.close_reason = 'Clash' then 'Had a clash when they said yes'
              when r.status = 'Declined' then 'Already declined this module week'
              when r.status = 'Expired' then 'Did not reply earlier'
              when r.status = 'Withdrawn' then 'Skipped by ops'
            end
       from public.request r
      where r.module_week_id = p_mw and r.instructor_id = p_instructor and r.kind = 'Outreach'
        and (r.status in ('Sent', 'Reminded', 'Queued', 'Declined', 'Expired')
             or (r.status = 'Withdrawn' and r.close_reason in ('Skipped', 'Outreach changed by ops')))
      order by (r.status in ('Sent', 'Reminded', 'Queued')) desc, r.created_at desc limit 1),
    (select 'Cancelled this module week earlier' from public.booking b
      where b.module_week_id = p_mw and b.instructor_id = p_instructor and b.status = 'Released' limit 1));
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
      perform private.log_event('System', 'Nobody left to ask', 'module_week', p_mw, null, null,
        nullif(v_skips, ''), w.domain_id, w.module_id, p_mw, null, null, null, v_test);
    end if;
    -- Only one open task per class week: "Nobody left to ask" replaces "Class at risk" (decision 271).
    perform private.close_at_risk_for(p_mw, p_now);
    perform private.raise_attention(w.domain_id, 'RankingExhausted', 'Urgent',
      'Needs instructor: ' || private.mw_label(p_mw),
      'Everyone in line has been asked or can''t be asked. Assign someone manually or add instructors to the instructor order.'
        || coalesce(E'\nSkipped: ' || nullif(v_skips, ''), ''),
      'exhausted:' || p_mw, private.recipients_for_week(p_mw, true), p_now, private.mw_refs(p_mw),
      true, 'T4');
    return null;
  end if;

  v_win := private.window_hours(p_mw, p_now);
  v_urgent := v_win.band = 'Short';
  v_send := private.instructor_send_time(w.id, p_now, v_urgent, private.week_region(p_mw));
  v_deadline := least(private.instructor_send_time(w.id, v_send + make_interval(hours => v_win.move_h), v_urgent, private.week_region(p_mw)),
                      w.first_class_at);
  insert into public.request (module_week_id, instructor_id, kind, status, time_version, line_source,
    declined_before, sent_at, reminder_at, deadline_at, is_test)
  values (p_mw, v_pick.instructor_id, 'Outreach', 'Sent', w.time_version, v_pick.source,
    v_pick.warning is not null, v_send,
    case when v_win.reminder_h is null then null else least(private.instructor_send_time(w.id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(p_mw)), v_deadline) end,
    v_deadline, v_test)
  returning id into v_req;
  if v_pick.queue_item_id is not null then
    update public.manual_queue_item set asked_request_id = v_req where id = v_pick.queue_item_id;
  end if;
  perform private.queue_instructor_message('M1', v_pick.instructor_id, p_mw, v_req, p_now,
    private.buttons(v_req, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local(v_deadline, private.week_region(p_mw))), v_urgent);

  v_first := w.outreach_started_at is null;
  update public.module_week
     set status = 'Asking', outreach_started_at = coalesce(outreach_started_at, p_now)
   where id = p_mw;
  perform private.log_event('Messages', 'Asked ' || v_pick.full_name, 'request', v_req, null,
    jsonb_build_object('deadline', v_deadline, 'band', v_win.band, 'source', v_pick.source),
    nullif('Skipped: ' || v_skips, 'Skipped: '), w.domain_id, w.module_id, p_mw, null, v_pick.instructor_id, null, v_test);
  if v_first then
    perform private.queue_team_message('T1', w.domain_id, 'alert', null, private.owners_or_leads(w.module_id),
      'Asking started: ' || private.mw_label(p_mw),
      '📣 Asking started for ' || private.mw_label(p_mw) || ': asking ' || v_pick.full_name || '.',
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

drop function if exists private.sooner_class_reason(uuid, uuid);
drop function if exists private.competing_requests(uuid, uuid);
drop function if exists private.week_sooner(uuid, uuid);
drop index if exists public.request_open_outreach_instructor_idx;
