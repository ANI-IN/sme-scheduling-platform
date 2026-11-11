-- Release 2 Milestone A: simpler settings and reminders that can be switched off.
-- Settings: built in default, then the domain, then an optional cohort override. No other layers.
-- Every reminder can be switched off or set to 0. The main automation never depends on reminders:
-- asking in order, moving on, confirming and urgent alerts always run.

-- =============================================================== settings layers
-- Values set for every domain become each domain's own value (where the domain has none).
insert into public.setting (scope, domain_id, key, value, reason)
select 'Domain', d.id, g.key, g.value, 'Copied from the settings for every domain (Release 2)'
  from public.setting g cross join public.domain d
 where g.scope = 'Global'
   and not exists (select 1 from public.setting s where s.scope = 'Domain' and s.domain_id = d.id and s.key = g.key);
delete from public.setting where scope in ('Global', 'Module', 'ModuleWeek');

create or replace function private.setting_chain(p_id uuid)
returns table (scope text, scope_id uuid, ord int)
language sql stable security definer set search_path = ''
as $$
  with w as (select id, cohort_id, domain_id from public.module_week where id = p_id),
       m as (select id, domain_id from public.module where id = p_id),
       c as (select id, domain_id from public.cohort where id = p_id)
  select 'Cohort', w.cohort_id, 3 from w where w.cohort_id is not null
  union all select 'Domain', w.domain_id, 4 from w
  union all select 'Domain', m.domain_id, 4 from m
  union all select 'Cohort', c.id, 3 from c
  union all select 'Domain', c.domain_id, 4 from c
  union all select 'Domain', p_id, 4
   where p_id is not null and not exists (select 1 from w) and not exists (select 1 from m) and not exists (select 1 from c);
$$;

create or replace function private.setting_with_source(p_id uuid, p_key text, out value jsonb, out source text, out source_id uuid)
language sql stable security definer set search_path = ''
as $$
  select coalesce(x.value, d.default_value), coalesce(x.scope, 'Default'), x.scope_id
    from public.setting_definition d
    left join lateral (
      select s.value, ch.scope, ch.scope_id
        from private.setting_chain(p_id) ch
        join public.setting s on s.key = p_key and s.scope = ch.scope
                             and coalesce(s.cohort_id, s.domain_id) = ch.scope_id
       order by ch.ord limit 1) x on true
   where d.key = p_key;
$$;

