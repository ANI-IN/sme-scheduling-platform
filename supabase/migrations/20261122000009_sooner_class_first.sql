-- Release 3, M7 part 1 (decision 296): Primary first, the sooner class wins.
--
-- Before: one instructor could be asked for two class weeks at overlapping times (only confirmed bookings were
-- compared), whoever answered first won, and after "Yes" came too late because of a clash that instructor was never
-- asked for that week again, even when the clash went away.
--
-- Now:
-- 1. Nobody has two open requests for classes that overlap in real time (UTC), across cohorts, domains and regions.
-- 2. The class week whose first class is sooner gets the instructor first (on a tie: the cohort that started first,
--    then the cohort's name, then the week). A later week skips them with "Being asked for a sooner class: ..." and
--    asks its next instructor; when the sooner week asks someone who is being asked for a later week, that request
--    is withdrawn ("Sooner class") and the later week asks its next instructor at once. A confirmed booking is never
--    taken away.
-- 3. The skip after "Yes" with a clash lasts only while the clash does (the clash itself is still checked each time).
-- 4. Asking takes a short lock per instructor and checks again, so two runs at the same moment (the hourly check and
--    an Ops action, or two domains) cannot both ask the same person.

create index if not exists request_open_outreach_instructor_idx on public.request (instructor_id)
  where kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded');

-- Is class week a ahead of class week b? Sooner first class, then the cohort that started first, then its name.
create or replace function private.week_sooner(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select (coalesce(a.first_class_at, 'infinity'), coalesce(ca.start_date, 'infinity'::date), coalesce(ca.name, ''), a.id)
       < (coalesce(b.first_class_at, 'infinity'), coalesce(cb.start_date, 'infinity'::date), coalesce(cb.name, ''), b.id)
    from public.module_week a left join public.cohort ca on ca.id = a.cohort_id,
         public.module_week b left join public.cohort cb on cb.id = b.cohort_id
   where a.id = p_a and b.id = p_b;
$$;

-- Open requests to this instructor for other class weeks whose classes overlap this week's classes in UTC.
create or replace function private.competing_requests(p_instructor uuid, p_mw uuid)
returns table (request_id uuid, module_week_id uuid, sooner boolean, label text)
language sql stable security definer set search_path = ''
as $$
  select r.id, r.module_week_id, private.week_sooner(r.module_week_id, p_mw), private.mw_label(r.module_week_id)
    from public.request r
   where r.instructor_id = p_instructor and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')
     and r.module_week_id <> p_mw
     and exists (select 1 from public.class_session a join public.class_session b
                     on tstzrange(a.starts_at, a.ends_at, '[)') && tstzrange(b.starts_at, b.ends_at, '[)')
                  where a.module_week_id = r.module_week_id and b.module_week_id = p_mw
                    and a.status <> 'Cancelled' and b.status <> 'Cancelled');
$$;

-- The reason a later week skips this instructor, or null.
create or replace function private.sooner_class_reason(p_instructor uuid, p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select 'Being asked for a sooner class: ' || c.label
    from private.competing_requests(p_instructor, p_mw) c where c.sooner
   limit 1;
$$;

-- 3. "Yes" with a clash no longer sticks: only the clash itself (checked by eligibility) keeps them out.
create or replace function private.week_history_reason(p_instructor uuid, p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select case
              when r.status in ('Sent', 'Reminded', 'Queued') then 'Being asked now'
              when r.status = 'Declined' then 'Already declined this module week'
              when r.status = 'Expired' then 'Did not reply earlier'
              when r.status = 'Withdrawn' then 'Skipped by ops'
            end
       from public.request r
      where r.module_week_id = p_mw and r.instructor_id = p_instructor and r.kind = 'Outreach'
        and ((r.status in ('Sent', 'Reminded', 'Queued', 'Expired'))
             or (r.status = 'Declined' and r.close_reason is distinct from 'Clash')
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
      reason := coalesce(private.eligibility(r.iid, p_mw), case when v_hist = 'Being asked now' then v_hist end,
                         private.sooner_class_reason(r.iid, p_mw));
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
    reason := coalesce(private.eligibility(r.iid, p_mw), private.week_history_reason(r.iid, p_mw),
                       private.sooner_class_reason(r.iid, p_mw));
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
  v_now_reason text;
  c record;
  v_later uuid[] := '{}';
  v_sent boolean;
  v_lw uuid;
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
      -- M7: one asking at a time per instructor, then check again with what other runs have just saved.
      perform pg_advisory_xact_lock(hashtextextended('ask:' || l.instructor_id::text, 0));
      v_now_reason := private.sooner_class_reason(l.instructor_id, p_mw);
      if v_now_reason is null then
        v_pick := l;
        v_found := true;
        exit;
      end if;
      v_skips := v_skips || l.full_name || ' — ' || v_now_reason || '; ';
    elsif l.reason not in ('Already declined this module week', 'Did not reply earlier', 'Skipped by ops',
                           'Cancelled this module week earlier', 'Being asked now') then
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

  -- M7: this week is sooner, so a later week that is asking the same person at an overlapping time lets them go.
  -- They hear "no longer needed" only if that request had already reached them.
  for c in select * from private.competing_requests(v_pick.instructor_id, p_mw) where not sooner loop
    v_sent := exists (select 1 from public.message m where m.request_id = c.request_id and m.template_id = 'M1'
                        and m.status in ('Sending', 'Sent'));
    if private.withdraw_open_request(c.module_week_id, 'Sooner class', p_now, v_sent) is not null then
      v_later := v_later || c.module_week_id;
      perform private.log_event('Messages', 'Sooner class first: ' || v_pick.full_name, 'module_week', c.module_week_id,
        null, jsonb_build_object('sooner_week', p_mw, 'sooner', private.mw_label(p_mw), 'told', v_sent),
        v_pick.full_name || ' is needed for a sooner class at the same time (' || private.mw_label(p_mw)
          || '), so this class week asks its next instructor.',
        (select x.domain_id from public.module_week x where x.id = c.module_week_id),
        (select x.module_id from public.module_week x where x.id = c.module_week_id),
        c.module_week_id, null, v_pick.instructor_id, null, v_test);
    end if;
  end loop;

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

  -- The later weeks ask their next instructor now (each is later, so this always ends).
  foreach v_lw in array v_later loop
    perform private.ask_next(v_lw, p_now);
  end loop;
  return v_req;
end;
$$;

-- The instructor list on a class week shows the same reason.
create or replace function public.week_eligibility(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_module uuid; v_cohort uuid;
begin
  perform private.require_team();
  select module_id, private.order_cohort(module_id, cohort_id) into v_module, v_cohort from public.module_week where id = p_module_week_id;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'instructor_id', i.id, 'name', i.full_name, 'rank', k.rank, 'in_ranking', k.rank is not null,
            'reason', coalesce(private.eligibility(i.id, p_module_week_id), private.sooner_class_reason(i.id, p_module_week_id)),
            'warning', coalesce(private.week_history_reason(i.id, p_module_week_id), private.instructor_soft_warning(i.id, p_module_week_id)), 'is_test', i.is_test)
          order by k.rank nulls last, i.full_name), '[]')
     from public.instructor i left join public.module_ranking k on k.instructor_id = i.id and k.module_id = v_module and k.cohort_id is not distinct from v_cohort
    where i.status <> 'Archived');
end;
$$;

revoke execute on function private.week_sooner(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.competing_requests(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.sooner_class_reason(uuid, uuid) from public, anon, authenticated;
