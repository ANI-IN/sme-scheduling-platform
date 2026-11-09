-- =====================================================================================
-- Milestone 2b — Automation engine (PRD §9, §10, §13). All decisions live here.
-- engine_tick(domain, now) does everything the hourly check decides for one domain.
-- =====================================================================================

alter table public.help_request add column raised_at timestamptz not null default now();

-- Several rows are often created in one engine transaction (decline → next ask); keep their real order.
alter table public.request alter column created_at set default clock_timestamp();
alter table public.message alter column created_at set default clock_timestamp();
alter table public.booking alter column created_at set default clock_timestamp();
alter table public.attention_item alter column created_at set default clock_timestamp();
alter table public.help_request alter column created_at set default clock_timestamp();
alter table public.history_event alter column at set default clock_timestamp();
alter table public.system_state add column last_digest_date date;

-- -------------------------------------------------------------------------------------
-- Who can be asked (PRD 9.3, BR-7)
-- -------------------------------------------------------------------------------------
-- Reason an instructor can't be asked/booked for a module week right now, or null if they can.
create or replace function private.eligibility(p_instructor uuid, p_mw uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_domain uuid;
  v_status text;
  v_reason text;
begin
  select * into i from public.instructor where id = p_instructor;
  select w.domain_id, d.status into v_domain, v_status
    from public.module_week w join public.domain d on d.id = w.domain_id where w.id = p_mw;
  if i.id is null then return 'Unknown instructor'; end if;
  if i.status = 'Inactive' then return 'Inactive'; end if;
  if i.status = 'Archived' then return 'Archived'; end if;
  if v_status = 'Live' and i.is_test then return 'Test instructor (not allowed in Live domains)'; end if;
  if v_status = 'Live' and i.verified_at is null then return 'Not verified'; end if;
  if i.discord_channel_id is null and i.email_bounced_at is not null then return 'No working contact details'; end if;

  select 'Unavailable ' || to_char(u.from_date, 'Mon FMDD') || ' – ' || to_char(u.to_date, 'Mon FMDD')
    into v_reason
    from public.instructor_unavailability u
   where u.instructor_id = p_instructor
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and (c.starts_at at time zone 'America/Los_Angeles')::date between u.from_date and u.to_date)
   order by u.from_date limit 1;
  if v_reason is not null then return v_reason; end if;

  select 'Teaching ' || case when w2.domain_id <> v_domain then d2.name else m2.name end || ' at this time'
    into v_reason
    from public.booking_slot s
    join public.booking b on b.id = s.booking_id
    join public.module_week w2 on w2.id = b.module_week_id
    join public.module m2 on m2.id = w2.module_id
    join public.domain d2 on d2.id = w2.domain_id
   where s.instructor_id = p_instructor and s.active and b.module_week_id <> p_mw
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and tstzrange(c.starts_at, c.ends_at, '[)') && s.time_range)
   limit 1;
  return v_reason;
end;
$$;

-- Already asked / declined for this module week (excluded in sequential mode; a warning in manual mode).
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

-- The line of instructors for a module week, in order, with the reason each one would be skipped.
-- Shared by the engine (ask_next) and the app previews, so "who will be asked next" matches behaviour.
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
            where k.module_id = w.module_id
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

