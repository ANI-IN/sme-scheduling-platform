-- Final round before the demo (decisions 271 and 272).
-- Item 3: the same plain words in the app, Discord and email: "We've started asking the next instructor." for a
--   class at risk, "Assign someone manually or add instructors to the instructor order." when nobody is left,
--   and no "ranking" or "outreach" in what people read (internal names stay).
-- Item 4: when "Nobody left to ask" is raised for a class week, the "Class at risk" task of that week is
--   marked done and logged, so there is one open task per class week.
-- Item 2: Activity history sends live updates.

create or replace function private.close_at_risk_for(p_mw uuid, p_now timestamptz)
returns void language plpgsql security definer set search_path = ''
as $$
declare a record;
begin
  for a in
    update public.attention_item set status = 'Done', done_at = p_now,
           done_note = 'Replaced by "Nobody left to ask" for the same class week.', version = version
     where module_week_id = p_mw and type = 'ClassAtRisk' and status <> 'Done'
    returning id, domain_id, module_id, title
  loop
    perform private.log_event('System', 'Class at risk task closed', 'attention_item', a.id, null, null,
      'Replaced by "Nobody left to ask" for the same class week: ' || a.title, a.domain_id, a.module_id, p_mw);
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
    case when p_kind in ('InstructorCancelled', 'TimeChangeDeclined') then 'M10' else 'M16' end,
    b.instructor_id, w.id, null, p_now, '[]', '{}', false, 'release:' || b.id);

  v_urgent := private.days_until(w.id, p_now) < private.setting_int(w.id, 'short_notice_days');
  -- Without a restart the week is paused, so the hourly check doesn't restart it either.
  update public.module_week
     set status = 'Ready', at_risk = true, at_risk_reason = v_reason, paused = paused or not p_restart
   where id = w.id;
  perform private.raise_attention(w.domain_id, 'ClassAtRisk', case when v_urgent then 'Urgent' else 'Normal' end,
    'At risk: ' || private.mw_label(w.id) || ', ' || v_reason,
    case when p_restart then 'We''ve started asking the next instructor.' else 'Asking is paused for this class week. Resume it from the class week when you are ready.' end || coalesce(' ' || p_note, ''),
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
     where k.module_id = m.id and ins.status = 'Active' and (not v_live or not ins.is_test or (select c.environment from public.app_config c where c.id = 1) = 'Sandbox');
    if v_cnt < v_min then
      perform private.raise_attention(p_domain, 'ThinBench', 'Normal',
        'Thin bench: ' || m.name || ' has ' || v_cnt || ' active instructor' || case when v_cnt = 1 then '' else 's' end || ' (minimum ' || v_min || ')',
        'Add instructors to the instructor order.', 'thinbench:' || m.id, private.owners_or_leads(m.id), p_now,
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
        'Not verified: ' || i.full_name, 'They are in an instructor order but haven''t confirmed the test message. Send a test message from Instructors.',
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
          '⚠️ Escalation: readiness check still failing for ' || private.mw_label(w.id) || ' and asking starts in '
            || greatest(0, round(v_days - v_out)) || ' days. '
            || (select string_agg(p ->> 'text', '; ') from jsonb_array_elements(v_probs) p where (p ->> 'blocking')::boolean),
          'T13:readiness:' || w.id, p_now, false, null, w.id);
        update public.module_week set readiness_escalated_at = p_now where id = w.id;
      end if;
    elsif w.status in ('Planned', 'NotReady') then
      perform private.resolve_attention('readiness:' || w.id, 'Readiness check passed');
      -- Once per module per run: the US and India weeks of one module pass at the same moment (decision 272).
      if not exists (select 1 from public.history_event e where e.action = 'Readiness check passed'
                        and e.module_id = w.module_id and e.at >= now()) then
        perform private.log_event('System', 'Readiness check passed', 'module_week', w.id, null, v_probs, null,
          w.domain_id, w.module_id, w.id);
      end if;
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

create or replace function public.pause_outreach(p_module_week_id uuid, p_paused boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare w public.module_week;
begin
  perform private.require_team();
  if p_paused and exists (select 1 from public.booking b where b.module_week_id = p_module_week_id and b.status = 'Active') then
    raise exception 'This class week already has a confirmed instructor, so there is nobody to ask. Its reminders before class and time changes go on as usual.'
      using errcode = '22023';
  end if;
  update public.module_week set paused = p_paused where id = p_module_week_id returning * into w;
  perform private.log_event('Team actions', case when p_paused then 'Asking paused' else 'Asking resumed' end,
    'module_week', p_module_week_id, null, null, null, w.domain_id, w.module_id, p_module_week_id);
end;
$$;

create or replace function public.resend_message(p_message_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare m public.message; v_id uuid; v_now timestamptz; v_send timestamptz;
begin
  perform private.require_team();
  select * into m from public.message where id = p_message_id;
  if m.id is null or m.direction <> 'Outbound' then raise exception 'Choose a sent message to resend.'; end if;
  if m.status not in ('Sent', 'Failed') then
    raise exception 'That message hasn''t gone out yet (it is %), so there is nothing to resend.', lower(m.status);
  end if;
  if m.domain_id is not null and m.audience <> 'Admin' and m.is_test <> private.is_test_domain(m.domain_id) then
    raise exception 'Testing was switched on or off since this message was sent. Send a new message instead, from Instructor requests after the next check.';
  end if;
  v_now := coalesce(private.domain_now(m.domain_id), now());
  v_send := case when m.audience = 'Instructor' then private.instructor_send_time(coalesce(m.module_week_id, m.domain_id), v_now, false, coalesce(private.week_region(m.module_week_id), 'US')) else v_now end;
  if m.request_id is not null and exists (select 1 from public.request r where r.id = m.request_id
       and r.status not in ('Queued', 'Sent', 'Reminded', 'Accepted')) then
    raise exception 'That request has closed, so the message would confuse the instructor. Ask again instead.';
  end if;
  insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id,
    team_member_id, module_week_id, request_id, help_request_id, attention_item_id, recipient_label, to_address,
    discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html, buttons, is_test)
  select domain_id, audience, template_id, channel,
         coalesce(unique_key, id::text) || ':resend:' || extract(epoch from clock_timestamp())::bigint,
         case when v_send > v_now then 'Scheduled' else 'Pending' end, v_send, instructor_id, team_member_id, module_week_id, request_id, help_request_id, attention_item_id,
         recipient_label, to_address, discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html,
         buttons, is_test
    from public.message where id = p_message_id
  returning id into v_id;
  perform private.log_event('Team actions', 'Resent ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
    'message', v_id, null, null, null, m.domain_id, null, m.module_week_id, null, m.instructor_id);
  perform private.queue_deliver('resend');
  return jsonb_build_object('ok', true, 'message_id', v_id);
end;
$$;

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
    raise exception 'This changed. Someone else saved this instructor order after you opened it. Reload the page and try again.' using errcode = '40001';
  end if;
  if (select count(distinct x) from unnest(p_instructor_ids) x) <> cardinality(p_instructor_ids) then
    raise exception 'An instructor appears twice in the instructor order.';
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
  perform private.require_undoable(p_event_id);
  select * into e from public.history_event where id = p_event_id;
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
      raise exception 'The instructor order changed again since then, so undo isn''t safe. Edit it directly instead.';
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

-- Activity history updates by itself in the app (decision 271).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'history_event') then
    alter publication supabase_realtime add table public.history_event;
  end if;
end $$;
