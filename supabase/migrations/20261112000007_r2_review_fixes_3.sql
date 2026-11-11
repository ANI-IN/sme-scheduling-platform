-- Release 2 Milestone F: the fixes the reviewers did not confirm on their second pass
-- (the "Confirmation (second pass)" sections of docs/reviews/*.md).


-- SEC-11: the automation puts a link's secret back only when the link belongs to the person the message
-- is for (the instructor, or the team member for an owner check). A placeholder copied from another
-- message into text the team writes becomes "expired", never someone else's working link.
create or replace function private.with_tokens(p text, p_instructor uuid, p_team uuid, p_test boolean)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare m text[]; v text := p;
begin
  if p is null or position('{{t:' in p) = 0 then return p; end if;
  for m in select regexp_matches(p, '\{\{t:([0-9a-f]{32})\}\}', 'g') loop
    v := replace(v, '{{t:' || m[1] || '}}',
                 coalesce((select l.token from public.response_link l join public.request r on r.id = l.request_id
                            where md5(l.token) = m[1]
                              and ((p_instructor is not null and r.instructor_id = p_instructor)
                                   or (p_team is not null and r.team_member_id = p_team))
                              -- SEC-15: a real link never goes into a test copy, nor a test link into a real message.
                              and r.is_test is not distinct from p_test
                            limit 1), 'expired'));
  end loop;
  return v;
end;
$$;
revoke execute on function private.with_tokens(text, uuid, uuid, boolean) from public;

create or replace function public.claim_outbound_messages(p_limit int default 25)
returns setof public.message language plpgsql security definer set search_path = ''
as $$
declare v_stuck uuid;
begin
  perform private.require_team();
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
  return query
  with c as (
    select m.id from public.message m left join public.domain d on d.id = m.domain_id
     where m.status = 'Pending' and m.direction = 'Outbound'
       and (m.audience <> 'Instructor'
            or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                and coalesce(d.status, 'Live') <> 'Paused'))
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

-- SEC-12: the answer pages show working buttons (for example "Need help" after "All set"), with the
-- secret of the same person's own links only.
create or replace function public.response_page(p_token text)
returns public."text/html" language sql security definer set search_path = ''
as $$
  select private.with_tokens(public.response_page_text(p_token),
           (select q.instructor_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.team_member_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.is_test from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token)
         )::public."text/html";
$$;

create or replace function public.submit_response_page(p_token text, p_form jsonb default '{}')
returns public."text/html" language sql security definer set search_path = ''
as $$
  select private.with_tokens(public.submit_response_page_text(p_token, p_form),
           (select q.instructor_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.team_member_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.is_test from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token)
         )::public."text/html";
$$;
grant execute on function public.response_page(text) to service_role;
grant execute on function public.submit_response_page(text, jsonb) to service_role;

drop function if exists private.with_tokens(text);
drop function if exists private.with_tokens(text, uuid, uuid);

create or replace function private.message_block_reason(m public.message)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  c public.app_config;
  i public.instructor;
  v_server text;
  v_domain text;
begin
  if m.direction <> 'Outbound' then return null; end if;
  select * into c from public.app_config where id = 1;
  if m.instructor_id is not null then
    select * into i from public.instructor where id = m.instructor_id;
  end if;
  if c.environment = 'Production' and m.audience = 'Instructor' and coalesce(i.is_test, false) then
    return 'Production never messages test instructors.';
  end if;
  if m.channel = 'Discord' and m.discord_channel_id is not null and m.discord_dm_user_id is not null then
    return 'A Discord message goes either to a channel or to one person, not both.';
  end if;
  if c.environment = 'Sandbox' then
    if m.channel = 'Email' then
      if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
         and not private.is_test_domain(m.domain_id) then
        return 'Sandbox never contacts real instructors by email, even at an allowed address. Mark them as a test instructor to try this.';
      end if;
      v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
      if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.sandbox_allowed_email_domains) x))) then
        return 'Sandbox only sends email to allowed domains. ' || coalesce(nullif(v_domain, ''), 'This address') || ' is not on the list.';
      end if;
    elsif m.channel = 'Discord' then
      if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
         and not private.is_test_domain(m.domain_id) then
        return 'Sandbox never contacts real instructors on Discord. Mark them as a test instructor to try this.';
      end if;
      -- A post goes to the server of its channel. A direct message is allowed only to a test instructor
      -- or a team member (Sandbox never contacts real instructors).
      if m.discord_dm_user_id is not null and m.discord_channel_id is null then
        if m.audience = 'Instructor' and not coalesce(i.is_test, false) then
          return 'Sandbox only sends direct messages to test instructors.';
        end if;
        -- SEC-5: only to the Discord account of a team member who still has access (test instructors use
        -- the account of the person testing), never to an account a real instructor uses or one the bot
        -- found in another server.
        if exists (select 1 from public.instructor x where x.discord_user_id = m.discord_dm_user_id and not x.is_test)
           or not exists (select 1 from public.team_member t where t.discord_user_id = m.discord_dm_user_id
                           and t.access_removed_at is null) then
          return 'Sandbox only sends direct messages to the Discord accounts of team members. Test instructors use the Discord account of the person testing.';
        end if;
        return null;
      end if;
      -- The channel must be one the bot listed, in an allowed server (no guessing from the domain).
      v_server := (select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id);
      if v_server is null then
        return 'Sandbox only posts to channels the bot has listed. Press Check on Settings, Connections first.';
      end if;
      if not (v_server = any (c.sandbox_allowed_discord_servers)) then
        return 'Sandbox only posts to allowed Discord servers. Server ' || v_server || ' is not on the list.';
      end if;
    end if;
  end if;
  return null;
end;
$$;

-- OUT-3: pausing is about asking. A class week with a confirmed instructor has nobody to ask, and pausing it
-- would silently stop its reminders before class and its time changes, so it is refused. Weeks paused
-- that way before are unpaused.
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
  perform private.log_event('Team actions', case when p_paused then 'Outreach paused' else 'Outreach resumed' end,
    'module_week', p_module_week_id, null, null, null, w.domain_id, w.module_id, p_module_week_id);
end;
$$;

update public.module_week w set paused = false
 where w.paused and exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Active');

create or replace function private.week_times_changed(p_mw uuid, p_now timestamptz, p_clash boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  b public.booking;
  r public.request;
  v_win record;
  v_urgent boolean;
  v_send timestamptz;
  v_deadline timestamptz;
begin
  update public.module_week set time_version = time_version + 1 where id = p_mw returning * into w;
  select * into b from public.booking where module_week_id = w.id and status = 'Active';
  if b.id is not null then
    if p_clash then
      perform private.release_booking_flow(b.id, 'TimeClash', p_now, true);
      return jsonb_build_object('released', true, 'reason', 'clash');
    end if;
    -- The time-change request (M5) is created by the engine step; run it now unless instructor
    -- messages are paused (then the next allowed hourly run creates it).
    if private.instructor_messages_allowed(w.domain_id) and not w.paused then
      perform private.step_time_changes(w.domain_id, p_now);
    end if;
    return jsonb_build_object('time_change_request', exists (
      select 1 from public.request q where q.module_week_id = w.id and q.kind = 'TimeChange'
         and q.status in ('Queued', 'Sent', 'Reminded')));
  end if;

  select * into r from public.request
   where module_week_id = w.id and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded') for update;
  if r.id is not null then
    -- Recalculate the response window for the new times (the class may now be much closer).
    v_win := private.window_hours(w.id, p_now);
    v_urgent := v_win.band = 'Short';
    v_send := private.instructor_send_time(w.id, p_now, v_urgent, private.week_region(w.id));
    v_deadline := least(greatest(r.sent_at, p_now) + make_interval(hours => v_win.move_h), w.first_class_at);
    v_deadline := least(private.instructor_send_time(w.id, v_deadline, v_urgent, private.week_region(w.id)), w.first_class_at);
    update public.request
       set time_version = w.time_version,
           deadline_at = least(deadline_at, v_deadline),
           reminder_at = case when v_win.reminder_h is null or reminder_at is null then null else least(reminder_at, private.instructor_send_time(w.id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(w.id)), v_deadline) end
     where id = r.id
    returning * into r;
    perform private.queue_instructor_message('M5', r.instructor_id, w.id, r.id, p_now,
      private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local(r.deadline_at, private.week_region(w.id))), v_urgent);
    return jsonb_build_object('updated_request', true);
  end if;
  return jsonb_build_object('ok', true);
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
      'Outreach started: ' || private.mw_label(p_mw),
      '📣 Outreach started for ' || private.mw_label(p_mw) || ' — asking ' || v_pick.full_name || '.',
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
    v_send := private.instructor_send_time(b.module_week_id, p_now, v_urgent, private.week_region(b.module_week_id));
    v_deadline := least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => v_win.move_h), v_urgent, private.week_region(b.module_week_id)), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, status, time_version, sent_at, reminder_at,
      deadline_at, is_test)
    values (b.module_week_id, b.instructor_id, b.id, 'TimeChange', 'Sent', b.mw_tv, v_send,
      case when v_win.reminder_h is null then null else least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(b.module_week_id)), v_deadline) end,
      v_deadline, b.is_test)
    returning id into v_req;
    perform private.queue_instructor_message('M5', b.instructor_id, b.module_week_id, v_req, p_now,
      private.buttons(v_req, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_local(v_deadline, private.week_region(b.module_week_id))), v_urgent);
    perform private.log_event('Messages', 'Time-change request sent', 'request', v_req, null,
      jsonb_build_object('time_version', b.mw_tv), null, p_domain, null, b.module_week_id, null, b.instructor_id, null, b.is_test);
    n := n + 1;
  end loop;
  return n;
end;
$$;
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
  v_urgent_band int;
  v_name text;
begin

  for b in select bk.*, mw.first_class_at, mw.module_id
             from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and not mw.paused and mw.first_class_at > p_now
            for update of bk skip locked loop
    v_days := private.checkin_days_for(b.module_week_id);
    v_last := private.last_checkin_day(b.module_week_id);
    v_urgent_band := private.setting_int(b.module_week_id, 'urgent_band_days');
    select min(d) into v_due from unnest(v_days) d
     where b.first_class_at - make_interval(days => d) <= p_now
       and b.confirmed_at < b.first_class_at - make_interval(days => d);
    continue when v_due is null;
    continue when exists (select 1 from public.request q where q.booking_id = b.id and q.kind = 'CheckIn' and q.check_in_days <= v_due);
    v_rem := case when v_due > v_urgent_band then 24 else 12 end;
    v_send := private.instructor_send_time(b.module_week_id, p_now, v_due <= v_urgent_band, private.week_region(b.module_week_id));
    v_deadline := least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => 2 * v_rem), v_due <= v_urgent_band, private.week_region(b.module_week_id)), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, check_in_days, status, sent_at,
      reminder_at, deadline_at, is_test, time_version)
    values (b.module_week_id, b.instructor_id, b.id, 'CheckIn', v_due, 'Sent', v_send,
      least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => v_rem), v_due <= v_urgent_band, private.week_region(b.module_week_id)), v_deadline),
      v_deadline, b.is_test, (select mw.time_version from public.module_week mw where mw.id = b.module_week_id))
    returning id into v_req;
    v_tpl := case when v_due = v_last then 'M7' when v_due = 14 and v_due <> all (array(select x::int from jsonb_array_elements_text(private.get_setting(b.module_week_id, 'checkin_days')) x)) then 'M8' else 'M6' end;
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
    v_last := private.last_checkin_day(r.module_week_id);
    v_urgent_band := private.setting_int(r.module_week_id, 'urgent_band_days');
    if r.deadline_at <= p_now then
      update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
      perform private.log_event('Messages', 'No reply to the ' || r.check_in_days || '-day check-in from ' || v_name, 'request', r.id,
        null, null, null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
      if r.check_in_days = v_last and private.setting_text(r.module_week_id, 'last_checkin_no_reply') = 'Release' then
        perform private.release_booking_flow(r.booking_id, 'NoReplyRelease', p_now);
      else
        perform private.raise_attention(p_domain, 'CheckInNoReply',
          case when r.check_in_days = v_last then 'Urgent' else 'Normal' end,
          'No reply to the ' || r.check_in_days || '-day check-in: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'The booking is kept. Please check with them.', 'checkin_noreply:' || r.id,
          private.ops_for_week(r.module_week_id), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)));
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now and private.setting_bool(r.module_week_id, 'remind_instructor_after_assign') then
      update public.request set status = 'Reminded', reminded_at = p_now where id = r.id;
      perform private.queue_instructor_message('M9', r.instructor_id, r.module_week_id, r.id, p_now,
        private.buttons(r.id, array['AllSet', 'NeedHelp', 'CantMakeIt']), '{}', r.check_in_days <= v_urgent_band);
      n := n + 1;
    end if;
  end loop;
  return n;
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
    raise exception 'Test mode changed since this message was sent. Send a new message instead (e.g. resend the check-in from Outreach after the next run).';
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
create or replace function public.add_one_class(p_module_week_id uuid, p_module_id uuid, p_cohort_id uuid,
  p_date date, p_start time, p_end time, p_class_type text, p_title text default null,
  p_accept_warnings boolean default false, p_reason text default null, p_region text default null, p_fold int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  m public.module;
  v_cohort uuid := p_cohort_id;
  v_start timestamptz;
  v_end timestamptz;
  v_warn jsonb;
  v_class uuid;
  v_booking public.booking;
  v_clash boolean := false;
  v_title text;
  v_seq int;
  v jsonb := '{}';
  v_region text;
  v_amb jsonb;
begin
  perform private.require_team();
  if p_module_week_id is not null then
    select * into w from public.module_week where id = p_module_week_id for update;
    if w.status in ('Cancelled', 'Completed') then raise exception 'This class week is already finished or cancelled.' using errcode = '22023'; end if;
    select * into m from public.module where id = w.module_id;
    v_cohort := w.cohort_id;
  else
    select * into m from public.module where id = p_module_id;
    if m.id is null then raise exception 'Choose a module.' using errcode = '22023'; end if;
    if v_cohort is null then raise exception 'Choose a cohort.' using errcode = '22023'; end if;
    if (select domain_id from public.cohort where id = v_cohort) <> m.domain_id then
      raise exception 'The cohort belongs to another domain.' using errcode = '22023';
    end if;
  end if;
  if p_start is null or p_end is null or p_date is null then raise exception 'Choose a date, a start time and an end time.' using errcode = '22023'; end if;
  if p_end = p_start then raise exception 'The class must end after it starts.' using errcode = '22023'; end if;
  if coalesce(trim(p_class_type), '') = '' then raise exception 'Choose a class type.' using errcode = '22023'; end if;
  -- The class's region: chosen for this class, else its cohort's.
  v_region := coalesce(p_region, (select co.region from public.cohort co where co.id = v_cohort), 'US');
  if v_region not in ('US', 'India') then raise exception 'Choose US or India.' using errcode = '22023'; end if;
  v_title := coalesce(nullif(trim(p_title), ''), m.name || ': ' || trim(p_class_type));
  v_amb := private.ambiguous_warning(p_date, p_start, v_region, v_title);
  if v_amb is not null and p_fold is null then
    -- A time that happens twice must be chosen, even when other warnings are accepted.
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'needs_choice', true, 'warnings', jsonb_build_array(v_amb));
  end if;
  v_start := private.local_to_utc(p_date, p_start, v_region, p_fold);
  v_end := private.local_to_utc(p_date + case when p_end <= p_start then 1 else 0 end, p_end, v_region, p_fold);
  v_warn := private.class_warnings(m.domain_id, v_cohort, v_start, v_end, null, v_title, v_region);
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;

  if w.id is null or not w.same_instructor then
    select coalesce(max(seq), 0) + 1 into v_seq from public.module_week where module_id = m.id and cohort_id = v_cohort and week_start_date = p_date;
    insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour, same_instructor)
    values (m.id, v_cohort, p_date, v_seq, private.setting_text(coalesce(v_cohort, m.domain_id), 'default_outreach_mode'),
            private.setting_text(coalesce(v_cohort, m.domain_id), 'manual_end_behaviour'), coalesce(w.same_instructor, m.same_instructor_for_module_week))
    returning * into w;
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region)
    values (w.id, trim(p_class_type), v_title, v_start, v_end, v_region) returning id into v_class;
    v := jsonb_build_object('new_class_week', true);
  else
    if private.week_self_overlap(w.id, v_start, v_end) is not null then
      raise exception 'This class overlaps another class of the same class week: %. One instructor teaches the whole week, so choose another time.',
        private.week_self_overlap(w.id, v_start, v_end) using errcode = '23P01';
    end if;
    select * into v_booking from public.booking where module_week_id = w.id and status = 'Active';
    -- The instructor of this class week teaches the new class too: never at the same time as another class.
    if v_booking.id is not null and private.clash_text(v_booking.instructor_id, v_start, v_end, v_region) is not null then
      raise exception '% cannot teach this class: %.', (select full_name from public.instructor where id = v_booking.instructor_id),
        private.clash_text(v_booking.instructor_id, v_start, v_end, v_region) using errcode = '23P01';
    end if;
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region)
    values (w.id, trim(p_class_type), v_title, v_start, v_end, v_region) returning id into v_class;
    if v_booking.id is not null then
      begin
        insert into public.booking_slot (booking_id, class_id, instructor_id, time_range)
        values (v_booking.id, v_class, v_booking.instructor_id, tstzrange(v_start, v_end, '[)'));
      exception when exclusion_violation then
        v_clash := true;
      end;
    end if;
    v := private.week_times_changed(w.id, private.mw_now(w.id), v_clash);
  end if;
  perform private.log_event('Team actions', 'Class added', 'class_session', v_class, null,
    jsonb_build_object('title', v_title, 'shown', private.fmt_class_range(v_start, v_end, v_region), 'region', v_region), nullif(trim(coalesce(p_reason, '')), ''),
    m.domain_id, m.id, w.id, v_class);
  perform private.log_accepted_warnings(v_warn, p_reason, m.domain_id, m.id, w.id, v_class);
  perform private.queue_deliver('class added');
  return jsonb_build_object('ok', true, 'class_id', v_class, 'module_week_id', w.id, 'warnings', v_warn) || v;
end;
$$;
create or replace function public.send_test_message(p_instructor_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_req uuid; v_n int; v_name text;
begin
  perform private.require_team();
  select full_name into v_name from public.instructor where id = p_instructor_id;
  if v_name is null then raise exception 'Instructor not found.'; end if;
  -- One contact check at a time per instructor, even on a double click.
  perform 1 from public.instructor where id = p_instructor_id for update;
  if exists (select 1 from public.message m join public.request q on q.id = m.request_id
              where q.instructor_id = p_instructor_id and q.kind = 'Test' and q.status in ('Queued', 'Sent', 'Reminded')
                and m.status in ('Scheduled', 'Pending', 'Sending')) then
    raise exception 'A contact check for % is already on its way. It goes out within a few minutes; send another one after that if they do not answer.', v_name
      using errcode = '22023';
  end if;
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