-- Readiness check (PRD 9.2 at 45 days): list of problems; blocking ones stop outreach (OUT-10).
create or replace function private.readiness_problems(p_mw uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  w public.module_week;
  m public.module;
  v jsonb := '[]';
begin
  select * into w from public.module_week where id = p_mw;
  select * into m from public.module where id = w.module_id;
  if not exists (select 1 from public.class_session c where c.module_week_id = p_mw and c.status = 'Planned') then
    v := v || jsonb_build_object('code', 'no_classes', 'text', 'No classes planned for this week', 'blocking', true);
  end if;
  if m.status <> 'Active' then
    v := v || jsonb_build_object('code', 'module_inactive', 'text', 'The module is not active', 'blocking', true);
  end if;
  if cardinality(private.module_owner_ids(m.id)) = 0 then
    v := v || jsonb_build_object('code', 'no_owner', 'text', 'No owner set for the module', 'blocking', true);
  end if;
  if not exists (select 1 from private.build_line(p_mw) l where l.reason is null) then
    v := v || jsonb_build_object('code', 'no_instructor',
      'text', 'Nobody in line is active, verified, available and free at that time', 'blocking', true);
  end if;
  if not exists (select 1 from public.module_resource r where r.module_id = m.id) then
    v := v || jsonb_build_object('code', 'no_resources', 'text', 'No resources added for the module', 'blocking', false);
  end if;
  return v;
end;
$$;

-- Response window hours for the module week's band (PRD 9.4).
create or replace function private.window_hours(p_mw uuid, p_now timestamptz, out band text, out reminder_h int, out move_h int)
language plpgsql stable security definer set search_path = ''
as $$
declare v_dom uuid := (select w.domain_id from public.module_week w where w.id = p_mw);
begin
  band := private.band(p_mw, p_now);
  reminder_h := private.setting_int(v_dom, case band when 'Long' then 'window_long_reminder_h' when 'Mid' then 'window_mid_reminder_h' else 'window_short_reminder_h' end);
  move_h := private.setting_int(v_dom, case band when 'Long' then 'window_long_move_h' when 'Mid' then 'window_mid_move_h' else 'window_short_move_h' end);
end;
$$;

create or replace function private.instructor_messages_allowed(p_domain uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select (select s.outreach_enabled from public.system_state s where s.id = 1)
     and coalesce((select d.status in ('Test', 'Live') from public.domain d where d.id = p_domain), false);
$$;

create or replace function private.recipients_for_week(p_mw uuid, p_with_ops boolean, p_with_leads boolean default false)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select private.uniq(private.owners_or_leads(w.module_id)
         || case when p_with_ops then private.domain_role_ids(w.domain_id, 'Ops') else '{}'::uuid[] end
         || case when p_with_leads then private.domain_role_ids(w.domain_id, 'Lead') else '{}'::uuid[] end)
    from public.module_week w where w.id = p_mw;
$$;

create or replace function private.mw_refs(p_mw uuid, p_extra jsonb default '{}')
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('module_week_id', w.id, 'module_id', w.module_id) || p_extra
    from public.module_week w where w.id = p_mw;
$$;

-- -------------------------------------------------------------------------------------
-- Asking the next instructor (PRD 9.3). Never more than one open request per module week.
-- -------------------------------------------------------------------------------------
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
  if w.status in ('Cancelled', 'Completed') or w.paused or w.first_class_at is null or w.first_class_at <= p_now then
    return null;
  end if;
  if not private.instructor_messages_allowed(w.domain_id) then
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
  v_test := coalesce((select d.status = 'Test' from public.domain d where d.id = w.domain_id), false);

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
      'Under ' || private.setting_int(w.domain_id, 'urgent_band_days') || ' days and no instructor yet: ' || private.mw_label(p_mw),
      'Now asking ' || v_pick.full_name || ' (moves on after ' || v_win.move_h || 'h). Consider phoning people too.',
      'urgentfill:' || p_mw, private.recipients_for_week(p_mw, true), p_now, private.mw_refs(p_mw));
  end if;
  return v_req;
end;
$$;

-- Withdraw the open outreach request (politely, M12) — used by skip, mode switch, deactivation, cancel.
create or replace function private.withdraw_open_request(p_mw uuid, p_reason text, p_now timestamptz, p_notify boolean default true)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare r public.request;
begin
  update public.request set status = 'Withdrawn', close_reason = p_reason, answered_at = null
   where module_week_id = p_mw and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded')
  returning * into r;
  if r.id is null then return null; end if;
  if p_notify then
    perform private.queue_instructor_message('M12', r.instructor_id, p_mw, r.id, p_now);
  end if;
  perform private.log_event('Messages', 'Request withdrawn: ' || (select i.full_name from public.instructor i where i.id = r.instructor_id),
    'request', r.id, null, jsonb_build_object('reason', p_reason), null,
    (select w.domain_id from public.module_week w where w.id = p_mw), null, p_mw, null, r.instructor_id, null, r.is_test);
  return r.instructor_id;
end;
$$;

-- -------------------------------------------------------------------------------------
-- Confirmation and booking (PRD 9.5) — one transaction; same function for Yes, manual, offline.
-- -------------------------------------------------------------------------------------
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
  v_test := coalesce((select d.status = 'Test' from public.domain d where d.id = w.domain_id), false);
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
  select c.id, v_booking, lbl, w.first_class_at - make_interval(days => private.setting_int(w.domain_id, 'checklist_due_days'))
    from public.class_session c
    cross join lateral jsonb_array_elements_text(private.get_setting(w.domain_id, 'checklist_items')) lbl
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

-- -------------------------------------------------------------------------------------
-- Releasing a booking / cancellation flow (PRD 9.7)
--   p_kind: InstructorCancelled | OpsReleased | TimeChangeDeclined | TimeClash | Deactivated | NoReplyRelease
-- -------------------------------------------------------------------------------------
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

  v_urgent := private.days_until(w.id, p_now) < private.setting_int(w.domain_id, 'short_notice_days');
  update public.module_week
     set status = 'Ready', at_risk = true, at_risk_reason = v_reason
   where id = w.id;
  perform private.raise_attention(w.domain_id, 'ClassAtRisk', case when v_urgent then 'Urgent' else 'Normal' end,
    'At risk: ' || private.mw_label(w.id) || ' — ' || v_reason,
    case when p_restart then 'Outreach has restarted automatically.' else 'Outreach was not restarted.' end || coalesce(' ' || p_note, ''),
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

-- -------------------------------------------------------------------------------------
-- Need Help (PRD §10)
-- -------------------------------------------------------------------------------------
create or replace function private.help_category_label(p text)
returns text language sql immutable set search_path = ''
as $$
  select case p
    when 'materials' then 'Class materials or content'
    when 'zoom' then 'Zoom / meeting link or calendar invite'
    when 'platform' then 'Platform access'
    when 'assignment' then 'Assignment or test review details'
    when 'students' then 'Students and cohort'
    when 'schedule' then 'Schedule question'
    when 'payment' then 'Payment or admin'
    else 'Something else' end;
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

  v_routing := private.get_setting(w.domain_id, 'help_routing');
  v_owners := private.owners_or_leads(w.module_id);
  v_ops := private.domain_role_ids(w.domain_id, 'Ops');
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
  v_h := case p_urgency when 'Urgent' then private.setting_int(w.domain_id, 'help_target_urgent_h')
                        when 'Within24h' then private.setting_int(w.domain_id, 'help_target_24h_h')
                        else private.setting_int(w.domain_id, 'help_target_norush_h') end;
  if v_days < 2 then
    v_h := least(v_h, private.setting_int(w.domain_id, 'help_target_urgent_h'));
  elsif v_days <= 7 then
    v_h := least(v_h, private.setting_int(w.domain_id, 'help_target_24h_h'));
  end if;
  if p_urgency = 'Urgent' or v_days < 2 then v_sev := 'Urgent'; end if;

  insert into public.help_request (domain_id, module_week_id, booking_id, requester_instructor_id, requester_team_member_id,
    source, categories, details, urgency, reply_channel, routed_to, severity, raised_at, response_target_at, is_test)
  values (w.domain_id, p_mw, coalesce(p_booking, (select b.id from public.booking b where b.module_week_id = p_mw and b.status = 'Active')),
    p_instructor, p_member, p_source, v_cats, left(p_details, 1000), coalesce(p_urgency, 'NoRush'), coalesce(p_reply, 'Either'),
    v_routed, v_sev, p_now, p_now + make_interval(hours => v_h),
    coalesce((select d.status = 'Test' from public.domain d where d.id = w.domain_id), false))
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

-- -------------------------------------------------------------------------------------
-- record_response(token): the single decision function behind every instructor/owner button.
-- Called only on the confirm page POST (never on GET), so link scanners can't answer.
-- -------------------------------------------------------------------------------------
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
          case when v_days < private.setting_int(w.domain_id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'Late "Yes" from ' || v_name || ' — ' || private.mw_label(w.id),
          'They said yes after the request closed (' || coalesce(r.close_reason, r.status) || '). Assign them manually if the slot is still free.',
          'late:' || r.id, private.domain_role_ids(w.domain_id, 'Ops'), v_now,
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
            private.domain_role_ids(w.domain_id, 'Ops'), v_now,
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

-- Help form submission from a Need help link (instructor or owner).
create or replace function public.submit_help_request(p_token text, p_categories text[], p_details text, p_urgency text, p_reply_channel text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  lnk public.response_link;
  r public.request;
  w public.module_week;
  v_now timestamptz;
  v_res jsonb;
  v_name text;
begin
  perform private.require_team();
  select * into lnk from public.response_link where token = p_token;
  if lnk.token is null or lnk.answer not in ('NeedHelp', 'OwnerNeedHelp') then
    return jsonb_build_object('result', 'invalid', 'message', 'This link isn''t valid.');
  end if;
  select * into r from public.request where id = lnk.request_id;
  select * into w from public.module_week where id = r.module_week_id;
  if w.status in ('Cancelled', 'Completed') then
    return jsonb_build_object('result', 'closed', 'message', 'This class is no longer scheduled.');
  end if;
  if p_urgency not in ('NoRush', 'Within24h', 'Urgent') or p_reply_channel not in ('Discord', 'Email', 'Either') then
    return jsonb_build_object('result', 'invalid', 'message', 'Please choose how soon you need this and how we should reply.');
  end if;
  v_now := private.domain_now(w.domain_id);
  if v_now <> now() then perform private.set_sim_now(v_now); end if;
  if r.instructor_id is not null then
    select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
    perform private.set_actor('Instructor', r.instructor_id, v_name);
    v_res := private.create_help_request(w.id, r.instructor_id, null, 'Instructor', p_categories, p_details,
      p_urgency, p_reply_channel, v_now, r.booking_id);
    if r.kind = 'CheckIn' and r.status in ('Sent', 'Reminded') then
      update public.request set status = 'Accepted', answer = 'NeedHelp', answered_at = v_now where id = r.id;
      perform private.resolve_attention('checkin_noreply:' || r.id, 'Instructor asked for help');
    end if;
    update public.instructor set last_response_at = v_now where id = r.instructor_id;
  else
    select t.name into v_name from public.team_member t where t.id = r.team_member_id;
    perform private.set_actor('TeamMember', null, v_name);
    v_res := private.create_help_request(w.id, null, r.team_member_id, 'Owner', p_categories, p_details,
      p_urgency, p_reply_channel, v_now);
  end if;
  return jsonb_build_object('result', 'help_created', 'help_request_id', v_res ->> 'id', 'merged', v_res -> 'merged',
    'message', 'Thanks! ' || (v_res ->> 'helper') || ' will reply by ' || private.fmt_pt((v_res ->> 'target_at')::timestamptz) || '.');
end;
$$;

-- =====================================================================================
-- Engine steps (each for one domain at p_now). Rows are locked with SKIP LOCKED so an
-- overlapping run skips what another run is processing (PRD 9.10).
-- =====================================================================================

-- Complete past classes and module weeks (unless ops flagged a problem).
create or replace function private.step_complete(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare w record; n int := 0;
begin
  update public.class_session c set status = 'Completed'
    from public.module_week mw
   where c.module_week_id = mw.id and mw.domain_id = p_domain and c.status = 'Planned'
     and c.ends_at <= p_now and not c.problem_flag;
  for w in select mw.* from public.module_week mw
            where mw.domain_id = p_domain and mw.status not in ('Completed', 'Cancelled')
              and mw.last_class_end_at <= p_now
              and not exists (select 1 from public.class_session c where c.module_week_id = mw.id and c.status = 'Planned')
              and exists (select 1 from public.booking b where b.module_week_id = mw.id and b.status = 'Active')
            for update skip locked loop
    update public.booking set status = 'Completed' where module_week_id = w.id and status = 'Active';
    update public.module_week set status = 'Completed', at_risk = false where id = w.id;
    update public.request set status = 'Superseded', close_reason = 'Classes completed'
     where module_week_id = w.id and status in ('Queued', 'Sent', 'Reminded');
    perform private.log_event('System', 'Module week completed', 'module_week', w.id, null, null, null,
      w.domain_id, w.module_id, w.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Readiness checks (45 days) and escalation (35 days).
create or replace function private.step_readiness(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  w record;
  v_probs jsonb;
  v_block boolean;
  v_days numeric;
  v_out int := private.setting_int(p_domain, 'outreach_days');
  v_read int := private.setting_int(p_domain, 'readiness_days');
  n int := 0;
begin
  for w in select mw.* from public.module_week mw
            where mw.domain_id = p_domain and mw.status in ('Planned', 'NotReady', 'Ready') and not mw.paused
              and mw.first_class_at > p_now and mw.first_class_at - make_interval(days => v_read) <= p_now
              and not exists (select 1 from public.booking b where b.module_week_id = mw.id and b.status = 'Active')
              and not exists (select 1 from public.request r where r.module_week_id = mw.id and r.kind = 'Outreach'
                                and r.status in ('Queued', 'Sent', 'Reminded'))
            for update skip locked loop
    v_probs := private.readiness_problems(w.id);
    v_block := exists (select 1 from jsonb_array_elements(v_probs) p where (p ->> 'blocking')::boolean);
    v_days := private.days_until(w.id, p_now);
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

-- Start outreach for ready module weeks at/after the outreach point (or restarted after a cancellation).
create or replace function private.step_outreach(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare w record; n int := 0; v_out int := private.setting_int(p_domain, 'outreach_days');
begin
  for w in select mw.* from public.module_week mw
            where mw.domain_id = p_domain and not mw.paused and mw.first_class_at > p_now
              and (mw.status = 'Ready'
                   or (mw.status = 'NeedsInstructor'
                       and exists (select 1 from private.build_line(mw.id) l where l.reason is null)))
              and (mw.first_class_at - make_interval(days => v_out) <= p_now or mw.at_risk)
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

-- Reminders and moving on for open outreach and time-change requests (PRD 9.4); withdraw requests
-- whose instructor can no longer be asked (PRD 9.9).
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
          case when private.days_until(r.module_week_id, p_now) < private.setting_int(p_domain, 'short_notice_days') then 'Urgent' else 'Normal' end,
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

-- Time-change requests for confirmed weeks whose time changed (PRD 9.9).
create or replace function private.step_time_changes(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare b record; n int := 0; v_req uuid; v_win record; v_send timestamptz; v_deadline timestamptz; v_urgent boolean;
begin
  for b in select bk.*, mw.time_version as mw_tv, mw.first_class_at, mw.domain_id
             from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and not mw.paused
              and mw.time_version > bk.time_version_confirmed and mw.first_class_at > p_now
              and not exists (select 1 from public.request q where q.module_week_id = mw.id and q.kind = 'TimeChange'
                                and q.time_version = mw.time_version)
            for update of bk skip locked loop
    update public.request set status = 'Superseded', close_reason = 'Time changed again'
     where module_week_id = b.module_week_id and kind = 'TimeChange' and status in ('Queued', 'Sent', 'Reminded');
    v_win := private.window_hours(b.module_week_id, p_now);
    v_urgent := v_win.band = 'Short';
    v_send := private.instructor_send_time(p_domain, p_now, v_urgent);
    v_deadline := least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_win.move_h), v_urgent), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, status, time_version, sent_at, reminder_at,
      deadline_at, is_test)
    values (b.module_week_id, b.instructor_id, b.id, 'TimeChange', 'Sent', b.mw_tv, v_send,
      least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_win.reminder_h), v_urgent), v_deadline),
      v_deadline, b.is_test)
    returning id into v_req;
    perform private.queue_instructor_message('M5', b.instructor_id, b.module_week_id, v_req, p_now,
      private.buttons(v_req, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_pt(v_deadline)), v_urgent);
    perform private.log_event('Messages', 'Time-change request sent', 'request', v_req, null,
      jsonb_build_object('time_version', b.mw_tv), null, p_domain, null, b.module_week_id, null, b.instructor_id, null, b.is_test);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Instructor check-ins (PRD 9.6) — send the latest due one, reminders, no-reply handling.
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
  v_urgent_band int := private.setting_int(p_domain, 'urgent_band_days');
  v_name text;
begin
  select array_agg(distinct x::int order by x::int) into v_days
    from jsonb_array_elements_text(private.get_setting(p_domain, 'checkin_days')) x;
  v_last := v_days[1];
  if private.setting_bool(p_domain, 'checkin_14_enabled') and not (14 = any (v_days)) then
    v_days := v_days || 14;
  end if;

  for b in select bk.*, mw.first_class_at, mw.module_id
             from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and not mw.paused and mw.first_class_at > p_now
            for update of bk skip locked loop
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
    v_tpl := case when v_due = v_last then 'M7' when v_due = 14 and v_due <> all (array(select x::int from jsonb_array_elements_text(private.get_setting(p_domain, 'checkin_days')) x)) then 'M8' else 'M6' end;
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
    if r.deadline_at <= p_now then
      update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
      perform private.log_event('Messages', 'No reply to the ' || r.check_in_days || '-day check-in from ' || v_name, 'request', r.id,
        null, null, null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
      if r.check_in_days = v_last and private.setting_text(p_domain, 'last_checkin_no_reply') = 'Release' then
        perform private.release_booking_flow(r.booking_id, 'NoReplyRelease', p_now);
      else
        perform private.raise_attention(p_domain, 'CheckInNoReply',
          case when r.check_in_days = v_last then 'Urgent' else 'Normal' end,
          'No reply to the ' || r.check_in_days || '-day check-in: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'The booking is kept. Please check with them.', 'checkin_noreply:' || r.id,
          private.domain_role_ids(p_domain, 'Ops'), p_now,
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

-- Owner check-in (T11): one message per owner listing their module weeks in the next N days.
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
     and mw.first_class_at > p_now and mw.first_class_at - make_interval(days => v_days) <= p_now;
  if cardinality(v_due) = 0 then return 0; end if;

  for o in select distinct x from public.module_week mw, unnest(private.owners_or_leads(mw.module_id)) x where mw.id = any (v_due) loop
    v_text := 'Your module weeks in the next ' || v_days || ' days:';
    for w in select mw.* from public.module_week mw
              where mw.domain_id = p_domain and mw.status not in ('Cancelled', 'Completed')
                and mw.first_class_at > p_now and mw.first_class_at <= p_now + make_interval(days => v_days)
                and o = any (private.owners_or_leads(mw.module_id))
              order by mw.first_class_at loop
      insert into public.request (module_week_id, team_member_id, kind, status, sent_at, is_test)
      values (w.id, o, 'OwnerCheckIn', 'Sent', p_now,
              coalesce((select d.status = 'Test' from public.domain d where d.id = p_domain), false))
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
      'T11:' || o || ':' || to_char(p_now at time zone 'Asia/Kolkata', 'YYYY-MM-DD'), p_now, true);
    n := n + 1;
  end loop;
  update public.module_week set owner_checkin_sent_at = p_now where id = any (v_due);
  return n;
end;
$$;

-- Help request deadlines (PRD 10.5).
create or replace function private.step_help(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare h record; n int := 0; v_targets uuid[];
begin
  for h in select hr.*, mw.module_id, mw.first_class_at, mw.at_risk
             from public.help_request hr join public.module_week mw on mw.id = hr.module_week_id
            where hr.domain_id = p_domain and hr.merged_into is null
              and hr.status in ('Open', 'InProgress', 'WaitingOnInstructor')
            for update of hr skip locked loop
    v_targets := case when h.assigned_to is not null then array[h.assigned_to] else h.routed_to end;
    if h.first_response_at is null and h.half_reminder_at is null and h.status = 'Open'
       and h.raised_at + (h.response_target_at - h.raised_at) / 2 <= p_now then
      perform private.queue_team_message('REM', p_domain, 'person', t, '{}',
          'Reminder: help request — ' || private.mw_label(h.module_week_id),
          '⏰ Half-time reminder: a help request for ' || private.mw_label(h.module_week_id)
            || ' needs a reply by ' || private.fmt_ist(h.response_target_at) || '.',
          'HELPHALF:' || h.id, p_now, false, null, h.module_week_id, h.id)
        from unnest(v_targets) t;
      update public.help_request set half_reminder_at = p_now where id = h.id;
      n := n + 1;
    end if;
    if h.first_response_at is null and h.escalated_at is null and h.response_target_at <= p_now then
      perform private.queue_team_message('T13', p_domain, 'alert', null,
        private.uniq(private.owners_or_leads(h.module_id) || private.domain_role_ids(p_domain, 'Lead')),
        'Escalation: help request past target — ' || private.mw_label(h.module_week_id),
        '⚠️ Escalation: a help request for ' || private.mw_label(h.module_week_id) || ' passed its reply target ('
          || private.fmt_ist(h.response_target_at) || ') with no reply.',
        'T13:help:' || h.id, p_now, false, null, h.module_week_id, h.id);
      update public.help_request set escalated_at = p_now, severity = 'Urgent' where id = h.id;
      update public.attention_item set severity = 'Urgent', escalated_at = p_now
       where dedupe_key = 'help:' || h.id and status <> 'Done';
      n := n + 1;
    end if;
    if h.first_class_at - interval '2 days' <= p_now and h.first_class_at > p_now and not h.at_risk then
      update public.module_week set at_risk = true, at_risk_reason = 'Help pending' where id = h.module_week_id;
      perform private.log_event('System', 'At risk (help pending)', 'module_week', h.module_week_id, null, null, null,
        p_domain, h.module_id, h.module_week_id);
    end if;
  end loop;
  return n;
end;
$$;

-- Checklist nudges (3 days after confirmation) and escalation (7 days before).
create or replace function private.step_checklist(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  b record;
  n int := 0;
  v_missing text;
  v_nudge int := private.setting_int(p_domain, 'checklist_nudge_days');
  v_due int := private.setting_int(p_domain, 'checklist_due_days');
  v_id uuid;
begin
  for b in select bk.*, mw.first_class_at, mw.module_id from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and mw.first_class_at > p_now loop
    select string_agg(distinct ci.label, ', ') into v_missing
      from public.checklist_item ci join public.class_session c on c.id = ci.class_id
     where c.module_week_id = b.module_week_id and c.status = 'Planned' and not ci.done;
    if v_missing is null then
      perform private.resolve_attention('checklist:' || b.module_week_id, 'Checklist complete');
      continue;
    end if;
    if b.first_class_at - make_interval(days => v_due) <= p_now then
      v_id := private.raise_attention(p_domain, 'ChecklistOverdue', 'Urgent',
        'Checklist overdue: ' || private.mw_label(b.module_week_id), 'Not done: ' || v_missing,
        'checklist:' || b.module_week_id, private.domain_role_ids(p_domain, 'Ops'), p_now, private.mw_refs(b.module_week_id), false, 'T9');
      if (select a.escalated_at from public.attention_item a where a.id = v_id) is null then
        perform private.queue_team_message('T13', p_domain, 'alert', null,
          private.uniq(private.domain_role_ids(p_domain, 'Ops') || private.domain_role_ids(p_domain, 'Lead')),
          'Escalation: checklist not done — ' || private.mw_label(b.module_week_id),
          '⚠️ Escalation: checklist must be complete ' || v_due || ' days before ' || private.mw_label(b.module_week_id) || '. Not done: ' || v_missing,
          'T13:checklist:' || b.module_week_id, p_now, false, v_id, b.module_week_id);
        update public.attention_item set escalated_at = p_now where id = v_id;
      end if;
      n := n + 1;
    elsif b.confirmed_at + make_interval(days => v_nudge) <= p_now then
      perform private.raise_attention(p_domain, 'ChecklistOverdue', 'Normal',
        'Checklist pending: ' || private.mw_label(b.module_week_id), 'Not done: ' || v_missing,
        'checklist:' || b.module_week_id, private.domain_role_ids(p_domain, 'Ops'), p_now, private.mw_refs(b.module_week_id), false, 'T9');
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

-- Thin benches, unverified instructors in rankings, schedule running low (PRD 9.8).
create or replace function private.step_health(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  m record;
  i record;
  v_min int := private.setting_int(p_domain, 'min_active_instructors');
  v_weeks int := private.setting_int(p_domain, 'schedule_low_weeks');
  v_last date;
  v_cnt int;
  v_live boolean := (select d.status = 'Live' from public.domain d where d.id = p_domain);
  n int := 0;
begin
  for m in select * from public.module where domain_id = p_domain and status = 'Active' loop
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

-- Escalation ladder for attention items (PRD 9.8): R1 → R2 → escalation; I'm on it pauses 24h.
create or replace function private.step_reminders(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  a record;
  n int := 0;
  v_targets uuid[];
  v_weekly boolean;
  v_r2n int := private.setting_int(p_domain, 'reminder_r2_normal_h');
  v_r2u int := private.setting_int(p_domain, 'reminder_r2_urgent_h');
  v_esn int := private.setting_int(p_domain, 'reminder_escalate_normal_h');
  v_esu int := private.setting_int(p_domain, 'reminder_escalate_urgent_h');
  v_has_r2 boolean;
  v_escal uuid[];
begin
  for a in select * from public.attention_item
            where domain_id = p_domain and status <> 'Done' and (ack_until is null or ack_until <= p_now)
            for update skip locked loop
    v_targets := case when a.assigned_to is not null then array[a.assigned_to] else a.recipients end;
    v_weekly := a.type in ('ThinBench', 'ScheduleLow', 'UnverifiedInRanking');
    if a.r1_at is null then
      continue;                                   -- normal items get R1 in the daily digest
    end if;
    if v_weekly then
      if a.last_reminder_at + interval '7 days' <= p_now then
        perform private.queue_team_message('REM', p_domain, 'person', t, '{}', 'Weekly reminder: ' || a.title,
            '⏰ Weekly reminder: ' || a.title || coalesce(E'\n' || a.detail, ''),
            'REM:' || a.id || ':' || to_char(p_now, 'YYYYMMDDHH24'), p_now, true, a.id, a.module_week_id)
          from unnest(v_targets) t;
        insert into public.reminder (attention_item_id, recipient, level, sent_at) select a.id, t, 'R2', p_now from unnest(v_targets) t;
        update public.attention_item set last_reminder_at = p_now where id = a.id;
        n := n + 1;
      end if;
      continue;
    end if;
    select exists (select 1 from public.reminder rm where rm.attention_item_id = a.id and rm.level = 'R2') into v_has_r2;
    if (a.severity = 'Urgent' and a.last_reminder_at + make_interval(hours => v_r2u) <= p_now)
       or (a.severity = 'Normal' and not v_has_r2 and a.r1_at + make_interval(hours => v_r2n) <= p_now) then
      perform private.queue_team_message('REM', p_domain, 'person', t, '{}',
          case when a.severity = 'Urgent' then '🚨 Reminder: ' else 'Reminder: ' end || a.title,
          case when a.severity = 'Urgent' then '🚨 Still open: ' else '⏰ Still open: ' end || a.title || coalesce(E'\n' || a.detail, '')
            || E'\nTap "I''m on it" in the app to pause reminders.',
          'REM:' || a.id || ':' || to_char(p_now, 'YYYYMMDDHH24'), p_now, a.severity = 'Normal', a.id, a.module_week_id)
        from unnest(v_targets) t;
      insert into public.reminder (attention_item_id, recipient, level, sent_at) select a.id, t, 'R2', p_now from unnest(v_targets) t;
      update public.attention_item set last_reminder_at = p_now where id = a.id;
      n := n + 1;
    end if;
    -- Readiness failures escalate on their own PRD timeline (35 days before), not by this ladder.
    if a.escalated_at is null and a.status = 'Open' and a.type <> 'ReadinessFailed'
       and a.r1_at + make_interval(hours => case when a.severity = 'Urgent' then v_esu else v_esn end) <= p_now then
      v_escal := private.uniq(
        coalesce(case when a.module_id is not null then private.owners_or_leads(a.module_id) end, '{}')
        || private.domain_role_ids(p_domain, 'Lead'));
      perform private.queue_team_message('T13', p_domain, 'alert', null, v_escal,
        'Escalation: ' || a.title,
        '⚠️ Escalation — not acknowledged since ' || private.fmt_ist(a.r1_at) || ': ' || a.title || coalesce(E'\n' || a.detail, ''),
        'T13:' || a.id, p_now, false, a.id, a.module_week_id);
      insert into public.reminder (attention_item_id, recipient, level, sent_at) select a.id, t, 'Escalation', p_now from unnest(v_escal) t;
      update public.attention_item set escalated_at = p_now where id = a.id;
      perform private.log_event('Reminders', 'Escalated: ' || a.title, 'attention_item', a.id, null, null, null,
        p_domain, a.module_id, a.module_week_id);
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

-- Release messages whose send time (quiet hours) has come, in this domain's clock.
create or replace function private.step_release(p_domain uuid, p_now timestamptz)
returns int language sql security definer set search_path = ''
as $$
  with u as (update public.message set status = 'Pending'
              where domain_id is not distinct from p_domain and status = 'Scheduled' and not_before <= p_now returning 1)
  select count(*)::int from u;
$$;

-- =====================================================================================
-- engine_tick — everything the hourly check (PRD 9.1) decides for one domain at p_now.
-- p_now null = real time (or the domain's test clock in test mode).
-- =====================================================================================
create or replace function public.engine_tick(p_domain_id uuid, p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  d public.domain;
  v_now timestamptz;
  v_instr boolean;
  v jsonb := '{}';
  v_before int;
  v_queued int;
begin
  perform private.require_team();
  select * into d from public.domain where id = p_domain_id;
  if d.id is null then raise exception 'Unknown domain'; end if;
  v_now := coalesce(p_now, private.domain_now(p_domain_id));
  perform private.set_actor('System', null, 'System');
  perform private.set_sim_now(case when abs(extract(epoch from (v_now - now()))) > 60 then v_now end);
  if d.status = 'Draft' then
    return jsonb_build_object('domain', d.name, 'skipped', 'Draft');
  end if;
  select count(*) into v_before from public.message where domain_id = p_domain_id;
  v_instr := private.instructor_messages_allowed(p_domain_id);

  v := v || jsonb_build_object('completed', private.step_complete(p_domain_id, v_now));
  if d.status in ('Test', 'Live') then
    v := v || jsonb_build_object('readiness_passed', private.step_readiness(p_domain_id, v_now));
  end if;
  if v_instr then
    v := v || jsonb_build_object('request_updates', private.step_requests(p_domain_id, v_now));
    v := v || jsonb_build_object('time_changes', private.step_time_changes(p_domain_id, v_now));
    v := v || jsonb_build_object('outreach_started', private.step_outreach(p_domain_id, v_now));
    v := v || jsonb_build_object('checkins', private.step_checkins(p_domain_id, v_now));
  end if;
  if d.status in ('Test', 'Live') then
    v := v || jsonb_build_object('owner_checkins', private.step_owner_checkins(p_domain_id, v_now));
    v := v || jsonb_build_object('checklist', private.step_checklist(p_domain_id, v_now));
    v := v || jsonb_build_object('health', private.step_health(p_domain_id, v_now));
  end if;
  v := v || jsonb_build_object('help', private.step_help(p_domain_id, v_now));
  v := v || jsonb_build_object('reminders', private.step_reminders(p_domain_id, v_now));
  v := v || jsonb_build_object('released', private.step_release(p_domain_id, v_now));
  select count(*) - v_before into v_queued from public.message where domain_id = p_domain_id;
  v := v || jsonb_build_object('domain', d.name, 'now', v_now, 'messages_queued', v_queued,
    'instructor_messages', case when v_instr then 'on' else 'paused' end);
  perform private.log_event('System', 'Hourly check: ' || d.name, 'domain', d.id, null, v,
    d.name || ': ' || (v ->> 'outreach_started') || ' outreach started, ' || v_queued || ' messages queued',
    d.id, null, null, null, null, null, d.status = 'Test');
  return v;
end;
$$;

-- Daily digest per team member (PRD 9.8, REM-2), sent once a day at the digest time (IST).
create or replace function private.send_digests(p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  t record;
  v_date date := (p_now at time zone 'Asia/Kolkata')::date;
  v_time time := private.setting_text(null, 'digest_time_ist')::time;
  v_text text;
  v_items record;
  v_count int;
  n int := 0;
  v_test text;
begin
  if (p_now at time zone 'Asia/Kolkata')::time < v_time
     or (select s.last_digest_date from public.system_state s where s.id = 1) >= v_date then
    return 0;
  end if;
  select string_agg(d.name, ', ') into v_test from public.domain d where d.status = 'Test';
  for t in select * from public.team_member where active and receives_digest loop
    select count(*) into v_count from public.attention_item a
     where a.status <> 'Done' and (a.assigned_to = t.id or (a.assigned_to is null and t.id = any (a.recipients)));
    continue when v_count = 0;
    v_text := 'Good morning ' || private.first_name(t.name) || ' — you have ' || v_count || ' open item' || case when v_count = 1 then '' else 's' end || '.';
    if v_test is not null then v_text := v_text || E'\nℹ️ In TEST MODE: ' || v_test; end if;
    if not (select s.outreach_enabled from public.system_state s where s.id = 1) then
      v_text := v_text || E'\n⛔ The kill switch is ON — no instructor messages are being sent.';
    end if;
    for v_items in select a.severity, string_agg('• ' || a.title || ' (open ' ||
                      greatest(1, round(extract(epoch from (p_now - a.opened_at)) / 3600))::int || 'h)', E'\n' order by a.opened_at) as lines
                     from public.attention_item a
                    where a.status <> 'Done' and (a.assigned_to = t.id or (a.assigned_to is null and t.id = any (a.recipients)))
                    group by a.severity order by a.severity desc loop
      v_text := v_text || E'\n\n' || case when v_items.severity = 'Urgent' then '🚨 Urgent' else 'Normal' end || E'\n' || v_items.lines;
    end loop;
    perform private.queue_team_message('T12', null, 'person', t.id, '{}', 'Your daily digest — ' || v_count || ' open',
      v_text, 'T12:' || t.id || ':' || v_date, p_now);
    insert into public.reminder (attention_item_id, recipient, level, sent_at)
    select a.id, t.id, 'R1', p_now from public.attention_item a
     where a.status <> 'Done' and a.r1_at is null and (a.assigned_to = t.id or (a.assigned_to is null and t.id = any (a.recipients)));
    n := n + 1;
  end loop;
  update public.attention_item set r1_at = p_now, last_reminder_at = coalesce(last_reminder_at, p_now)
   where status <> 'Done' and r1_at is null;
  update public.system_state set last_digest_date = v_date where id = 1;
  return n;
end;
$$;

-- WF1 entry point: run the engine for every Test/Live/Paused domain, then digests.
create or replace function public.engine_tick_all(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  d record;
  v jsonb := '[]';
  v_res jsonb;
  v_err text;
  v_errors int := 0;
begin
  perform private.require_team();
  for d in select * from public.domain where status in ('Test', 'Live', 'Paused') order by name loop
    begin
      v_res := public.engine_tick(d.id, p_now);
      v := v || v_res;
    exception when others then
      get stacked diagnostics v_err = message_text;
      v_errors := v_errors + 1;
      v := v || jsonb_build_object('domain', d.name, 'error', v_err);
      perform private.set_actor('System', null, 'System');
      perform private.log_event('System', 'Hourly check failed: ' || d.name, 'domain', d.id, null, null, v_err, d.id);
      perform private.queue_team_message('T14', d.id, 'admin', null, '{}', 'Hourly check failed: ' || d.name,
        '❗ Hourly check failed for ' || d.name || ': ' || v_err, 'T14:tick:' || d.id || ':' || to_char(now(), 'YYYYMMDDHH24'), now());
    end;
  end loop;
  perform private.set_actor('System', null, 'System');
  perform private.send_digests(coalesce(p_now, now()));
  perform private.step_release(null, coalesce(p_now, now()));
  update public.system_state
     set last_hourly_run_at = now(), last_hourly_status = case when v_errors = 0 then 'ok' else v_errors || ' error(s)' end,
         last_hourly_summary = v
   where id = 1;
  return jsonb_build_object('domains', v, 'errors', v_errors);
end;
$$;

-- WF3: heartbeat (T15) and kill-switch reminder. Digests are time-gated inside engine_tick_all.
create or replace function public.daily_jobs(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  s public.system_state;
  v_text text;
  v_sent int; v_failed int; v_open int; v_urgent int;
begin
  perform private.require_team();
  perform private.set_actor('System', null, 'System');
  select * into s from public.system_state where id = 1;
  select count(*) filter (where status = 'Sent' and sent_at > v_now - interval '24 hours'),
         count(*) filter (where status = 'Failed' and updated_at > v_now - interval '24 hours')
    into v_sent, v_failed from public.message;
  select count(*), count(*) filter (where severity = 'Urgent') into v_open, v_urgent from public.attention_item where status <> 'Done';
  v_text := '💓 Daily heartbeat — last hourly run: ' || coalesce(private.fmt_ist(s.last_hourly_run_at), 'never')
    || ' (' || coalesce(s.last_hourly_status, 'n/a') || ')'
    || E'\nMessages sent (24h): ' || v_sent || ' · failed: ' || v_failed
    || E'\nOpen items: ' || v_open || ' (' || v_urgent || ' urgent)'
    || coalesce(E'\nIn TEST MODE: ' || (select string_agg(d.name, ', ') from public.domain d where d.status = 'Test'), '')
    || case when not s.outreach_enabled then E'\n⛔ Kill switch is ON since ' || coalesce(private.fmt_ist(s.kill_switch_changed_at), '?')
            || ' — no instructor messages are going out. Turn it off in Settings → System when ready.' else '' end;
  perform private.queue_team_message('T15', null, 'admin', null, '{}', 'Daily heartbeat', v_text,
    'T15:' || to_char(v_now at time zone 'Asia/Kolkata', 'YYYY-MM-DD'), v_now);
  update public.system_state set last_daily_run_at = now(), last_heartbeat_at = now() where id = 1;
  perform private.log_event('System', 'Daily jobs', null, null, null,
    jsonb_build_object('sent_24h', v_sent, 'failed_24h', v_failed, 'open', v_open), null);
  return jsonb_build_object('sent_24h', v_sent, 'failed_24h', v_failed, 'open_items', v_open, 'urgent_items', v_urgent);
end;
$$;

-- =====================================================================================
-- Outbox for n8n (write-before-send, PRD 9.10)
-- =====================================================================================
create or replace function public.claim_outbound_messages(p_limit int default 25)
returns setof public.message language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  update public.message set status = 'Pending'
   where status = 'Sending' and claimed_at < now() - interval '15 minutes';
  return query
  with c as (
    select m.id from public.message m left join public.domain d on d.id = m.domain_id
     where m.status = 'Pending' and m.direction = 'Outbound'
       and (m.audience <> 'Instructor'
            or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                and coalesce(d.status, 'Live') <> 'Paused'))
     order by m.created_at
     limit greatest(1, least(p_limit, 100))
     for update of m skip locked)
  update public.message m set status = 'Sending', claimed_at = now(), attempts = m.attempts + 1
    from c where m.id = c.id
  returning m.*;
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
                and private.days_until(q.module_week_id, v_now) < private.setting_int(m.domain_id, 'short_notice_days');
  end if;
  perform private.log_event('Messages', m.template_id || ' failed to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
    'message', m.id, null, null, p_error, m.domain_id, null, m.module_week_id, null, m.instructor_id, null, m.is_test);
  if m.audience <> 'Admin' then
    perform private.raise_attention(m.domain_id, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
      'Message failed: ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
      coalesce(p_error, 'Unknown error') || case when m.channel = 'Discord' then ' (email is still sent)' else ' (Discord is still used)' end,
      'msgfail:' || m.id,
      coalesce(nullif(private.domain_role_ids(m.domain_id, 'Ops'), '{}'),
               (select array_agg(t.id) from public.team_member t where t.label = 'Ops' and t.active)),
      v_now, jsonb_build_object('module_week_id', m.module_week_id, 'instructor_id', m.instructor_id, 'message_id', m.id), true, 'T14');
    perform private.queue_team_message('T14', m.domain_id, 'admin', null, '{}', 'Message failed',
      '❗ ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel || ' failed: ' || coalesce(p_error, '?'),
      'T14:' || m.id, now());
  end if;
  return jsonb_build_object('ok', true, 'status', 'Failed');
end;
$$;

-- =====================================================================================
-- Inbound (PRD 9.1 "read inbound"): typed replies and bounces become attention items.
-- =====================================================================================
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
      (select coalesce(array_agg(t.id), '{}') from public.team_member t where t.label = 'Ops' and t.active), v_now,
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

  if v_mw is not null and private.days_until(v_mw, v_now) < private.setting_int(v_dom, 'short_notice_days') then
    v_sev := 'Urgent';
  end if;
  perform private.raise_attention(v_dom, 'TypedReply', v_sev,
    'Typed reply from ' || i.full_name || coalesce(' — ' || private.mw_label(v_mw), ''),
    coalesce('Summary: ' || p_summary || E'\n', '') || left(coalesce(p_body, ''), 500)
      || E'\nNothing was changed automatically. Read it and decide.',
    'typed:' || v_msg, coalesce(private.domain_role_ids(v_dom, 'Ops'), '{}'), v_now,
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
    v_urgent := private.days_until(q.module_week_id, private.domain_now(v_dom)) < private.setting_int(v_dom, 'short_notice_days');
  end if;
  perform private.raise_attention(v_dom, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
    'Email bounced: ' || i.full_name || ' (' || p_email || ')',
    coalesce(p_detail, 'The email address may be wrong.') || ' Discord is still used. Fix the email in Instructors.',
    'bounce:' || i.id, coalesce(nullif(private.domain_role_ids(v_dom, 'Ops'), '{}'),
      (select array_agg(t.id) from public.team_member t where t.label = 'Ops' and t.active)),
    coalesce(private.domain_now(v_dom), now()), jsonb_build_object('instructor_id', i.id), true, 'T14');
  perform private.log_event('Messages', 'Email bounced: ' || i.full_name, 'instructor', i.id, null, null, p_detail,
    v_dom, null, null, null, i.id);
  return jsonb_build_object('ok', true, 'matched', true);
end;
$$;

-- Instructor Discord channels worth reading for typed replies (open requests, upcoming bookings, open help).
create or replace function public.discord_watchlist()
returns table (channel_id text, instructor_id uuid, discord_user_id text, last_message_id text)
language sql stable security definer set search_path = ''
as $$
  select i.discord_channel_id, i.id, i.discord_user_id, c.last_message_id
    from public.instructor i left join public.discord_cursor c on c.channel_id = i.discord_channel_id
   where i.discord_channel_id is not null and i.discord_user_id is not null and i.status = 'Active'
     and private.is_service()
     and (exists (select 1 from public.request r where r.instructor_id = i.id and r.status in ('Sent', 'Reminded'))
          or exists (select 1 from public.booking b join public.module_week w on w.id = b.module_week_id
                      where b.instructor_id = i.id and b.status = 'Active' and w.first_class_at > now())
          or exists (select 1 from public.help_request h where h.requester_instructor_id = i.id
                      and h.status in ('Open', 'InProgress', 'WaitingOnInstructor')));
$$;

create or replace function public.set_discord_cursor(p_channel_id text, p_last_message_id text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  insert into public.discord_cursor (channel_id, last_message_id, updated_at) values (p_channel_id, p_last_message_id, now())
  on conflict (channel_id) do update set last_message_id = excluded.last_message_id, updated_at = now();
end;
$$;

-- =====================================================================================
-- Action queue for WF4 (app "poke")
-- =====================================================================================
create or replace function public.next_actions(p_limit int default 20)
returns setof public.action_queue language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  return query
  with c as (select a.id from public.action_queue a where a.status = 'Queued' order by a.created_at limit p_limit for update skip locked)
  update public.action_queue a set status = 'Processing' from c where a.id = c.id returning a.*;
end;
$$;

create or replace function public.complete_action(p_action_id uuid, p_ok boolean, p_result jsonb default null, p_error text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  update public.action_queue set status = case when p_ok then 'Done' else 'Failed' end, result = p_result, error = p_error,
         processed_at = now()
   where id = p_action_id;
end;
$$;

-- Full snapshot for the nightly backup export (WF3, SYS-3).
create or replace function public.export_snapshot()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare t text; v jsonb := '{}'; r jsonb;
begin
  if not private.is_service() then raise exception 'Not allowed' using errcode = '42501'; end if;
  foreach t in array array['team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
    'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'module_week',
    'class_session', 'request', 'booking', 'checklist_item', 'help_request', 'attention_item', 'setting', 'holiday'] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x', t) into r;
    v := v || jsonb_build_object(t, r);
  end loop;
  return v || jsonb_build_object('exported_at', now());
end;
$$;

-- n8n (service role) entry points
grant execute on function public.engine_tick(uuid, timestamptz) to service_role;
grant execute on function public.engine_tick_all(timestamptz) to service_role;
grant execute on function public.daily_jobs(timestamptz) to service_role;
grant execute on function public.claim_outbound_messages(int) to service_role;
grant execute on function public.report_message_result(uuid, boolean, text, text, boolean) to service_role;
grant execute on function public.record_response(text, text) to service_role;
grant execute on function public.submit_help_request(text, text[], text, text, text) to service_role;
grant execute on function public.record_inbound_message(text, text, text, text, text, timestamptz, text) to service_role;
grant execute on function public.record_bounce(text, text, text) to service_role;
grant execute on function public.discord_watchlist() to service_role;
grant execute on function public.set_discord_cursor(text, text) to service_role;
grant execute on function public.next_actions(int) to service_role;
grant execute on function public.complete_action(uuid, boolean, jsonb, text) to service_role;
grant execute on function public.export_snapshot() to service_role;