create or replace function public.set_setting_at(p_scope text, p_scope_id uuid, p_key text, p_value jsonb, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_scope not in ('Domain', 'Cohort') then
    raise exception 'Settings are set for a domain or for one cohort.' using errcode = '22023';
  end if;
  insert into public.setting (scope, domain_id, cohort_id, module_id, module_week_id, key, value, reason)
  values (p_scope,
          case when p_scope = 'Domain' then p_scope_id end,
          case when p_scope = 'Cohort' then p_scope_id end,
          case when p_scope = 'Module' then p_scope_id end,
          case when p_scope = 'ModuleWeek' then p_scope_id end,
          p_key, p_value, nullif(trim(coalesce(p_reason, '')), ''))
  on conflict (key, scope, coalesce(module_week_id, module_id, cohort_id, domain_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set value = excluded.value, reason = excluded.reason;
end;
$$;

-- =============================================================== settings that are no longer offered
-- The optional 14 day reminder becomes one more number in the reminders before class.
update public.setting s set value = (
    select to_jsonb(array(select distinct x from (
      select (e #>> '{}')::int x from jsonb_array_elements(coalesce(
        (select c.value from public.setting c where c.key = 'checkin_days' and c.scope = s.scope
            and coalesce(c.cohort_id, c.domain_id) = coalesce(s.cohort_id, s.domain_id)),
        (select d.default_value from public.setting_definition d where d.key = 'checkin_days'))) e
      union all select 14) y order by x desc)))
 where s.key = 'checkin_14_enabled' and s.value = 'true'::jsonb;
insert into public.setting (scope, domain_id, cohort_id, key, value, reason)
select s.scope, s.domain_id, s.cohort_id, 'checkin_days', s.value, 'The 14 day reminder is now part of the reminders before class'
  from public.setting s where s.key = 'checkin_14_enabled' and jsonb_typeof(s.value) = 'array'
on conflict (key, scope, coalesce(module_week_id, module_id, cohort_id, domain_id, '00000000-0000-0000-0000-000000000000'::uuid))
do update set value = excluded.value;
delete from public.setting where key in ('checkin_14_enabled', 'team_channels', 'instructor_channels', 'digest_time_ist');
delete from public.setting_definition where key in ('checkin_14_enabled', 'team_channels', 'instructor_channels', 'digest_time_ist');

-- =============================================================== reminders: switches, and 0 means no reminder
insert into public.setting_definition (key, group_name, label, value_type, default_value, help, sort_order) values
  ('answer_reminders', 'Reminders', 'Remind the instructor while we wait for their answer', 'bool', 'true',
   'A reminder before we ask the next instructor. Off: we wait, then ask the next instructor without a reminder.', 400),
  ('remind_instructor_after_assign', 'Reminders', 'Remind the instructor after they are assigned', 'bool', 'true',
   'Short reminders before the class, on the days below.', 410),
  ('remind_team_after_assign', 'Reminders', 'Remind the team after an instructor is assigned', 'bool', 'true',
   'The module owners are asked if everything is ready, and the operations team is reminded about class tasks.', 420),
  ('daily_summary', 'Reminders', 'Send each team member a daily summary', 'bool', 'true',
   'One message each morning (10:00 AM India time) with their open tasks.', 440)
on conflict (key) do nothing;

update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 401,
       label = 'More than 10 days before the class: remind after (hours)' where key = 'window_long_reminder_h';
update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 402,
       label = '3 to 10 days before the class: remind after (hours)' where key = 'window_mid_reminder_h';
update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 403,
       label = 'Under 3 days before the class: remind after (hours)' where key = 'window_short_reminder_h';
update public.setting_definition set group_name = 'Reminders', sort_order = 411,
       label = 'Reminders before class (days before the class)',
       help = 'For example 10, 2. The smallest number is the last reminder. Leave empty for none.' where key = 'checkin_days';
update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 421,
       label = 'Ask the module owners if everything is ready (days before the class)' where key = 'owner_checkin_days';
update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 422,
       label = 'Remind the operations team about class tasks (days after an instructor confirms)' where key = 'checklist_nudge_days';
update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 430,
       label = 'Remind the team again about an open task after (hours)' where key = 'reminder_r2_normal_h';
update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 431,
       label = 'Remind the team again about an urgent task every (hours)' where key = 'reminder_r2_urgent_h';
update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 432,
       label = 'Tell the escalation contacts about a task still open after (hours)' where key = 'reminder_escalate_normal_h';
update public.setting_definition set group_name = 'Reminders', min_value = 0, sort_order = 433,
       label = 'Tell the escalation contacts about an urgent task still open after (hours)' where key = 'reminder_escalate_urgent_h';
update public.setting_definition set group_name = 'LastReminder' where group_name = 'Check-ins';

create or replace function private.validate_setting()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  d public.setting_definition;
  v jsonb := new.value;
  e jsonb;
  n int;
  v_out int;
  v_read int;
  v_dom uuid := coalesce(new.module_week_id, new.module_id, new.cohort_id, new.domain_id);
begin
  select * into d from public.setting_definition where key = new.key;
  if d.value_type = 'int' then
    if jsonb_typeof(v) <> 'number' or (v #>> '{}') !~ '^-?\d+$' then
      raise exception '"%" must be a whole number.', d.label using errcode = '22023';
    end if;
    n := (v #>> '{}')::int;
    if (d.min_value is not null and n < d.min_value) or (d.max_value is not null and n > d.max_value) then
      raise exception '"%" must be between % and %.', d.label, d.min_value, d.max_value using errcode = '22023';
    end if;
  elsif d.value_type = 'bool' then
    if jsonb_typeof(v) <> 'boolean' then
      raise exception '"%" must be on or off.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'enum' then
    if jsonb_typeof(v) <> 'string' or not (d.allowed @> jsonb_build_array(v)) then
      raise exception '"%" must be one of: %.', d.label, d.allowed using errcode = '22023';
    end if;
  elsif d.value_type = 'time' then
    if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^([01]\d|2[0-3]):[0-5]\d$' then
      raise exception '"%" must be a time like 09:00.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'int_list' then
    if jsonb_typeof(v) <> 'array' or (jsonb_array_length(v) = 0 and new.key <> 'checkin_days') then
      raise exception '"%" needs at least one value.', d.label using errcode = '22023';
    end if;
    for e in select * from jsonb_array_elements(v) loop
      if jsonb_typeof(e) <> 'number' or (e #>> '{}')::numeric not between d.min_value and d.max_value then
        raise exception '"%": every value must be between % and %.', d.label, d.min_value, d.max_value using errcode = '22023';
      end if;
    end loop;
  elsif d.value_type = 'text_list' then
    if jsonb_typeof(v) <> 'array' then
      raise exception '"%" must be a list.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'json' then
    if jsonb_typeof(v) <> 'object' then
      raise exception '"%" must be an object.', d.label using errcode = '22023';
    end if;
    if d.allowed is not null then
      for e in select value from jsonb_each(v) loop
        if not (d.allowed @> jsonb_build_array(e)) then
          raise exception '"%": each value must be one of %.', d.label, d.allowed using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  -- Cross-field rules (evaluated with this new value in place). Saving many settings at once checks
  -- them after all values are in place instead (private.check_setting_rules).
  if current_setting('app.settings_batch', true) = 'on' then
    return new;
  end if;
  if new.key in ('outreach_days', 'readiness_days') then
    v_out := case when new.key = 'outreach_days' then (v #>> '{}')::int else private.setting_int(v_dom, 'outreach_days') end;
    v_read := case when new.key = 'readiness_days' then (v #>> '{}')::int else private.setting_int(v_dom, 'readiness_days') end;
    if v_read < v_out + 5 then
      raise exception 'The setup check must be at least 5 days before instructors are first asked. Asking starts % days before the class, so the setup check must be at least % days before.',
        v_out, v_out + 5 using errcode = '22023';
    end if;
  end if;
  if new.key in ('instructor_quiet_start', 'instructor_quiet_end') then
    if private.time_window_minutes(
         case when new.key = 'instructor_quiet_start' then v #>> '{}' else private.setting_text(v_dom, 'instructor_quiet_start') end,
         case when new.key = 'instructor_quiet_end' then v #>> '{}' else private.setting_text(v_dom, 'instructor_quiet_end') end) > 720 then
      raise exception 'Quiet hours for instructors can be at most 12 hours long.' using errcode = '22023';
    end if;
  end if;
  if new.key in ('team_quiet_start', 'team_quiet_end') then
    if private.time_window_minutes(
         case when new.key = 'team_quiet_start' then v #>> '{}' else private.setting_text(v_dom, 'team_quiet_start') end,
         case when new.key = 'team_quiet_end' then v #>> '{}' else private.setting_text(v_dom, 'team_quiet_end') end) > 840 then
      raise exception 'Quiet hours for the team can be at most 14 hours long.' using errcode = '22023';
    end if;
  end if;
  if false then
    raise exception 'Choose at least one channel.' using errcode = '22023';
  end if;
  return new;
end;
$$;

create or replace function private.window_hours(p_mw uuid, p_now timestamptz, out band text, out reminder_h int, out move_h int)
language plpgsql stable security definer set search_path = ''
as $$
declare v_dom uuid := (select w.domain_id from public.module_week w where w.id = p_mw);
begin
  band := private.band(p_mw, p_now);
  reminder_h := nullif(private.setting_int(p_mw, case band when 'Long' then 'window_long_reminder_h' when 'Mid' then 'window_mid_reminder_h' else 'window_short_reminder_h' end), 0);
  -- Off or 0: no reminder (null). Moving on to the next instructor is not affected.
  if not private.setting_bool(p_mw, 'answer_reminders') then reminder_h := null; end if;
  move_h := private.setting_int(p_mw, case band when 'Long' then 'window_long_move_h' when 'Mid' then 'window_mid_move_h' else 'window_short_move_h' end);
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
  v_send := private.instructor_send_time(w.domain_id, p_now, v_urgent);
  v_deadline := least(private.instructor_send_time(w.domain_id, v_send + make_interval(hours => v_win.move_h), v_urgent),
                      w.first_class_at);
  insert into public.request (module_week_id, instructor_id, kind, status, time_version, line_source,
    declined_before, sent_at, reminder_at, deadline_at, is_test)
  values (p_mw, v_pick.instructor_id, 'Outreach', 'Sent', w.time_version, v_pick.source,
    v_pick.warning is not null, v_send,
    case when v_win.reminder_h is null then null else least(private.instructor_send_time(w.domain_id, v_send + make_interval(hours => v_win.reminder_h), v_urgent), v_deadline) end,
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
    v_send := private.instructor_send_time(p_domain, p_now, v_urgent);
    v_deadline := least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_win.move_h), v_urgent), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, status, time_version, sent_at, reminder_at,
      deadline_at, is_test)
    values (b.module_week_id, b.instructor_id, b.id, 'TimeChange', 'Sent', b.mw_tv, v_send,
      case when v_win.reminder_h is null then null else least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_win.reminder_h), v_urgent), v_deadline) end,
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
    return jsonb_build_object('time_change_request', true);
  end if;

  select * into r from public.request
   where module_week_id = w.id and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded') for update;
  if r.id is not null then
    -- Recalculate the response window for the new times (the class may now be much closer).
    v_win := private.window_hours(w.id, p_now);
    v_urgent := v_win.band = 'Short';
    v_send := private.instructor_send_time(w.domain_id, p_now, v_urgent);
    v_deadline := least(greatest(r.sent_at, p_now) + make_interval(hours => v_win.move_h), w.first_class_at);
    v_deadline := least(private.instructor_send_time(w.domain_id, v_deadline, v_urgent), w.first_class_at);
    update public.request
       set time_version = w.time_version,
           deadline_at = least(deadline_at, v_deadline),
           reminder_at = case when v_win.reminder_h is null or reminder_at is null then null else least(reminder_at, private.instructor_send_time(w.domain_id, v_send + make_interval(hours => v_win.reminder_h), v_urgent), v_deadline) end
     where id = r.id
    returning * into r;
    perform private.queue_instructor_message('M5', r.instructor_id, w.id, r.id, p_now,
      private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_pt(r.deadline_at)), v_urgent);
    return jsonb_build_object('updated_request', true);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Reminders before class: none when switched off; 0 and empty mean none.
create or replace function private.checkin_days_for(p_mw uuid)
returns int[] language sql stable security definer set search_path = ''
as $$
  select case when not private.setting_bool(p_mw, 'remind_instructor_after_assign') then '{}'::int[]
    else array(select distinct x::int from jsonb_array_elements_text(private.get_setting(p_mw, 'checkin_days')) x
                where x::int > 0 order by 1) end;
$$;

create or replace function private.last_checkin_day(p_mw uuid)
returns int language sql stable security definer set search_path = ''
as $$ select min(d) from unnest(private.checkin_days_for(p_mw)) d; $$;

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
     and mw.first_class_at > p_now and mw.first_class_at - make_interval(days => private.setting_int(mw.id, 'owner_checkin_days')) <= p_now
     -- Off when the team is not reminded after an assignment, or the number is 0.
     and private.setting_bool(mw.id, 'remind_team_after_assign') and private.setting_int(mw.id, 'owner_checkin_days') > 0;
  if cardinality(v_due) = 0 then return 0; end if;

  for o in select distinct x from public.module_week mw, unnest(private.owners_or_leads(mw.module_id)) x where mw.id = any (v_due) loop
    v_text := 'Coming up in the next ' || v_days || ' days — please check these module weeks:';
    for w in select mw.* from public.module_week mw
              where mw.id = any (v_due) and o = any (private.owners_or_leads(mw.module_id))
              order by mw.first_class_at loop
      insert into public.request (module_week_id, team_member_id, kind, status, sent_at, is_test)
      values (w.id, o, 'OwnerCheckIn', 'Sent', p_now,
              private.is_test_domain(p_domain))
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
      'T11:' || o || ':' || md5(array_to_string(array(select x::text from unnest(v_due) x order by 1), ',')), p_now, true);
    n := n + 1;
  end loop;
  update public.module_week set owner_checkin_sent_at = p_now where id = any (v_due);
  return n;
end;
$$;

create or replace function private.step_checklist(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  b record;
  n int := 0;
  v_missing text;
  v_nudge int;
  v_due int;
  v_id uuid;
begin
  for b in select bk.*, mw.first_class_at, mw.module_id from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and mw.first_class_at > p_now loop
    select string_agg(distinct ci.label, ', ') into v_missing
      from public.checklist_item ci join public.class_session c on c.id = ci.class_id
     where c.module_week_id = b.module_week_id and c.status = 'Planned' and not ci.done;
    v_nudge := private.setting_int(b.module_week_id, 'checklist_nudge_days');
    v_due := private.setting_int(b.module_week_id, 'checklist_due_days');
    if v_missing is null then
      perform private.resolve_attention('checklist:' || b.module_week_id, 'Checklist complete');
      continue;
    end if;
    -- Class task reminders are switched off with the team reminders after an assignment.
    continue when not private.setting_bool(b.module_week_id, 'remind_team_after_assign');
    if b.first_class_at - make_interval(days => v_due) <= p_now then
      v_id := private.raise_attention(p_domain, 'ChecklistOverdue', 'Urgent',
        'Checklist overdue: ' || private.mw_label(b.module_week_id), 'Not done: ' || v_missing,
        'checklist:' || b.module_week_id, private.ops_for_week(b.module_week_id), p_now, private.mw_refs(b.module_week_id), false, 'T9');
      if (select a.escalated_at from public.attention_item a where a.id = v_id) is null then
        perform private.queue_team_message('T13', p_domain, 'alert', null,
          private.uniq(private.ops_for_week(b.module_week_id) || private.domain_role_ids(p_domain, 'Lead')),
          'Escalation: checklist not done — ' || private.mw_label(b.module_week_id),
          '⚠️ Escalation: checklist must be complete ' || v_due || ' days before ' || private.mw_label(b.module_week_id) || '. Not done: ' || v_missing,
          'T13:checklist:' || b.module_week_id, p_now, false, v_id, b.module_week_id);
        update public.attention_item set escalated_at = p_now where id = v_id;
      end if;
      n := n + 1;
    elsif v_nudge > 0 and b.confirmed_at + make_interval(days => v_nudge) <= p_now then
      perform private.raise_attention(p_domain, 'ChecklistOverdue', 'Normal',
        'Checklist pending: ' || private.mw_label(b.module_week_id), 'Not done: ' || v_missing,
        'checklist:' || b.module_week_id, private.ops_for_week(b.module_week_id), p_now, private.mw_refs(b.module_week_id), false, 'T9');
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

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
    if (a.severity = 'Urgent' and v_r2u > 0 and a.last_reminder_at + make_interval(hours => v_r2u) <= p_now)
       or (a.severity = 'Normal' and v_r2n > 0 and not v_has_r2 and a.r1_at + make_interval(hours => v_r2n) <= p_now) then
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
       and (case when a.severity = 'Urgent' then v_esu else v_esn end) > 0
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

create or replace function private.send_digests(p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  t record;
  v_date date := (p_now at time zone 'Asia/Kolkata')::date;
  v_time time := '10:00';
  v_text text;
  v_items record;
  v_count int;
  n int := 0;
  v_test text;
  v_updates text;
begin
  if (p_now at time zone 'Asia/Kolkata')::time < v_time
     or (select s.last_digest_date from public.system_state s where s.id = 1) >= v_date then
    return 0;
  end if;
  select string_agg(d.name, ', ') into v_test from public.domain d where private.is_test_domain(d.id);
  for t in select * from public.team_member where active and receives_digest loop
    select count(*) into v_count from public.attention_item a
     where a.status <> 'Done' and (a.assigned_to = t.id or (a.assigned_to is null and t.id = any (a.recipients)))
       and (a.domain_id is null or private.setting_bool(a.domain_id, 'daily_summary'));
    -- T3 for the owner's modules: declines and no-replies of the last day (immediate only under 10 days).
    select string_agg('• ' || h.action || ' — ' || private.mw_label(h.module_week_id), E'
' order by h.id) into v_updates
      from public.history_event h join public.module_week w on w.id = h.module_week_id
     where (h.action like '% said no' or h.action like 'No reply from %')
       and coalesce(h.sim_at, h.at) > p_now - interval '1 day' and coalesce(h.sim_at, h.at) <= p_now
       and t.id = any (private.owners_or_leads(w.module_id)) and private.setting_bool(w.domain_id, 'daily_summary');
    continue when v_count = 0 and v_updates is null;
    v_text := 'Good morning ' || private.first_name(t.name) || ' — you have ' || v_count || ' open item' || case when v_count = 1 then '' else 's' end || '.';
    if v_updates is not null then
      v_text := v_text || E'

Outreach updates (asking the next instructor automatically):
' || v_updates;
    end if;
    if v_test is not null then v_text := v_text || E'\nℹ️ In TEST MODE: ' || v_test; end if;
    if not (select s.outreach_enabled from public.system_state s where s.id = 1) then
      v_text := v_text || E'\n⛔ The kill switch is ON — no instructor messages are being sent.';
    end if;
    for v_items in select a.severity, string_agg('• ' || a.title || ' (open ' ||
                      greatest(1, round(extract(epoch from (p_now - a.opened_at)) / 3600))::int || 'h)', E'\n' order by a.opened_at) as lines
                     from public.attention_item a
                    where a.status <> 'Done' and (a.assigned_to = t.id or (a.assigned_to is null and t.id = any (a.recipients)))
                      and (a.domain_id is null or private.setting_bool(a.domain_id, 'daily_summary'))
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

create or replace function private.queue_team_message(
  p_template text,
  p_domain uuid,
  p_target text,
  p_person uuid,
  p_mentions uuid[],
  p_subject text,
  p_text text,
  p_key text,
  p_now timestamptz,
  p_quiet boolean default false,
  p_attention uuid default null,
  p_mw uuid default null,
  p_help uuid default null
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  d public.domain;
  t public.team_member;
  v_test boolean;
  v_prefix text := '';
  v_send timestamptz := p_now;
  v_channel text;
  v_count int := 0;
  v_n int;
  v_ch text;
  v_mentions text[] := private.team_discord_ids(p_mentions);
  v_app text := (select c.app_base_url from public.app_config c where c.id = 1);
  v_text text;
begin
  select * into d from public.domain where id = p_domain;
  v_test := private.is_test_domain(d.id);
  if v_test then v_prefix := '[TEST] '; end if;
  if p_quiet then
    v_send := private.team_send_time(p_domain, p_now);
  end if;
  v_text := p_text || case when v_app is not null then E'\nOpen the app: ' || v_app else '' end;

  if p_target in ('alert', 'admin') then
    v_channel := case when p_target = 'admin' then (select c.admin_discord_channel_id from public.app_config c where c.id = 1)
                      when v_test then d.test_discord_channel_id else d.alert_discord_channel_id end;
    if v_channel is null and p_target = 'alert' then
      v_channel := (select c.admin_discord_channel_id from public.app_config c where c.id = 1);
    end if;
    insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before,
      module_week_id, help_request_id, attention_item_id, recipient_label, discord_channel_id, mention_user_ids,
      subject, body_text, is_test)
    values (p_domain, case when p_target = 'admin' then 'Admin' else 'Team' end, p_template, 'Discord', p_key || ':Discord',
      case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, p_mw, p_help, p_attention,
      case when p_target = 'admin' then 'Admin channel' else coalesce(d.name, '') || ' alert channel' end,
      v_channel, v_mentions, v_prefix || p_subject,
      v_prefix || case when cardinality(v_mentions) > 0
                       then (select string_agg('<@' || m || '>', ' ') from unnest(v_mentions) m) || ' ' else '' end || v_text,
      v_test)
    on conflict (unique_key) where unique_key is not null do nothing;
    get diagnostics v_count = row_count;
  else
    select * into t from public.team_member where id = p_person;
    if t.id is null or not t.active then
      return 0;
    end if;
    foreach v_ch in array array['Discord', 'Email'] loop
      continue when v_ch = 'Discord' and (t.digest_channel = 'Email' or t.discord_user_id is null);
      -- Email when the person chose it, or when the domain sends team reminders by Discord and email.
      continue when v_ch = 'Email' and t.digest_channel = 'Discord'
                    ;
      insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before,
        team_member_id, module_week_id, help_request_id, attention_item_id, recipient_label, to_address,
        discord_dm_user_id, subject, body_text, is_test)
      values (p_domain, 'Team', p_template, v_ch, p_key || ':' || t.id || ':' || v_ch,
        case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, t.id, p_mw, p_help, p_attention, t.name,
        case when v_ch = 'Email' then t.email end,
        case when v_ch = 'Discord' then t.discord_user_id end,
        v_prefix || p_subject, v_prefix || v_text, v_test)
      on conflict (unique_key) where unique_key is not null do nothing;
      get diagnostics v_n = row_count;
      v_count := v_count + v_n;
    end loop;
  end if;
  return v_count;
end;
$$;

create or replace function private.queue_instructor_message(
  p_template text,
  p_instructor uuid,
  p_mw uuid,
  p_request uuid,
  p_now timestamptz,
  p_buttons jsonb default '[]',
  p_extra jsonb default '{}',
  p_urgent boolean default false,
  p_key_suffix text default '',
  p_help_request uuid default null,
  p_only_channel text default null
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  d public.domain;
  v_domain uuid;
  v_channels text;
  v_r jsonb;
  v_tv int;
  v_send timestamptz;
  v_test boolean;
  v_prefix text := '';
  v_count int := 0;
  v_n int;
  v_ch text;
  v_key text;
  v_text text;
  v_html text;
  v_btn_html text;
begin
  select * into i from public.instructor where id = p_instructor;
  if p_mw is not null then
    select w.domain_id, w.time_version into v_domain, v_tv from public.module_week w where w.id = p_mw;
  end if;
  if p_request is not null then
    select r.time_version into v_tv from public.request r where r.id = p_request;
  end if;
  select * into d from public.domain where id = v_domain;
  v_test := private.is_test_domain(d.id);
  v_channels := 'Both';
  v_r := private.render_instructor(p_template, p_mw, p_instructor, p_extra);
  if v_test then
    v_prefix := '[TEST → would go to ' || i.full_name || '] ';
  end if;
  v_send := private.instructor_send_time(v_domain, p_now, p_urgent);

  select coalesce(string_agg(format('<a href="%s" style="display:inline-block;margin:4px 8px 4px 0;padding:10px 16px;background:#1f6feb;color:#fff;border-radius:6px;text-decoration:none;font-weight:600">%s</a>',
                                    private.html_escape(b ->> 'url'), private.html_escape(b ->> 'label')), ''), '')
    into v_btn_html from jsonb_array_elements(p_buttons) b;

  foreach v_ch in array array['Discord', 'Email'] loop
    continue when p_only_channel is not null and v_ch <> p_only_channel;
    continue when v_ch = 'Discord' and v_channels = 'EmailOnly';
    continue when v_ch = 'Email' and v_channels = 'DiscordOnly';
    continue when v_ch = 'Discord' and not v_test and i.discord_channel_id is null;
    continue when v_ch = 'Email' and not v_test and coalesce(i.primary_email, '') = '';
    v_key := p_template || ':' || coalesce(p_request::text, coalesce(p_mw::text, '-') || ':' || p_instructor::text)
             || ':' || coalesce(v_tv, 0) || ':' || v_ch || coalesce(nullif(':' || p_key_suffix, ':'), '');
    if v_ch = 'Discord' then
      v_text := v_prefix || 'Hi ' ||
                case when i.discord_user_id is not null and (not v_test or i.is_test) then '<@' || i.discord_user_id || '>'
                     else (v_r ->> 'first_name') end
                || ' 👋 ' || (v_r ->> 'body');
      v_html := null;
    else
      v_text := v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')
                || case when jsonb_array_length(p_buttons) > 0 then E'\n\n' ||
                     (select string_agg((b ->> 'label') || ': ' || (b ->> 'url'), E'\n') from jsonb_array_elements(p_buttons) b) else '' end
                || E'\n\n— SME Scheduling';
      v_html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#1f2328">'
                || replace(private.html_escape(v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')), E'\n', '<br>')
                || case when v_btn_html <> '' then '<p style="margin-top:16px">' || v_btn_html || '</p>' else '' end
                || '<p style="color:#59636e;font-size:13px">— SME Scheduling</p></div>';
    end if;
    insert into public.message (
      domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id, module_week_id,
      request_id, help_request_id, recipient_label, to_address, discord_channel_id, mention_user_ids, subject,
      body_text, body_html, buttons, is_test)
    values (
      v_domain, 'Instructor', p_template, v_ch, v_key,
      case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, p_instructor, p_mw,
      p_request, p_help_request, i.full_name,
      case when v_ch = 'Email' then case when v_test then d.test_email else i.primary_email end end,
      case when v_ch = 'Discord' then case when v_test then d.test_discord_channel_id else i.discord_channel_id end end,
      case when v_ch = 'Discord' and i.discord_user_id is not null and (not v_test or i.is_test) then array[i.discord_user_id] else '{}' end,
      v_prefix || (v_r ->> 'subject'), v_text, v_html, p_buttons, v_test)
    on conflict (unique_key) where unique_key is not null do nothing;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
  end loop;
  return v_count;
end;
$$;

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
          case when private.days_until(r.module_week_id, p_now) < private.setting_int(r.module_week_id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'New time not confirmed: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'No reply to the time-change message. The booking is kept; please check with them.',
          'timechange:' || r.module_week_id, private.recipients_for_week(r.module_week_id, true), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)), true);
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now and (private.window_hours(r.module_week_id, p_now)).reminder_h is not null then
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
    v_send := private.instructor_send_time(p_domain, p_now, v_due <= v_urgent_band);
    v_deadline := least(private.instructor_send_time(p_domain, v_send + make_interval(hours => 2 * v_rem), v_due <= v_urgent_band), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, check_in_days, status, sent_at,
      reminder_at, deadline_at, is_test, time_version)
    values (b.module_week_id, b.instructor_id, b.id, 'CheckIn', v_due, 'Sent', v_send,
      least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_rem), v_due <= v_urgent_band), v_deadline),
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

-- Reset: replace the Sandbox people even after someone saved them on the Team page.
create or replace function public.reset_sandbox_data(p_confirm text, p_test_email text default null,
  p_test_discord_user_id text default null, p_test_channel_id text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_env text := (select environment from public.app_config where id = 1); v jsonb;
begin
  perform private.require_team();
  if v_env = 'Production' then
    raise exception 'Sandbox data can never be reset in Production.' using errcode = '42501';
  end if;
  if p_confirm is distinct from 'RESET' then
    raise exception 'Type RESET to confirm.' using errcode = '22023';
  end if;
  perform private.log_event('System', 'Sandbox data reset started');
  -- Run any checks still waiting in this transaction (instructor order) before clearing tables.
  set constraints all immediate;
  -- Keep holidays and settings that apply to every domain (truncating domains would remove them).
  create temp table reset_keep_holiday on commit drop as select date, name from public.holiday where domain_id is null;
  create temp table reset_keep_setting on commit drop as select key, value from public.setting where scope = 'Global';
  truncate table public.message, public.request, public.response_link, public.booking_slot, public.booking,
    public.checklist_item, public.help_request, public.reminder, public.attention_item, public.manual_queue_item,
    public.class_session, public.module_week, public.setting, public.module_operations, public.module_ranking,
    public.module_owner, public.module_resource, public.class_pattern_item, public.module, public.cohort,
    public.class_type, public.message_template, public.domain_team, public.instructor_unavailability,
    public.instructor_email, public.instructor, public.action_queue, public.app_error, public.domain,
    public.discord_cursor
    restart identity cascade;
  -- Real people keep their sign in and profile; only the made up Sandbox people are replaced.
  -- The made up Sandbox people are found by their Sandbox email too: saving one on the Team page
  -- clears "needs real details", and the reset must still replace them.
  delete from public.team_member
   where is_placeholder or split_part(lower(email), '@', 1) in ('sandbox.owner', 'sandbox.operations', 'sandbox.escalation');
  insert into public.holiday (date, name) select date, name from reset_keep_holiday on conflict do nothing;
  insert into public.setting (scope, key, value) select 'Global', key, value from reset_keep_setting;
  update public.system_state set outreach_enabled = true where id = 1;
  v := private.load_sandbox_seed(p_test_email, p_test_discord_user_id, p_test_channel_id);
  set constraints all deferred;
  return v;
end;
$$;
revoke execute on function public.reset_sandbox_data(text, text, text, text) from anon, public;
grant execute on function public.reset_sandbox_data(text, text, text, text) to authenticated, service_role;
