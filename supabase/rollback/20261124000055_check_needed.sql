-- Rollback of 20261124000055_check_needed.sql. Nothing is deleted: messages waiting for a check become Failed (what
-- they became before), and their tasks become "Message not delivered" tasks.
update public.message set status = 'Failed' where status = 'CheckNeeded';
update public.attention_item set type = 'MessageFailed' where type = 'MessageCheck';
drop function if exists public.resolve_message_check(uuid, boolean);
drop function if exists private.mark_check_needed(uuid);
alter table public.message drop constraint message_status_check;
alter table public.message add constraint message_status_check check (status in (
  'Scheduled', 'Pending', 'Sending', 'Sent', 'Failed', 'Received', 'Cancelled'));
alter table public.attention_item drop constraint attention_item_type_check;
alter table public.attention_item add constraint attention_item_type_check check (type in (
    'RankingExhausted', 'ClassAtRisk', 'TypedReply', 'HelpRequest', 'ReadinessFailed',
    'ChecklistOverdue', 'MessageFailed', 'LateReply', 'ScheduleLow', 'TimeChangeNotConfirmed',
    'CheckInNoReply', 'ThinBench', 'UnverifiedInRanking', 'OwnerCheckIn', 'Other', 'TimeProposal'));

create or replace function public.claim_outbound_messages(p_limit int default 25)
returns setof public.message language plpgsql security definer set search_path = ''
as $$
declare v_stuck uuid;
begin
  perform private.require_service();
  -- OUT-2: drop what should no longer go out before handing messages to n8n.
  perform private.cancel_stale_messages();
  -- DIS-13: never send again what may already have arrived (Discord only drops a repeated nonce for a
  -- few minutes, and Gmail never does). It fails like any other message, with a task to check.
  for v_stuck in select id from public.message where status = 'Sending' and claimed_at < now() - interval '15 minutes' loop
    perform public.report_message_result(v_stuck,
      false, null,
      'The automation took this message but never said whether it was sent, so it may or may not have arrived. Check, and send it again if it did not.',
      true);
  end loop;
  -- The daily email cap (decision 287): one task a day when emails are waiting for it.
  if (select private.email_cap_left()) <= 0
     and exists (select 1 from public.message m where m.status = 'Pending' and m.direction = 'Outbound' and m.channel = 'Email')
     and not exists (select 1 from public.attention_item a where a.dedupe_key = 'email-cap:' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD')) then
    insert into public.attention_item (type, severity, title, detail, dedupe_key)
    values ('Other', 'Urgent', 'Daily email limit reached',
      'The app has sent ' || (select c.daily_email_cap from public.app_config c where c.id = 1) || ' emails in the last 24 hours. '
      || 'The rest wait and go out by themselves as the limit frees up. Discord messages are not affected.',
      'email-cap:' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD'));
  end if;
  return query
  with c as (
    select m.id from public.message m left join public.domain d on d.id = m.domain_id
     where m.status = 'Pending' and m.direction = 'Outbound'
       and (m.channel <> 'Email' or (select private.email_cap_left()) > 0)
       and (m.audience <> 'Instructor'
            or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                and coalesce(d.status, 'Live') <> 'Paused' and d.archived_at is null))
     order by m.created_at
     limit greatest(1, least(p_limit, 100))
     for update of m skip locked),
  u as (
    update public.message m set status = 'Sending', claimed_at = now(), attempts = m.attempts + 1
      from c where m.id = c.id
    returning m.*)
  select (jsonb_populate_record(null::public.message, to_jsonb(u) || jsonb_build_object(
           'body_text', private.with_tokens(u.body_text, u.instructor_id, u.team_member_id, u.is_test),
           'body_html', private.with_tokens(u.body_html, u.instructor_id, u.team_member_id, u.is_test),
           'buttons', private.with_tokens(u.buttons::text, u.instructor_id, u.team_member_id, u.is_test)::jsonb))).*
    from u;
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
  v_notice boolean;
  v_reach text;
  v_what text;
  v_who text;
  v_first text;
  v_got text[];
  v_title text;
  v_fix text;
begin
  perform private.require_service();
  perform private.set_actor('System', null, 'System');
  select * into m from public.message where id = p_message_id for update;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'unknown message'); end if;
  v_now := case when m.domain_id is not null then private.domain_now(m.domain_id) else now() end;
  if p_ok then
    update public.message set status = 'Sent', sent_at = now(), external_id = p_external_id, last_error = null where id = m.id;
    perform private.log_event(case when m.channel = 'Discord' then 'Discord' else 'Messages' end,
      m.template_id || ' sent to ' || coalesce(m.recipient_label, '?') || ' via ' || private.message_route(m),
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
                and private.days_until(q.module_week_id, v_now) < private.setting_int(q.module_week_id, 'short_notice_days');
  end if;
  perform private.log_event(case when m.channel = 'Discord' then 'Discord' else 'Messages' end,
    m.template_id || ' failed to ' || coalesce(m.recipient_label, '?') || ' via ' || private.message_route(m),
    'message', m.id, null, null, private.message_fix(m, p_error) || ' (' || coalesce(p_error, 'no reason given') || ')', m.domain_id, null, m.module_week_id, null, m.instructor_id, null, m.is_test);
  -- A message about a failure that fails itself is only logged (and posted in the admin channel):
  -- raising a new alert for it could go round and round.
  v_notice := m.template_id = 'T14'
              or exists (select 1 from public.attention_item ai where ai.id = m.attention_item_id and ai.type = 'MessageFailed');
  if m.audience = 'Team' and not v_notice and m.channel = 'Discord' and m.discord_dm_user_id is not null and m.team_member_id is not null then
    -- A team member's direct message failed: they get the same message by email instead.
    perform private.queue_team_message(m.template_id, m.domain_id, 'email', null, array[m.team_member_id],
      m.subject, m.body_text, coalesce(m.unique_key, m.id::text) || ':fallback', now(), false, m.attention_item_id, m.module_week_id, m.help_request_id);
  end if;
  -- Say in plain words what failed and what still reached the person, from what was really queued.
  v_what := 'The ' || coalesce(lower(private.template_defaults() -> m.template_id ->> 'name'), 'message');
  v_who := coalesce(nullif(m.recipient_label, ''), 'the person');
  v_first := coalesce(nullif(private.first_name(v_who), ''), v_who);
  v_title := v_what || case
    when m.channel = 'Discord' and m.discord_channel_id is not null and m.audience = 'Instructor'
      then ' could not be posted in ' || v_who || '''s Discord channel.'
    when m.channel = 'Discord' and m.discord_channel_id is not null then ' could not be posted in ' || v_who || '.'
    when m.channel = 'Discord' then ' could not be sent to ' || v_who || ' as a Discord direct message.'
    else ' could not be emailed to ' || v_who || '.' end;
  select array_agg(distinct case when x.channel = 'Email' then 'email'
                                 when x.discord_dm_user_id is not null then 'direct message'
                                 else 'their Discord channel' end)
    into v_got
    from public.message x
   where x.id <> m.id and x.template_id = m.template_id and x.status <> 'Failed'
     and x.module_week_id is not distinct from m.module_week_id and x.request_id is not distinct from m.request_id
     and x.help_request_id is not distinct from m.help_request_id and x.instructor_id is not distinct from m.instructor_id
     and x.team_member_id is not distinct from m.team_member_id
     and not (x.channel = m.channel and x.discord_dm_user_id is not distinct from m.discord_dm_user_id
              and x.discord_channel_id is not distinct from m.discord_channel_id);
  v_reach := case
    when m.audience = 'Team' and m.channel = 'Discord' and m.discord_dm_user_id is not null
      then ' ' || v_first || ' gets it by email instead.'
    when cardinality(v_got) > 0
      then ' ' || v_first || ' still got it by ' || array_to_string(v_got, ' and ') || '.'
    else ' It did not reach ' || v_first || ' any other way.' end;
  -- The specific advice when the error is a known one; otherwise where to look, without the technical error.
  v_fix := ' ' || private.message_fix(m, p_error);
  if p_error is not null and position(p_error in v_fix) > 0 then
    v_fix := case
      when m.channel = 'Discord' and m.discord_channel_id is not null then ' Check the channel on Settings, Connections.'
      when m.channel = 'Discord' and m.audience = 'Instructor' then ' Check their Discord account on Setup, Instructors.'
      when m.channel = 'Discord' then ' Check their Discord account on Setup, Team.'
      else ' Check the email connection on Settings, Connections.' end;
  end if;
  if m.audience <> 'Admin' and not v_notice then
    -- One task, and the alert about it goes to the operations team by email (see queue_team_message: T14).
    perform private.raise_attention(m.domain_id, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
      v_title,
      ltrim(v_reach || v_fix),
      'msgfail:' || m.id,
      coalesce(nullif(private.domain_role_ids(m.domain_id, 'Ops'), '{}'),
               private.all_operations_ids()),
      v_now, jsonb_build_object('module_week_id', m.module_week_id, 'instructor_id', m.instructor_id, 'message_id', m.id), true, 'T14');
  end if;
  if m.audience <> 'Admin' then
    perform private.queue_team_message('T14', m.domain_id, 'admin', null, '{}', 'Message failed',
      '❗ ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel || ' failed: ' || coalesce(p_error, '?'),
      'T14:' || m.id, now());
  end if;
  return jsonb_build_object('ok', true, 'status', 'Failed');
end;
$$;

create or replace function private.apply_cohort_move(p_cohort uuid, p_from date, p_offset int, p_release uuid[], p_now timestamptz)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_moved jsonb := private.move_cohort_weeks(p_cohort, p_from, p_offset);
  x jsonb;
  w public.module_week;
  v_booking uuid;
  v_sent boolean;
  v_confirmed uuid[] := '{}';
begin
  if jsonb_array_length(v_moved -> 'blocks') > 0 then
    raise exception '%', v_moved -> 'blocks' ->> 0 using errcode = '22023';
  end if;
  for x in select * from jsonb_array_elements(v_moved -> 'weeks') loop
    select * into w from public.module_week where id = (x ->> 'module_week_id')::uuid;
    select b.id into v_booking from public.booking b where b.module_week_id = w.id and b.status = 'Active';
    if w.id = any (coalesce(p_release, '{}')) then
      update public.module_week set time_version = time_version + 1 where id = w.id;
      if v_booking is not null then
        perform private.release_booking_flow(v_booking, 'OpsReleased', p_now, true,
          'The class week moved for a break and they can''t teach the new dates.');
      else
        v_sent := exists (select 1 from public.message m join public.request r on r.id = m.request_id
                           where r.module_week_id = w.id and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')
                             and m.status in ('Sending', 'Sent'));
        if private.withdraw_open_request(w.id, 'Moved for a break', p_now, v_sent) is not null then
          perform private.ask_next(w.id, p_now);
        end if;
      end if;
    elsif (x ->> 'slot_clash')::boolean then
      raise exception '% clashes with another class of the confirmed instructor after the move.', private.mw_label(w.id)
        using errcode = '23P01';
    elsif v_booking is not null then
      update public.module_week set time_version = time_version + 1 where id = w.id;
      v_confirmed := v_confirmed || w.id;
    else
      -- The person being asked gets the request with the new times, as for any time change.
      perform private.week_times_changed(w.id, p_now, false);
    end if;
  end loop;
  return jsonb_build_object('moved', v_moved -> 'weeks', 'confirmed', to_jsonb(v_confirmed));
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
      v_skips := v_skips || l.full_name || ': ' || v_now_reason || '; ';
    elsif l.reason not in ('Already declined this module week', 'Did not reply earlier', 'Skipped by ops',
                           'Cancelled this module week earlier', 'Being asked now') then
      v_skips := v_skips || l.full_name || ': ' || l.reason || '; ';
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
  v_send := private.instructor_send_time(w.id, p_now, v_urgent, private.week_region(p_mw), v_pick.instructor_id);
  v_deadline := least(private.instructor_send_time(w.id, v_send + make_interval(hours => v_win.move_h), v_urgent, private.week_region(p_mw), v_pick.instructor_id),
                      w.first_class_at);
  insert into public.request (module_week_id, instructor_id, kind, status, time_version, line_source,
    declined_before, sent_at, reminder_at, deadline_at, is_test)
  values (p_mw, v_pick.instructor_id, 'Outreach', 'Sent', w.time_version, v_pick.source,
    v_pick.warning is not null, v_send,
    case when v_win.reminder_h is null then null else least(private.instructor_send_time(w.id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(p_mw), v_pick.instructor_id), v_deadline) end,
    v_deadline, v_test)
  returning id into v_req;
  if v_pick.queue_item_id is not null then
    update public.manual_queue_item set asked_request_id = v_req where id = v_pick.queue_item_id;
  end if;
  perform private.queue_instructor_message('M1', v_pick.instructor_id, p_mw, v_req, p_now,
    private.buttons(v_req, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local_both(v_deadline, private.week_region(p_mw))), v_urgent);

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

create or replace function public.share_class_weeks(p_host_id uuid, p_guest_ids uuid[], p_times_from uuid default null,
  p_release_instructors boolean default false, p_save boolean default false, p_accept_warnings boolean default false,
  p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_plan jsonb;
  h public.module_week;
  v_guest uuid;
  v_now timestamptz;
  k record;
  v_moved boolean := false;
  v_clash boolean := false;
  bk public.booking;
  v_sent boolean;
  v_name text;
begin
  perform private.require_team();
  select * into h from public.module_week where id = p_host_id;
  if p_save and h.id is not null then perform pg_advisory_xact_lock(hashtext('plan:' || h.domain_id::text)); end if;
  v_plan := private.share_plan(p_host_id, p_guest_ids, p_times_from, p_release_instructors);
  if not p_save then return v_plan || jsonb_build_object('ok', true, 'preview', true); end if;
  if jsonb_array_length(v_plan -> 'blocks') > 0 then return v_plan || jsonb_build_object('ok', false); end if;
  if exists (select 1 from jsonb_array_elements(v_plan -> 'warnings') x where x ->> 'level' = 'Warning') and not p_accept_warnings then
    return v_plan || jsonb_build_object('ok', false, 'needs_confirmation', true);
  end if;
  v_now := private.domain_now(h.domain_id);
  perform private.log_accepted_warnings(v_plan -> 'warnings', p_reason, h.domain_id, h.module_id, h.id);

  -- The shared class keeps a guest's times: the host's classes move, and its instructor is asked as usual.
  if p_times_from is not null and p_times_from <> h.id then
    for k in select a.id, b.starts_at, b.ends_at from private.week_classes(h.id) a join private.week_classes(p_times_from) b using (n)
              where (a.starts_at, a.ends_at) is distinct from (b.starts_at, b.ends_at) order by b.starts_at desc loop
      v_clash := private.move_class(k.id, k.starts_at, k.ends_at) or v_clash;
      v_moved := true;
    end loop;
    if v_clash then raise exception 'The host''s instructor clashes at the chosen time.' using errcode = '23P01'; end if;
  end if;

  foreach v_guest in array p_guest_ids loop
    v_sent := exists (select 1 from public.message m join public.request r on r.id = m.request_id
                       where r.module_week_id = v_guest and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')
                         and m.status in ('Sending', 'Sent'));
    perform private.withdraw_open_request(v_guest, 'Shared with another class', v_now, v_sent);
    for bk in select * from public.booking where module_week_id = v_guest and status = 'Active' loop
      select full_name into v_name from public.instructor where id = bk.instructor_id;
      update public.booking set status = 'Released', released_at = v_now, release_reason = 'OpsReleased' where id = bk.id;
      update public.request set status = 'Superseded', close_reason = 'Booking released'
       where booking_id = bk.id and status in ('Queued', 'Sent', 'Reminded');
      -- The host's own instructor teaches the shared class, so only someone else hears they are no longer needed.
      if bk.instructor_id is distinct from (select x.instructor_id from public.booking x where x.module_week_id = h.id and x.status = 'Active') then
        perform private.queue_instructor_message('M16', bk.instructor_id, v_guest, null, v_now, '[]', '{}', false, 'release:' || bk.id);
      end if;
      perform private.log_event('Bookings', 'Booking released: ' || v_name, 'booking', bk.id, jsonb_build_object('status', 'Active'),
        jsonb_build_object('status', 'Released', 'reason', 'Shared with another class'), null,
        h.domain_id, (select module_id from public.module_week where id = v_guest), v_guest, null, bk.instructor_id);
    end loop;
    perform set_config('app.share_sync', 'on', true);
    update public.class_session g set starts_at = a.starts_at, ends_at = a.ends_at, shared_class_id = a.id
      from private.week_classes(h.id) a join private.week_classes(v_guest) x using (n)
     where g.id = x.id;
    perform set_config('app.share_sync', 'off', true);
    update public.module_week set shared_with = h.id, paused = true, status = 'Planned', at_risk = false, at_risk_reason = null
     where id = v_guest;
    perform private.log_event('Team actions', 'Class shared', 'module_week', v_guest, null,
      jsonb_build_object('host', h.id, 'host_label', private.mw_label(h.id)), null,
      h.domain_id, (select module_id from public.module_week where id = v_guest), v_guest);
  end loop;
  if v_moved then perform private.week_times_changed(h.id, v_now, false); end if;
  perform private.log_event('Team actions', 'Class shared with ' || cardinality(p_guest_ids) || ' other class week(s)', 'module_week',
    h.id, null, jsonb_build_object('guests', to_jsonb(p_guest_ids)), null, h.domain_id, h.module_id, h.id);
  perform private.queue_deliver('share');
  return v_plan || jsonb_build_object('ok', true, 'saved', cardinality(p_guest_ids));
end;
$$;

create or replace function private.email_cap_left()
returns int language sql stable security definer set search_path = ''
as $$
  select (select c.daily_email_cap from public.app_config c where c.id = 1)
       - (select count(*)::int from public.message m
           where m.direction = 'Outbound' and m.channel = 'Email' and m.status in ('Sent', 'Sending')
             and coalesce(m.sent_at, m.claimed_at) > now() - interval '24 hours');
$$;
