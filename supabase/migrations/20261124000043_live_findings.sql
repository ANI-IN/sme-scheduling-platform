-- Release 3: findings from the live run on Production.
--
-- 1. No dashes in the words the database writes: task titles ("Need help from QA Instructor A: QA Databases ..."),
--    alerts, Activity history, errors and the answer pages. Every string literal in the latest definition of each
--    function was checked; scripts/src/scan-text.ts now checks them too, so a dash cannot come back.
-- 2. A help request closes when its class week is cancelled, or when the instructor who asked is released (Can't make
--    it, Release, a declined new time): status Closed with a note, its task done, both in Activity history.
-- 3. Messages to instructors about a class week that have not gone out (Scheduled or Pending) are withdrawn when the
--    class week is cancelled ("Not sent: the class week was cancelled"), and the released instructor's when they no
--    longer teach it. The class cancelled and request withdrawn notices still go, and team messages are not touched.
-- 4. The instructor answer pages: the first line no longer repeats the heading, every box and choice has its own
--    label, and the Propose another time page shows each date as "Mon, Dec 14, 2026" under its date box.
-- Rollback: supabase/rollback/20261123000029_live_findings.sql.

-- Live finding 2: closes the open help requests for a class week (all of them, or only those one instructor asked),
-- with a note, their tasks done and both in Activity history.
create or replace function private.close_week_help(p_mw uuid, p_instructor uuid, p_note text, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare h record; a record; n int := 0;
begin
  for h in
    with o as (
      select hr.id, hr.status from public.help_request hr
       where hr.module_week_id = p_mw and hr.status in ('Open', 'InProgress', 'WaitingOnInstructor')
         and (p_instructor is null or hr.requester_instructor_id = p_instructor)
       for update)
    update public.help_request hr set status = 'Closed', resolved_at = p_now, resolution_note = p_note
      from o where hr.id = o.id
    returning hr.id, o.status as was, hr.domain_id, hr.requester_instructor_id, hr.is_test,
              coalesce((select i.full_name from public.instructor i where i.id = hr.requester_instructor_id),
                       (select t.name from public.team_member t where t.id = hr.requester_team_member_id), 'the team') as who
  loop
    for a in update public.attention_item set status = 'Done', done_at = now(), done_note = p_note
              where (dedupe_key = 'help:' || h.id or help_request_id = h.id) and status <> 'Done'
             returning id, title, domain_id, module_week_id loop
      perform private.log_event('Reminders', 'Resolved automatically: ' || a.title, 'attention_item', a.id,
        null, null, p_note, a.domain_id, null, a.module_week_id);
    end loop;
    perform private.log_event('Help requests', 'Help request from ' || h.who || ' closed', 'help_request', h.id,
      jsonb_build_object('status', h.was), jsonb_build_object('status', 'Closed'), p_note,
      h.domain_id, null, p_mw, null, h.requester_instructor_id, null, h.is_test);
    n := n + 1;
  end loop;
  perform private.clear_help_risk(p_mw);
  return n;
end;
$$;
revoke execute on function private.close_week_help(uuid, uuid, text, timestamptz) from public, anon, authenticated;

-- Live finding 3: withdraws the messages to instructors about a class week that have not gone out yet (all
-- instructors, or one). Notices that end someone's part in the class week still go: request closed (M3), released
-- (M10, M16), class cancelled (M11), request withdrawn (M12). A contact check (M15) is not about the class week.
create or replace function private.withdraw_week_messages(p_mw uuid, p_instructor uuid, p_reason text)
returns int language plpgsql security definer set search_path = ''
as $$
declare n int; w public.module_week;
begin
  update public.message m set status = 'Cancelled', last_error = p_reason
   where m.module_week_id = p_mw and m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound'
     and m.audience = 'Instructor' and (p_instructor is null or m.instructor_id = p_instructor)
     and m.template_id not in ('M3', 'M10', 'M11', 'M12', 'M15', 'M16');
  get diagnostics n = row_count;
  if n > 0 then
    select * into w from public.module_week where id = p_mw;
    perform private.log_event('Messages', n || ' waiting message' || case when n = 1 then '' else 's' end || ' not sent',
      'module_week', p_mw, null, jsonb_build_object('withdrawn', n), p_reason,
      w.domain_id, w.module_id, p_mw, null, p_instructor, null,
      coalesce((select i.is_test from public.instructor i where i.id = p_instructor), false));
  end if;
  return n;
end;
$$;
revoke execute on function private.withdraw_week_messages(uuid, uuid, text) from public, anon, authenticated;

-- private.touch_row: finding 1 (was 20261110000001_foundation.sql).
create or replace function private.touch_row()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.version is distinct from old.version then
    raise exception 'This changed. Someone else saved this record after you opened it. Please reload.'
      using errcode = '40001';
  end if;
  new.version := old.version + 1;
  new.updated_at := now();
  new.updated_by := coalesce(private.current_team_member_id(), new.updated_by);
  return new;
end;
$$;

-- private.help_form_fields: finding 4b (was 20261110000004_pages.sql).
create or replace function private.help_form_fields()
returns text language sql immutable set search_path = ''
as $$
  select '<fieldset><legend>What do you need help with?</legend>'
    || (select string_agg('<div style="margin:6px 0"><input type="checkbox" id="cat_' || c || '" name="cat_' || c || '" value="1"> <label for="cat_' || c || '" style="display:inline">' || private.html_escape(private.help_category_label(c)) || '</label></div>', '' order by o)
          from unnest(array['materials', 'zoom', 'platform', 'assignment', 'students', 'schedule', 'payment', 'other']) with ordinality as x(c, o))
    || '<p class="muted">To cancel, use the "Can''t make it" button instead.</p></fieldset>'
    || '<label for="details" style="font-weight:600">Details (optional)</label><textarea id="details" name="details" maxlength="1000"></textarea>'
    || '<fieldset><legend>How soon do you need this?</legend>'
    || '<div style="margin:6px 0"><input type="radio" id="urgency_NoRush" name="urgency" value="NoRush" checked> <label for="urgency_NoRush" style="display:inline">Before the class, no rush</label></div>'
    || '<div style="margin:6px 0"><input type="radio" id="urgency_Within24h" name="urgency" value="Within24h"> <label for="urgency_Within24h" style="display:inline">Within 24 hours</label></div>'
    || '<div style="margin:6px 0"><input type="radio" id="urgency_Urgent" name="urgency" value="Urgent"> <label for="urgency_Urgent" style="display:inline">Urgent</label></div></fieldset>'
    || '<fieldset><legend>How should we reply?</legend>'
    || '<div style="margin:6px 0"><input type="radio" id="reply_Discord" name="reply_channel" value="Discord"> <label for="reply_Discord" style="display:inline">Discord channel</label></div>'
    || '<div style="margin:6px 0"><input type="radio" id="reply_Email" name="reply_channel" value="Email"> <label for="reply_Email" style="display:inline">Email</label></div>'
    || '<div style="margin:6px 0"><input type="radio" id="reply_Either" name="reply_channel" value="Either" checked> <label for="reply_Either" style="display:inline">Either</label></div></fieldset>';
$$;

-- public.update_class_details: finding 1 (was 20261110000005_actions.sql).
create or replace function public.update_class_details(p_class_id uuid, p_title text, p_class_type text, p_notes text,
  p_problem_flag boolean, p_expected_version int default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare c public.class_session; w public.module_week;
begin
  perform private.require_team();
  select * into c from public.class_session where id = p_class_id for update;
  if p_expected_version is not null and c.version <> p_expected_version then
    raise exception 'This changed. Someone else saved this class after you opened it. Please reload.' using errcode = '40001';
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

-- private.step_checklist: finding 1 (was 20261112000001_r2_settings_reminders.sql).
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
          'Escalation: checklist not done for ' || private.mw_label(b.module_week_id),
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

-- private.send_digests: finding 1 (was 20261112000001_r2_settings_reminders.sql).
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
    select string_agg('• ' || h.action || ': ' || private.mw_label(h.module_week_id), E'
' order by h.id) into v_updates
      from public.history_event h join public.module_week w on w.id = h.module_week_id
     where (h.action like '% said no' or h.action like 'No reply from %')
       and coalesce(h.sim_at, h.at) > p_now - interval '1 day' and coalesce(h.sim_at, h.at) <= p_now
       and t.id = any (private.owners_or_leads(w.module_id)) and private.setting_bool(w.domain_id, 'daily_summary');
    continue when v_count = 0 and v_updates is null;
    v_text := 'Good morning ' || private.first_name(t.name) || ', you have ' || v_count || ' open item' || case when v_count = 1 then '' else 's' end || '.';
    if v_updates is not null then
      v_text := v_text || E'

Outreach updates (asking the next instructor automatically):
' || v_updates;
    end if;
    if v_test is not null then v_text := v_text || E'\nℹ️ In TEST MODE: ' || v_test; end if;
    if not (select s.outreach_enabled from public.system_state s where s.id = 1) then
      v_text := v_text || E'\n⛔ The kill switch is ON, so no instructor messages are being sent.';
    end if;
    for v_items in select a.severity, string_agg('• ' || a.title || ' (open ' ||
                      greatest(1, round(extract(epoch from (p_now - a.opened_at)) / 3600))::int || 'h)', E'\n' order by a.opened_at) as lines
                     from public.attention_item a
                    where a.status <> 'Done' and (a.assigned_to = t.id or (a.assigned_to is null and t.id = any (a.recipients)))
                      and (a.domain_id is null or private.setting_bool(a.domain_id, 'daily_summary'))
                    group by a.severity order by a.severity desc loop
      v_text := v_text || E'\n\n' || case when v_items.severity = 'Urgent' then '🚨 Urgent' else 'Normal' end || E'\n' || v_items.lines;
    end loop;
    perform private.queue_team_message('T12', null, 'person', t.id, '{}', 'Your daily digest: ' || v_count || ' open',
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

-- private.step_requests: finding 1 (was 20261112000002_r2_regions_time_zones.sql).
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
        perform private.log_event('Messages', 'No reply from ' || v_name || ', moving on', 'request', r.id, null, null,
          null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
        if private.band(r.module_week_id, p_now) <> 'Long' then
          perform private.queue_team_message('T3', p_domain, 'alert', null, private.owners_or_leads(r.module_id),
            'No reply: ' || private.mw_label(r.module_week_id),
            'No reply from ' || v_name || ' for ' || private.mw_label(r.module_week_id) || '. We''re asking the next instructor.',
            'T3:' || r.id, p_now, false, null, r.module_week_id);
        end if;
        perform private.ask_next(r.module_week_id, p_now);
      else
        update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
        perform private.raise_attention(p_domain, 'TimeChangeNotConfirmed',
          case when private.days_until(r.module_week_id, p_now) < private.setting_int(r.module_week_id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'New time not confirmed by ' || v_name || ': ' || private.mw_label(r.module_week_id),
          'No reply to the time-change message. The booking is kept; please check with them.',
          'timechange:' || r.module_week_id, private.recipients_for_week(r.module_week_id, true), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)), true);
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now and (private.window_hours(r.module_week_id, p_now)).reminder_h is not null then
      update public.request set status = 'Reminded', reminded_at = p_now where id = r.id;
      if r.kind = 'Outreach' then
        perform private.queue_instructor_message('M2', r.instructor_id, r.module_week_id, r.id, p_now,
          private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local_both(r.deadline_at, private.week_region(r.module_week_id))), v_urgent);
      else
        perform private.queue_instructor_message('M5', r.instructor_id, r.module_week_id, r.id, p_now,
          private.buttons(r.id, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_local_both(r.deadline_at, private.week_region(r.module_week_id))),
          v_urgent, 'reminder');
      end if;
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

-- public.help_reply: finding 1 (was 20261112000005_r2_review_fixes.sql).
create or replace function public.help_reply(p_help_id uuid, p_text text, p_resolves boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  h public.help_request;
  v_now timestamptz;
  v_req uuid;
  v_n int;
  v_from text := coalesce((select t.name from public.team_member t where t.id = private.current_team_member_id()), 'SME Scheduling');
begin
  perform private.require_team();
  if coalesce(trim(p_text), '') = '' then raise exception 'Write a reply first.'; end if;
  select * into h from public.help_request where id = p_help_id for update;
  v_now := private.mw_now(h.module_week_id);
  if h.requester_instructor_id is not null then
    select r.id into v_req from public.request r join public.booking b on b.request_id = r.id
     where b.module_week_id = h.module_week_id and b.status = 'Active' and b.instructor_id = h.requester_instructor_id;
    v_n := private.queue_instructor_message('M14', h.requester_instructor_id, h.module_week_id, null, v_now,
      case when v_req is not null then private.buttons(v_req, array['NeedMoreHelp']) else '[]'::jsonb end,
      jsonb_build_object('text', p_text, 'from', v_from), false, 'reply:' || h.id || ':' || gen_random_uuid(),
      h.id, null);
    if v_n = 0 then
      raise exception 'The reply could not be sent: % has no email address or Discord. Add one on Setup, Instructors.',
        (select full_name from public.instructor where id = h.requester_instructor_id) using errcode = '22023';
    end if;
  elsif h.requester_team_member_id is not null then
    perform private.queue_team_message('M14', h.domain_id, 'person', h.requester_team_member_id, '{}',
      'Reply to your help request', p_text || E'\n\nFrom ' || v_from,
      'M14:' || h.id || ':' || gen_random_uuid(), v_now, false, null, h.module_week_id, h.id);
  end if;
  update public.help_request
     set status = case when p_resolves then 'Resolved' else 'WaitingOnInstructor' end,
         first_response_at = coalesce(first_response_at, v_now),
         resolved_at = case when p_resolves then v_now end,
         assigned_to = coalesce(assigned_to, private.current_team_member_id())
   where id = h.id;
  if p_resolves then
    perform private.resolve_attention('help:' || h.id, 'Resolved with a reply');
    perform private.clear_help_risk(h.module_week_id);
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

-- private.confirm_booking: finding 1 (was 20261112000005_r2_review_fixes.sql).
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
  v_test := private.is_test_domain(w.domain_id);
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
      return jsonb_build_object('ok', false, 'reason', 'stale', 'message', 'The class times changed. Please use the latest message.');
    end if;
  end if;
  -- SCH-1: one instructor teaches the whole week, so its classes must not overlap each other.
  if w.same_instructor and private.week_self_overlap(p_mw) is not null then
    perform private.raise_attention(w.domain_id, 'Other', 'Urgent', 'Classes overlap: ' || private.mw_label(p_mw),
      'Two classes of this class week overlap: ' || private.week_self_overlap(p_mw) || '. Change one of the times so one instructor can teach both.',
      'selfoverlap:' || p_mw, private.ops_for_week(p_mw), p_now, private.mw_refs(p_mw), false);
    return jsonb_build_object('ok', false, 'reason', 'week_overlap',
      'message', 'Thank you! The times of this class week are being corrected, so we cannot confirm it right now. The team will be in touch.');
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
      v_clash := private.week_clash(p_instructor, p_mw);
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
  -- OUT-3: pausing is about asking; a confirmed week has nobody left to ask, so reminders and time changes go on.
  update public.module_week set status = 'Confirmed', at_risk = false, at_risk_reason = null, paused = false where id = p_mw;
  if p_via = 'Instructor' then
    update public.instructor set last_response_at = p_now where id = p_instructor;
  end if;
  perform private.resolve_attention('exhausted:' || p_mw, 'Instructor confirmed');
  perform private.resolve_attention('urgentfill:' || p_mw, 'Instructor confirmed');
  perform private.resolve_attention('atrisk:' || p_mw, 'Replacement confirmed');
  perform private.resolve_attention('readiness:' || p_mw, 'Instructor confirmed');

  -- Class checklist (SCH-8)
  insert into public.checklist_item (class_id, booking_id, label, due_at)
  select c.id, v_booking, lbl, w.first_class_at - make_interval(days => private.setting_int(w.id, 'checklist_due_days'))
    from public.class_session c
    cross join lateral jsonb_array_elements_text(private.get_setting(w.id, 'checklist_items')) lbl
   where c.module_week_id = p_mw and c.status = 'Planned'
  on conflict (class_id, label) do update set booking_id = excluded.booking_id;

  perform private.queue_instructor_message('M4', p_instructor, p_mw, v_req, p_now,
    private.buttons(v_req, array['NeedHelp', 'CantMakeItAnymore']));
  perform private.queue_team_message('T2', w.domain_id,
    case when private.is_test_domain(w.domain_id)
              or not exists (select 1 from public.instructor_channel ic where ic.instructor_id = p_instructor and ic.domain_id = w.domain_id)
                 and (select i.discord_channel_id from public.instructor i where i.id = p_instructor) is null
         then 'alert' else 'people' end,
    null, array(select distinct x from unnest(private.owners_or_leads(w.module_id) || private.ops_for_week(p_mw)) x),
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

-- private.step_reminders: finding 1 (was 20261112000005_r2_review_fixes.sql).
create or replace function private.step_reminders(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  a record;
  n int := 0;
  v_targets uuid[];
  v_weekly boolean;
  v_r2n int;
  v_r2u int;
  v_esn int;
  v_esu int;
  v_scope uuid;
  v_has_r2 boolean;
  v_escal uuid[];
begin
  for a in select * from public.attention_item
            where domain_id = p_domain and status <> 'Done' and (ack_until is null or ack_until <= p_now)
              -- OUT-6: nothing is reminded about a class week that is over or cancelled.
              and not exists (select 1 from public.module_week mw where mw.id = attention_item.module_week_id
                                and (mw.status in ('Cancelled', 'Completed') or mw.last_class_end_at <= p_now))
            for update skip locked loop
    -- OUT-4: the numbers of the task's own class week (a cohort can change them), else the domain's.
    v_scope := coalesce(a.module_week_id, a.module_id, p_domain);
    v_r2n := private.setting_int(v_scope, 'reminder_r2_normal_h');
    v_r2u := private.setting_int(v_scope, 'reminder_r2_urgent_h');
    v_esn := private.setting_int(v_scope, 'reminder_escalate_normal_h');
    v_esu := private.setting_int(v_scope, 'reminder_escalate_urgent_h');
    v_targets := case when a.assigned_to is not null then array[a.assigned_to] else a.recipients end;
    v_weekly := a.type in ('ThinBench', 'ScheduleLow', 'UnverifiedInRanking');
    if a.r1_at is null then
      continue;                                   -- normal items get R1 in the daily digest
    end if;
    if v_weekly then
      if v_r2n > 0 and a.last_reminder_at + interval '7 days' <= p_now then
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
        '⚠️ Escalation: not acknowledged since ' || private.fmt_ist(a.r1_at) || ': ' || a.title || coalesce(E'\n' || a.detail, ''),
        'T13:' || a.id, p_now, a.severity = 'Normal', a.id, a.module_week_id);
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

-- private.create_help_request: finding 1 (was 20261112000005_r2_review_fixes.sql).
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
  v_reopen boolean;
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
    v_reopen := h.status = 'WaitingOnInstructor';
    update public.help_request
       set categories = (select array_agg(distinct x) from unnest(categories || v_cats) x),
           details = left(concat_ws(E'\n---\n', nullif(details, ''), nullif(p_details, '')), 1000),
           urgency = case when p_urgency = 'Urgent' or urgency = 'Urgent' then 'Urgent'
                          when p_urgency = 'Within24h' or urgency = 'Within24h' then 'Within24h' else 'NoRush' end,
           status = 'Open'
     where id = h.id returning * into h;
    -- The stricter urgency wins: a new reply target and severity, worked out like a new request.
    v_days := private.days_until(p_mw, p_now);
    v_h := case h.urgency when 'Urgent' then private.setting_int(w.id, 'help_target_urgent_h')
                          when 'Within24h' then private.setting_int(w.id, 'help_target_24h_h')
                          else private.setting_int(w.id, 'help_target_norush_h') end;
    if v_days < 2 then v_h := least(v_h, private.setting_int(w.id, 'help_target_urgent_h'));
    elsif v_days <= 7 then v_h := least(v_h, private.setting_int(w.id, 'help_target_24h_h')); end if;
    v_sev := case when h.urgency = 'Urgent' or v_days < 2 then 'Urgent' else h.severity end;
    update public.help_request
       set severity = v_sev,
           response_target_at = case when v_reopen then p_now + make_interval(hours => v_h)
                                     else least(response_target_at, p_now + make_interval(hours => v_h)) end,
           first_response_at = case when v_reopen then null else first_response_at end,
           half_reminder_at = case when v_reopen then null else half_reminder_at end,
           escalated_at = case when v_reopen then null else escalated_at end
     where id = h.id returning * into h;
    update public.attention_item set status = 'Open', ack_until = null
     where dedupe_key = 'help:' || h.id and status <> 'Done';
    perform private.raise_attention(w.domain_id, 'HelpRequest', v_sev,
      coalesce((select a.title from public.attention_item a where a.dedupe_key = 'help:' || h.id and a.status <> 'Done'),
               'Need help: ' || v_name || ' · ' || private.mw_label(p_mw)),
      null, 'help:' || h.id, h.routed_to, p_now, private.mw_refs(p_mw, jsonb_build_object('help_request_id', h.id)), false, 'T7');
    if v_reopen then
      perform private.queue_team_message('T7', w.domain_id, 'people', null,
        case when h.assigned_to is not null then array[h.assigned_to] else h.routed_to end,
        'Follow up on a help request: ' || private.mw_label(p_mw),
        v_name || ' needs more help with ' || private.mw_label(p_mw) || '.' || coalesce(E'
' || nullif(p_details, ''), ''),
        'HELPFOLLOW:' || h.id || ':' || gen_random_uuid(), p_now, false, null, p_mw, h.id);
    end if;
    perform private.log_event('Help requests', 'Help request merged (same person within 1 hour)', 'help_request', h.id,
      null, jsonb_build_object('categories', v_cats), p_details, w.domain_id, w.module_id, p_mw, null, p_instructor);
    return jsonb_build_object('id', h.id, 'merged', true, 'target_at', h.response_target_at,
      'helper', private.team_names(coalesce(nullif(array[h.assigned_to], array[null]::uuid[]), h.routed_to[1:1])));
  end if;

  v_routing := private.get_setting(w.id, 'help_routing');
  v_owners := private.owners_or_leads(w.module_id);
  v_ops := private.ops_for_week(w.id);
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
  v_h := case p_urgency when 'Urgent' then private.setting_int(w.id, 'help_target_urgent_h')
                        when 'Within24h' then private.setting_int(w.id, 'help_target_24h_h')
                        else private.setting_int(w.id, 'help_target_norush_h') end;
  if v_days < 2 then
    v_h := least(v_h, private.setting_int(w.id, 'help_target_urgent_h'));
  elsif v_days <= 7 then
    v_h := least(v_h, private.setting_int(w.id, 'help_target_24h_h'));
  end if;
  if p_urgency = 'Urgent' or v_days < 2 then v_sev := 'Urgent'; end if;

  insert into public.help_request (domain_id, module_week_id, booking_id, requester_instructor_id, requester_team_member_id,
    source, categories, details, urgency, reply_channel, routed_to, severity, raised_at, response_target_at, is_test)
  values (w.domain_id, p_mw, coalesce(p_booking, (select b.id from public.booking b where b.module_week_id = p_mw and b.status = 'Active')),
    p_instructor, p_member, p_source, v_cats, left(p_details, 1000), coalesce(p_urgency, 'NoRush'), coalesce(p_reply, 'Either'),
    v_routed, v_sev, p_now, p_now + make_interval(hours => v_h),
    private.is_test_domain(w.domain_id))
  returning * into h;

  v_helper := (select t.name from public.team_member t where t.id = v_routed[1]);
  perform private.raise_attention(w.domain_id, 'HelpRequest', v_sev,
    'Need help from ' || v_name || ': ' || private.mw_label(p_mw),
    (select string_agg(private.help_category_label(x), ', ') from unnest(v_cats) x) || coalesce(E'\n' || p_details, '')
      || E'\nReply by ' || private.fmt_ist(h.response_target_at),
    'help:' || h.id, v_routed, p_now,
    private.mw_refs(p_mw, jsonb_build_object('help_request_id', h.id, 'instructor_id', p_instructor, 'due_at', h.response_target_at)),
    true, 'T7');
  if p_instructor is not null then
    perform private.queue_instructor_message('M13', p_instructor, p_mw, null, p_now, '[]',
      jsonb_build_object('helper', coalesce(v_helper, 'Our team'), 'by', private.fmt_local(h.response_target_at, coalesce(private.week_region(h.module_week_id), 'US'))),
      v_sev = 'Urgent', 'help:' || h.id, h.id,
      case when coalesce(p_reply, 'Either') = 'Email' then 'Email' when p_reply = 'Discord' then 'Discord' end);
  end if;
  perform private.log_event('Help requests', 'Help requested by ' || v_name, 'help_request', h.id, null,
    jsonb_build_object('categories', v_cats, 'urgency', p_urgency, 'routed_to', private.team_names(v_routed)),
    p_details, w.domain_id, w.module_id, p_mw, null, p_instructor, null, h.is_test);
  return jsonb_build_object('id', h.id, 'merged', false, 'target_at', h.response_target_at, 'helper', coalesce(v_helper, 'Our team'));
end;
$$;

-- public.cancel_module_week: finding 2 and 3 (was 20261112000005_r2_review_fixes.sql).
create or replace function public.cancel_module_week(p_module_week_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare w public.module_week; b public.booking; v_now timestamptz;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.status in ('Cancelled', 'Completed') then raise exception 'This module week is already %.', lower(w.status); end if;
  v_now := private.domain_now(w.domain_id);
  -- Live finding 3: messages to instructors about this class week that have not gone out are withdrawn first, so the
  -- notices queued below (class cancelled, request withdrawn) are the only ones that still go.
  perform private.withdraw_week_messages(w.id, null, 'Not sent: the class week was cancelled');
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
  -- Live finding 2: every open help request for the week closes with a note, its task done, in Activity history.
  perform private.close_week_help(w.id, null, 'Closed: the class week was cancelled', v_now);
  update public.attention_item set status = 'Done', done_at = now(), done_note = 'Module week cancelled'
   where module_week_id = w.id and status <> 'Done';
  perform private.log_event('Team actions', 'Module week cancelled', 'module_week', w.id, null, null, p_reason,
    w.domain_id, w.module_id, w.id);
  perform private.queue_deliver('cancel');
  return jsonb_build_object('ok', true);
end;
$$;

-- private.step_help: finding 1 (was 20261112000005_r2_review_fixes.sql).
create or replace function private.step_help(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare h record; n int := 0; v_targets uuid[];
begin
  for h in select hr.*, mw.module_id, mw.first_class_at, mw.at_risk
             from public.help_request hr join public.module_week mw on mw.id = hr.module_week_id
            where hr.domain_id = p_domain and hr.merged_into is null
              and hr.status in ('Open', 'InProgress', 'WaitingOnInstructor')
              and mw.status not in ('Cancelled', 'Completed')
            for update of hr skip locked loop
    v_targets := case when h.assigned_to is not null then array[h.assigned_to] else h.routed_to end;
    if h.first_response_at is null and h.half_reminder_at is null and h.status = 'Open'
       and h.raised_at + (h.response_target_at - h.raised_at) / 2 <= p_now then
      perform private.queue_team_message('REM', p_domain, 'person', t, '{}',
          'Reminder: help request for ' || private.mw_label(h.module_week_id),
          '⏰ Half-time reminder: a help request for ' || private.mw_label(h.module_week_id)
            || ' needs a reply by ' || private.fmt_ist(h.response_target_at) || '.',
          'HELPHALF:' || h.id, p_now, h.severity = 'Normal', null, h.module_week_id, h.id)
        from unnest(v_targets) t;
      update public.help_request set half_reminder_at = p_now where id = h.id;
      n := n + 1;
    end if;
    if h.first_response_at is null and h.escalated_at is null and h.response_target_at <= p_now then
      perform private.queue_team_message('T13', p_domain, 'alert', null,
        private.uniq(private.owners_or_leads(h.module_id) || private.domain_role_ids(p_domain, 'Lead')),
        'Escalation: help request past target for ' || private.mw_label(h.module_week_id),
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

-- private.step_checkins: finding 1 (was 20261112000007_r2_review_fixes_3.sql).
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
    v_send := private.instructor_send_time(b.module_week_id, p_now, v_due <= v_urgent_band, private.week_region(b.module_week_id), b.instructor_id);
    v_deadline := least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => 2 * v_rem), v_due <= v_urgent_band, private.week_region(b.module_week_id), b.instructor_id), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, check_in_days, status, sent_at,
      reminder_at, deadline_at, is_test, time_version)
    values (b.module_week_id, b.instructor_id, b.id, 'CheckIn', v_due, 'Sent', v_send,
      least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => v_rem), v_due <= v_urgent_band, private.week_region(b.module_week_id), b.instructor_id), v_deadline),
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
          'No reply to the ' || r.check_in_days || '-day check-in: ' || v_name || ' for ' || private.mw_label(r.module_week_id),
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

-- private.release_booking_flow: finding 1, 2 and 3 (was 20261113000008_final_round.sql).
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
      'Class already started: ' || v_name || ' says they can''t teach ' || private.mw_label(w.id),
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

  -- Live findings 2 and 3: the instructor no longer teaches this class week, so their open help requests for it close
  -- (each task done, in Activity history) and their messages about it that have not gone out are withdrawn.
  perform private.close_week_help(w.id, b.instructor_id, 'Closed: the instructor no longer teaches this class week', p_now);
  perform private.withdraw_week_messages(w.id, b.instructor_id, 'Not sent: the instructor no longer teaches this class week');

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

-- private.step_readiness: finding 1 (was 20261113000008_final_round.sql).
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
          'Escalation: readiness still failing for ' || private.mw_label(w.id),
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

-- public.set_app_config: finding 1 (was 20261122000003_admins_and_sign_in.sql).
create or replace function public.set_app_config(p_config jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare c public.app_config;
begin
  perform private.require_team();
  perform private.require_admin();
  select * into c from public.app_config where id = 1;
  if (p_config ->> 'version')::int is distinct from c.version then
    raise exception 'This changed. Someone else saved the system settings after you opened them. Please reload.' using errcode = '40001';
  end if;
  if p_config ? 'company_email_domain' and lower(trim(p_config ->> 'company_email_domain')) <> c.company_email_domain then
    raise exception 'The company email domain can only be changed by an admin in the database (see docs/SETUP.md).';
  end if;
  if (p_config ? 'response_base_url' and nullif(trim(p_config ->> 'response_base_url'), '') is distinct from c.response_base_url)
     or (p_config ? 'app_base_url' and nullif(trim(p_config ->> 'app_base_url'), '') is distinct from c.app_base_url) then
    raise exception 'The answer link address and the app address are set when the app is set up (npm run configure, see docs/SETUP_GUIDE.md), so nobody can point instructors somewhere else from the app.'
      using errcode = '42501';
  end if;
  update public.app_config set
    discord_guild_id = nullif(trim(coalesce(p_config ->> 'discord_guild_id', discord_guild_id)), ''),
    response_base_url = nullif(trim(coalesce(p_config ->> 'response_base_url', response_base_url)), ''),
    app_base_url = nullif(trim(coalesce(p_config ->> 'app_base_url', app_base_url)), ''),
    admin_discord_channel_id = nullif(trim(coalesce(p_config ->> 'admin_discord_channel_id', admin_discord_channel_id)), ''),
    scheduling_email = nullif(trim(coalesce(p_config ->> 'scheduling_email', scheduling_email)), ''),
    scheduling_sender_name = coalesce(nullif(trim(p_config ->> 'scheduling_sender_name'), ''), scheduling_sender_name)
  where id = 1;
end;
$$;

-- public.daily_jobs: finding 1 (was 20261122000006_security_data_findings.sql).
create or replace function public.daily_jobs(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  s public.system_state;
  v_text text;
  v_sent int; v_failed int; v_open int; v_urgent int;
begin
  perform private.count_n8n_run('WF3');
  perform private.require_service();
  perform private.set_actor('System', null, 'System');
  select * into s from public.system_state where id = 1;
  select count(*) filter (where status = 'Sent' and sent_at > v_now - interval '24 hours'),
         count(*) filter (where status = 'Failed' and updated_at > v_now - interval '24 hours')
    into v_sent, v_failed from public.message;
  select count(*), count(*) filter (where severity = 'Urgent') into v_open, v_urgent from public.attention_item where status <> 'Done';
  v_text := '💓 Daily heartbeat. Last hourly run: ' || coalesce(private.fmt_ist(s.last_hourly_run_at), 'never')
    || ' (' || coalesce(s.last_hourly_status, 'n/a') || ')'
    || E'\nMessages sent (24h): ' || v_sent || ' · failed: ' || v_failed
    || E'\nOpen items: ' || v_open || ' (' || v_urgent || ' urgent)'
    || coalesce(E'\nIn TEST MODE: ' || (select string_agg(d.name, ', ') from public.domain d where private.is_test_domain(d.id)), '')
    || case when not s.outreach_enabled then E'\n⛔ Kill switch is ON since ' || coalesce(private.fmt_ist(s.kill_switch_changed_at), '?')
            || ', so no instructor messages are going out. Turn it off in Settings → System when ready.' else '' end;
  perform private.queue_team_message('T15', null, 'admin', null, '{}', 'Daily heartbeat', v_text,
    'T15:' || to_char(v_now at time zone 'Asia/Kolkata', 'YYYY-MM-DD'), v_now);
  update public.system_state set last_daily_run_at = now(), last_heartbeat_at = now() where id = 1;
  perform private.log_event('System', 'Daily jobs', null, null, null,
    jsonb_build_object('sent_24h', v_sent, 'failed_24h', v_failed, 'open', v_open), null);
  return jsonb_build_object('sent_24h', v_sent, 'failed_24h', v_failed, 'open_items', v_open, 'urgent_items', v_urgent);
end;
$$;

-- public.record_inbound_message: finding 1 (was 20261122000006_security_data_findings.sql).
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
  perform private.require_service();
  p_body := private.strip_answer_links(p_body);
  p_subject := private.strip_answer_links(p_subject);
  p_summary := private.strip_answer_links(p_summary);
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
      private.all_operations_ids(), v_now,
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

  if v_mw is not null and private.days_until(v_mw, v_now) < private.setting_int(v_mw, 'short_notice_days') then
    v_sev := 'Urgent';
  end if;
  perform private.raise_attention(v_dom, 'TypedReply', v_sev,
    'Typed reply from ' || i.full_name || coalesce(' about ' || private.mw_label(v_mw), ''),
    coalesce('Summary: ' || p_summary || E'\n', '') || left(coalesce(p_body, ''), 500)
      || E'\nNothing was changed automatically. Read it and decide.',
    'typed:' || v_msg, coalesce(nullif(private.domain_role_ids(v_dom, 'Ops'), '{}'),
      private.all_operations_ids()), v_now,
    coalesce(private.mw_refs(v_mw, jsonb_build_object('instructor_id', i.id, 'request_id', q.id, 'message_id', v_msg)),
             jsonb_build_object('instructor_id', i.id, 'message_id', v_msg)));
  perform private.log_event('Instructor responses', 'Typed reply from ' || i.full_name, 'message', v_msg, null, null,
    left(p_body, 500), v_dom, null, v_mw, null, i.id);
  return jsonb_build_object('ok', true, 'matched', true);
end;
$$;

-- public.submit_help_request: finding 4a (was 20261122000006_security_data_findings.sql).
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
  perform private.require_service();
  select * into lnk from public.response_link where token = p_token;
  if lnk.token is null or lnk.answer not in ('NeedHelp', 'OwnerNeedHelp') then
    return jsonb_build_object('result', 'invalid', 'message', 'This link isn''t valid.');
  end if;
  select * into r from public.request where id = lnk.request_id;
  select * into w from public.module_week where id = r.module_week_id;
  if w.status in ('Cancelled', 'Completed') then
    return jsonb_build_object('result', 'closed', 'message', 'This class is no longer scheduled.');
  end if;
  if r.instructor_id is not null
     and not exists (select 1 from public.booking b where b.module_week_id = w.id and b.instructor_id = r.instructor_id and b.status = 'Active')
     and not (r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')) then
    return jsonb_build_object('result', 'closed', 'message', 'You are no longer teaching this class, so this help link has closed. If you still need something, reply in your Discord channel or by email.');
  end if;
  -- SEC 8: only the help categories the page offers (a repeat within an hour merges into the first request).
  p_categories := array(select x from unnest(coalesce(p_categories, '{}')) x
    where x = any (array['materials', 'zoom', 'platform', 'assignment', 'students', 'schedule', 'payment', 'other']));
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
    'message', (v_res ->> 'helper') || ' will reply by ' || private.fmt_local((v_res ->> 'target_at')::timestamptz, private.week_region(w.id)) || '.');
end;
$$;

-- public.record_response: finding 1 and 4a (was 20261122000006_security_data_findings.sql).
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
  perform 1 from public.module_week mw
   where mw.id = (select q.module_week_id from public.request q where q.id = lnk.request_id) for update;
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
    return jsonb_build_object('result', 'already_recorded', 'message', 'We already have your answer. Thank you!');
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
    return jsonb_build_object('result', 'cancelled', 'message', 'We''ll take it from here.', 'detail', v_res);
  end if;

  -- ---------- outreach Yes / No
  if r.kind = 'Outreach' then
    if r.status not in ('Sent', 'Reminded') then
      if r.status = 'Accepted' or (r.status = 'Declined' and r.answer is not null) then
        return jsonb_build_object('result', 'already_recorded', 'message', 'We already have your answer. Thank you!');
      end if;
      update public.response_link set used_at = now() where token = p_token;
      if v_answer = 'Yes' and w.status not in ('Cancelled', 'Completed') then
        v_days := private.days_until(w.id, v_now);
        perform private.raise_attention(w.domain_id, 'LateReply',
          case when v_days < private.setting_int(w.id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'Late "Yes" from ' || v_name || ': ' || private.mw_label(w.id),
          'They said yes after the request closed (' || coalesce(r.close_reason, r.status) || '). Assign them manually if the slot is still free.',
          'late:' || r.id, private.ops_for_week(w.id), v_now,
          private.mw_refs(w.id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)));
      end if;
      perform private.log_event('Instructor responses', 'Late answer from ' || v_name || ': ' || v_answer, 'request', r.id,
        null, null, 'Request was ' || r.status, w.domain_id, w.module_id, w.id, null, r.instructor_id);
      return jsonb_build_object('result', 'closed', 'message',
        'Nothing changed, but we''ve let the team know you replied. Thank you!');
    end if;

    if v_answer = 'Yes' then
      v_res := private.confirm_booking(w.id, r.instructor_id, r.id, 'Instructor', v_now);
      if (v_res ->> 'ok')::boolean then
        update public.response_link set used_at = now() where token = p_token;
        perform private.log_event('Instructor responses', v_name || ' said yes', 'request', r.id, null, null, null,
          w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
        return jsonb_build_object('result', 'confirmed', 'message', 'Thank you! We''ve sent the details to you.');
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
            v_name || ' said yes but couldn''t be booked for ' || private.mw_label(w.id),
            (v_res ->> 'message') || '. The next instructor is being asked.', 'yesfail:' || r.id,
            private.ops_for_week(w.id), v_now,
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
          'Declined: ' || private.mw_label(w.id), v_name || ' declined ' || private.mw_label(w.id) || '. We''re asking the next instructor.',
          'T3:' || r.id, v_now, false, null, w.id);
      end if;
      perform private.ask_next(w.id, v_now);
      return jsonb_build_object('result', 'declined', 'message', 'No problem. We''ll ask someone else.');
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
      return jsonb_build_object('result', 'cancelled', 'message', 'We''ll take it from here.');
    end if;
    if r.status not in ('Sent', 'Reminded') then
      return jsonb_build_object('result', 'already_recorded', 'message', 'We already have your answer. Thank you!');
    end if;
    if v_answer = 'AllSet' then
      update public.response_link set used_at = now() where token = p_token;
      update public.request set status = 'Accepted', answer = 'AllSet', answered_at = v_now where id = r.id;
      update public.instructor set last_response_at = v_now where id = r.instructor_id;
      perform private.resolve_attention('checkin_noreply:' || r.id, 'Instructor answered All set');
      perform private.log_event('Instructor responses', v_name || ': all set (' || r.check_in_days || '-day check-in)', 'request',
        r.id, null, null, null, w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
      return jsonb_build_object('result', 'all_set', 'message', 'See you in class.');
    end if;
  end if;

  -- ---------- time change
  if r.kind = 'TimeChange' then
    if r.status not in ('Sent', 'Reminded') then
      return jsonb_build_object('result', 'already_recorded', 'message', 'We already have your answer. Thank you!');
    end if;
    update public.response_link set used_at = now() where token = p_token;
    if v_answer = 'StillWorks' then
      update public.request set status = 'Accepted', answer = 'StillWorks', answered_at = v_now where id = r.id;
      update public.booking set time_version_confirmed = r.time_version where id = r.booking_id;
      perform private.resolve_attention('timechange:' || w.id, 'Instructor confirmed the new time');
      perform private.log_event('Instructor responses', v_name || ': new time still works', 'request', r.id, null, null, null,
        w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
      return jsonb_build_object('result', 'still_works', 'message', 'You''re still confirmed at the new time.');
    elsif v_answer = 'DoesntWork' then
      update public.request set status = 'Declined', answer = 'DoesntWork', answered_at = v_now where id = r.id;
      perform private.log_event('Instructor responses', v_name || ': new time doesn''t work', 'request', r.id, null, null, null,
        w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
      perform private.release_booking_flow(r.booking_id, 'TimeChangeDeclined', v_now);
      return jsonb_build_object('result', 'released', 'message', 'We''ll find someone for the new time.');
    end if;
  end if;

  -- ---------- owner check-in
  if r.kind = 'OwnerCheckIn' and v_answer = 'OwnerAllGood' then
    update public.response_link set used_at = now() where token = p_token;
    update public.request set status = 'Accepted', answer = 'OwnerAllGood', answered_at = v_now
     where id = r.id and status in ('Sent', 'Reminded');
    perform private.log_event('Team actions', v_name || ': all good for ' || private.mw_label(w.id), 'request', r.id,
      null, null, null, w.domain_id, w.module_id, w.id);
    return jsonb_build_object('result', 'owner_ok', 'message', 'We''ve noted that everything is fine.');
  end if;

  return jsonb_build_object('result', 'invalid', 'message', 'This link isn''t valid.');
end;
$$;

-- private.ask_next: finding 1 (was 20261122000009_sooner_class_first.sql).
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

-- private.proposal_form_fields: finding 4b and 4c (was 20261122000015_time_proposals.sql).
create or replace function private.proposal_form_fields(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(string_agg(
           '<fieldset><legend>' || private.html_escape(c.title) || '</legend>'
           || '<input type="hidden" name="c_' || n || '" value="' || c.id || '">'
           || '<label for="d_' || n || '">Date</label><input type="date" id="d_' || n || '" name="d_' || n
           || '" required style="font:inherit;padding:6px" data-show="d_' || n || '_text" aria-describedby="d_' || n || '_text" value="'
           || to_char(c.starts_at at time zone private.region_tz(c.region), 'YYYY-MM-DD') || '">'
           || '<p class="muted" id="d_' || n || '_text" aria-live="polite" style="margin:4px 0 8px">'
           || to_char(c.starts_at at time zone private.region_tz(c.region), 'FMDy, FMMon FMDD, YYYY') || '</p>'
           || '<label for="s_' || n || '">Starts</label><input type="time" id="s_' || n || '" name="s_' || n
           || '" required style="font:inherit;padding:6px" value="'
           || to_char(c.starts_at at time zone private.region_tz(c.region), 'HH24:MI') || '">'
           || '<label for="e_' || n || '">Ends</label><input type="time" id="e_' || n || '" name="e_' || n
           || '" required style="font:inherit;padding:6px" value="'
           || to_char(c.ends_at at time zone private.region_tz(c.region), 'HH24:MI') || '">'
           || '<p class="muted">' || private.zone_name(c.region) || '</p></fieldset>', '' order by n), '')
      || '<label for="note" style="font-weight:600">Note for the team (optional)</label>'
      || '<textarea id="note" name="note" maxlength="500"></textarea>'
      -- Live finding 4c: the date also shows as "Mon, Dec 14, 2026" under its box, and changes with it.
      || '<script>(function(){var o={weekday:''short'',month:''short'',day:''numeric'',year:''numeric'',timeZone:''UTC''};document.querySelectorAll(''input[data-show]'').forEach(function(i){var t=document.getElementById(i.getAttribute(''data-show''));var u=function(){var p=(i.value||'''').split(''-'');t.textContent=p.length===3?new Date(Date.UTC(+p[0],+p[1]-1,+p[2])).toLocaleDateString(''en-US'',o):''Choose a date'';};i.addEventListener(''input'',u);i.addEventListener(''change'',u);});})();</script>'
    from (select c.*, row_number() over (order by c.starts_at, c.id) as n
            from public.class_session c where c.module_week_id = p_mw and c.status = 'Planned') c;
$$;

-- public.response_page_text: finding 1 and 4a (was 20261122000015_time_proposals.sql).
create or replace function public.response_page_text(p_token text)
returns text language plpgsql security definer set search_path = ''
as $$
declare
  lnk public.response_link;
  r public.request;
  w public.module_week;
  v_name text;
  v_who text;
  v_open boolean;
  v_booking_active boolean;
  v_details text := '';
begin
  perform private.require_service();
  select * into lnk from public.response_link where token = p_token;
  if lnk.token is null then
    return private.page_message('Link not valid', 'We couldn''t find this link. If you need anything, reply in your Discord channel or by email.');
  end if;
  update public.response_link set opened_at = coalesce(opened_at, now()) where token = p_token;
  select * into r from public.request where id = lnk.request_id;
  select * into w from public.module_week where id = r.module_week_id;
  v_name := coalesce((select i.full_name from public.instructor i where i.id = r.instructor_id),
                     (select t.name from public.team_member t where t.id = r.team_member_id));
  v_who := '<p class="muted">Confirming as <strong>' || private.html_escape(v_name) || '</strong></p>';
  if w.id is not null then v_details := private.page_details(w.id); end if;
  v_open := r.status in ('Sent', 'Reminded', 'Queued');
  v_booking_active := exists (select 1 from public.booking b where b.status = 'Active'
                               and (b.id = r.booking_id or b.request_id = r.id));

  if lnk.used_at is not null then
    return private.page_message('Already recorded', 'We already have your answer. Thank you!', v_details);
  end if;
  if w.status in ('Cancelled') then
    return private.page_message('No longer needed', 'This class is no longer scheduled, so nothing is needed from you.', v_details);
  end if;
  -- SEC 8: a link closes when its classes are over, and every link expires after 90 days.
  if w.status = 'Completed' or lnk.created_at < now() - interval '90 days' then
    return private.page_message('Link closed', 'Links close when their classes are over, or 90 days after we sent them. If you need anything, reply in your Discord channel or by email.', v_details);
  end if;

  if lnk.answer in ('NeedHelp', 'OwnerNeedHelp') then
    return private.page('Need help',
      '<h1>Need help?</h1>' || v_details
      || case when lnk.answer = 'NeedHelp' then
           '<p>Tell us what you need, and we''ll help you before class.</p><div>'
         else '<details open><summary>Tell ops what you need</summary>' end
      || private.page_form(p_token, 'Send help request', '', private.help_form_fields())
      || case when lnk.answer = 'NeedHelp' then '</div>' else '</details>' end || v_who);
  end if;

  if lnk.answer = 'CantMakeIt' then
    if not v_booking_active then
      return private.page_message('Nothing to change', 'This booking is no longer active, so nothing is needed.', v_details);
    end if;
    return private.page('Can''t make it',
      '<h1>Can''t make it?</h1>' || v_details
      || '<p>This will release your class and we''ll find someone else. Are you sure?</p>'
      || private.page_form(p_token, 'Yes, release my class', 'danger')
      || '<p class="muted">Need something instead? Use the Need help button in our message.</p>' || v_who);
  end if;

  if lnk.answer = 'ProposeTime' then
    if not v_open or w.id is null or r.kind not in ('Outreach', 'TimeChange') then
      return private.page_message('Request closed', 'Nothing is needed from you. Thank you!', v_details);
    end if;
    if exists (select 1 from public.time_proposal p where p.module_week_id = w.id and p.status = 'Pending') then
      return private.page_message('Already sent', 'We have a proposed time for this class, and the team will reply soon. Thank you!', v_details);
    end if;
    return private.page('Propose another time',
      '<h1>Propose another time</h1>' || v_details
      || '<p>Change the date or time of any class below. Each time is in the time zone shown under it. The team checks it with the cohort and replies to you. Until then, nothing changes.</p>'
      || private.page_form(p_token, 'Send my proposed time', '', private.proposal_form_fields(w.id)) || v_who);
  end if;

  if not v_open then
    if lnk.answer = 'Yes' and r.kind = 'Outreach' and r.status <> 'Accepted' then
      return private.page('Request closed',
        '<h1>This request has closed</h1>' || v_details
        || '<p>We''ve already moved on for this class. If you can still teach, tap below and we''ll let the team know. They''ll be in touch if the slot is still free.</p>'
        || private.page_form(p_token, 'Tell the team I can still teach', 'secondary') || v_who);
    end if;
    return private.page_message(case when r.status = 'Accepted' then 'Already recorded' else 'Request closed' end,
      case when r.status = 'Accepted' then 'We already have your answer. Thank you!' else 'Nothing is needed from you. Thank you!' end,
      v_details);
  end if;

  return private.page('Please confirm',
    '<h1>' || case lnk.answer
        when 'Yes' then 'Confirm you can teach'
        when 'No' then 'Confirm you can''t teach'
        when 'AllSet' then 'All set?'
        when 'StillWorks' then 'Does the new time work?'
        when 'DoesntWork' then 'The new time doesn''t work?'
        when 'GotIt' then 'Confirm you got our test message'
        when 'OwnerAllGood' then 'All good?'
        else 'Please confirm' end || '</h1>'
    || v_details
    || case when lnk.answer = 'Yes' and r.deadline_at is not null then
         '<p class="muted">Please answer by ' || private.html_escape(private.fmt_local(r.deadline_at, private.week_region(w.id))) || '.</p>'
       else '' end
    || private.page_form(p_token, private.answer_label(lnk.answer), case when lnk.answer in ('No', 'DoesntWork') then 'danger' else '' end)
    || v_who);
end;
$$;

-- public.submit_response_page_text: finding 1 and 4a (was 20261122000015_time_proposals.sql).
create or replace function public.submit_response_page_text(p_token text, p_form jsonb default '{}')
returns text language plpgsql security definer set search_path = ''
as $$
declare
  lnk public.response_link;
  r public.request;
  v_res jsonb;
  v_cats text[];
  v_extra text := '';
  v_title text;
begin
  perform private.require_team();
  select * into lnk from public.response_link where token = p_token;
  if lnk.token is null then
    return private.page_message('Link not valid', 'We couldn''t find this link.');
  end if;
  select * into r from public.request where id = lnk.request_id;
  -- SEC 8: a link closes when its classes are over, and every link expires after 90 days.
  if lnk.created_at < now() - interval '90 days'
     or exists (select 1 from public.module_week mw where mw.id = r.module_week_id and mw.status = 'Completed') then
    return private.page_message('Link closed', 'Links close when their classes are over, or 90 days after we sent them. If you need anything, reply in your Discord channel or by email.');
  end if;
  if lnk.answer in ('NeedHelp', 'OwnerNeedHelp') then
    select coalesce(array_agg(substr(k, 5)), '{}') into v_cats
      from jsonb_object_keys(coalesce(p_form, '{}')) k
     where k like 'cat\_%' and coalesce(p_form ->> k, '') <> '';
    v_res := public.submit_help_request(p_token, v_cats, nullif(trim(coalesce(p_form ->> 'details', '')), ''),
      coalesce(p_form ->> 'urgency', 'NoRush'), coalesce(p_form ->> 'reply_channel', 'Either'));
    return private.page_message(case when v_res ->> 'result' = 'help_created' then 'Thanks!' else 'Sorry' end, v_res ->> 'message');
  end if;

  if lnk.answer = 'ProposeTime' then
    v_res := private.create_time_proposal(p_token, p_form);
    return private.page_message(case when v_res ->> 'result' = 'proposed' then 'Thanks!'
                                     when v_res ->> 'result' in ('closed', 'already') then 'Thank you'
                                     else 'Please check' end, v_res ->> 'message');
  end if;

  v_res := public.record_response(p_token, null);
  v_title := case v_res ->> 'result'
    when 'confirmed' then 'You''re confirmed 🎉'
    when 'declined' then 'Thanks for letting us know'
    when 'all_set' then 'Great, thanks!'
    when 'cancelled' then 'Thanks for letting us know'
    when 'released' then 'Thanks for letting us know'
    when 'still_works' then 'Thanks!'
    when 'verified' then 'Verified ✓'
    when 'owner_ok' then 'Thanks!'
    when 'already_recorded' then 'Already recorded'
    when 'closed' then 'Request closed'
    when 'not_booked' then 'Thank you!'
    else 'Sorry' end;
  if v_res ->> 'result' = 'confirmed' and r.module_week_id is not null then
    v_extra := private.page_details(r.module_week_id)
      || coalesce(nullif('<p><strong>Materials</strong></p>' || private.page_materials(r.module_week_id), '<p><strong>Materials</strong></p>'), '');
  elsif v_res ->> 'result' = 'all_set' then
    v_extra := '<p>Need anything else?</p><a class="btn secondary" href="' || private.html_escape(private.link_for(r.id, 'NeedHelp')) || '">🙋 Need help</a>';
  end if;
  return private.page_message(v_title, v_res ->> 'message', v_extra);
end;
$$;

-- private.create_time_proposal: finding 4a (was 20261122000015_time_proposals.sql).
create or replace function private.create_time_proposal(p_token text, p_form jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  lnk public.response_link;
  r public.request;
  w public.module_week;
  c public.class_session;
  v_now timestamptz;
  v_name text;
  n int := 0;
  v_items jsonb := '[]';
  v_changed boolean := false;
  v_date date;
  v_s time;
  v_e time;
  v_start timestamptz;
  v_end timestamptz;
  v_id uuid;
  v_note text := nullif(left(trim(coalesce(p_form ->> 'note', '')), 500), '');
  v_to text;
begin
  select * into lnk from public.response_link where token = p_token for update;
  if lnk.token is null or lnk.answer <> 'ProposeTime' then
    return jsonb_build_object('result', 'invalid', 'message', 'This link isn''t valid.');
  end if;
  select * into r from public.request where id = lnk.request_id for update;
  select * into w from public.module_week where id = r.module_week_id for update;
  v_now := private.domain_now(w.domain_id);
  if v_now <> now() then perform private.set_sim_now(v_now); end if;
  select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
  perform private.set_actor('Instructor', r.instructor_id, v_name);
  if r.kind not in ('Outreach', 'TimeChange') or r.status not in ('Sent', 'Reminded') or w.status in ('Cancelled', 'Completed') then
    return jsonb_build_object('result', 'closed', 'message', 'This request has closed, so nothing is needed from you. Thank you!');
  end if;
  if exists (select 1 from public.time_proposal p where p.module_week_id = w.id and p.status = 'Pending') then
    return jsonb_build_object('result', 'already', 'message', 'We already have a proposed time for this class, and the team will reply soon. Thank you!');
  end if;
  while coalesce(p_form, '{}') ? ('c_' || (n + 1)) loop
    n := n + 1;
    select * into c from public.class_session
     where id = (p_form ->> ('c_' || n))::uuid and module_week_id = w.id and status = 'Planned';
    if c.id is null then
      return jsonb_build_object('result', 'invalid', 'message', 'The classes changed after this page was opened. Please open the link again.');
    end if;
    begin
      v_date := (p_form ->> ('d_' || n))::date;
      v_s := (p_form ->> ('s_' || n))::time;
      v_e := (p_form ->> ('e_' || n))::time;
    exception when others then
      return jsonb_build_object('result', 'invalid', 'message', 'Please enter a date, a start and an end for every class.');
    end;
    if v_date is null or v_s is null or v_e is null then
      return jsonb_build_object('result', 'invalid', 'message', 'Please enter a date, a start and an end for every class.');
    end if;
    if v_e <= v_s then
      return jsonb_build_object('result', 'invalid', 'message', c.title || ': the class must end after it starts.');
    end if;
    begin
      v_start := private.local_to_utc(v_date, v_s, c.region);
      v_end := private.local_to_utc(v_date, v_e, c.region);
    exception when sqlstate '22023' then
      return jsonb_build_object('result', 'invalid', 'message', c.title || ': ' || sqlerrm);
    end;
    if v_start <= v_now then
      return jsonb_build_object('result', 'invalid', 'message', c.title || ': a proposed time must be in the future.');
    end if;
    v_changed := v_changed or v_start <> c.starts_at or v_end <> c.ends_at;
    v_to := private.fmt_class_range(v_start, v_end, c.region);
    v_items := v_items || jsonb_build_object('class_id', c.id, 'title', c.title, 'region', c.region,
      'from', private.fmt_class_range(c.starts_at, c.ends_at, c.region), 'to', v_to,
      'starts_at', v_start, 'ends_at', v_end, 'changed', v_start <> c.starts_at or v_end <> c.ends_at);
  end loop;
  if n = 0 or n <> (select count(*) from public.class_session x where x.module_week_id = w.id and x.status = 'Planned') then
    return jsonb_build_object('result', 'invalid', 'message', 'The classes changed after this page was opened. Please open the link again.');
  end if;
  if not v_changed then
    return jsonb_build_object('result', 'invalid', 'message',
      'These are the same times. Change at least one class, or answer with the buttons in our message.');
  end if;

  insert into public.time_proposal (request_id, module_week_id, domain_id, instructor_id, proposed, note, time_version)
  values (r.id, w.id, w.domain_id, r.instructor_id, v_items, v_note, w.time_version)
  returning id into v_id;
  update public.response_link set used_at = now() where token = p_token;
  -- The request stays open while Ops decides: up to 48 hours more to answer, never past the first class.
  update public.request
     set deadline_at = greatest(deadline_at, least(v_now + interval '48 hours', w.first_class_at - interval '1 hour')),
         reminder_at = null
   where id = r.id and deadline_at is not null;
  update public.instructor set last_response_at = v_now where id = r.instructor_id;
  perform private.raise_attention(w.domain_id, 'TimeProposal',
    case when private.days_until(w.id, v_now) < private.setting_int(w.id, 'short_notice_days') then 'Urgent' else 'Normal' end,
    'Proposed time from ' || v_name || ': ' || private.mw_label(w.id),
    'They propose: ' || (select string_agg((x ->> 'title') || ' ' || (x ->> 'to'), '; ') from jsonb_array_elements(v_items) x
                         where (x ->> 'changed')::boolean)
      || coalesce(E'\nTheir note: ' || v_note, '') || E'\nOpen the class week to check it, then accept or reject it.',
    'proposal:' || v_id, private.ops_for_week(w.id), v_now,
    private.mw_refs(w.id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)));
  perform private.queue_instructor_message('M18', r.instructor_id, w.id, r.id, v_now, '[]', '{}', false, 'proposal:' || v_id);
  perform private.log_event('Instructor responses', v_name || ' proposed another time', 'time_proposal', v_id, null,
    jsonb_build_object('proposed', v_items), v_note, w.domain_id, w.module_id, w.id, null, r.instructor_id, null, r.is_test);
  perform private.queue_deliver('proposal');
  return jsonb_build_object('result', 'proposed', 'id', v_id,
    'message', 'The team checks your proposed time with the cohort and replies to you soon. Until then, nothing changes.');
end;
$$;

-- private.step_owner_checkins: finding 1 (was 20261122000016_shared_classes.sql).
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
   where mw.domain_id = p_domain and mw.status not in ('Cancelled', 'Completed') and mw.owner_checkin_sent_at is null and mw.shared_with is null
     and mw.first_class_at > p_now and mw.first_class_at - make_interval(days => private.setting_int(mw.id, 'owner_checkin_days')) <= p_now
     -- Off when the team is not reminded after an assignment, or the number is 0.
     and private.setting_bool(mw.id, 'remind_team_after_assign') and private.setting_int(mw.id, 'owner_checkin_days') > 0;
  if cardinality(v_due) = 0 then return 0; end if;

  for o in select distinct x from public.module_week mw, unnest(private.owners_or_leads(mw.module_id)) x where mw.id = any (v_due) loop
    -- OUT-4: each week has its own number of days (a cohort can change it), so the text names none.
    v_text := 'Coming up soon. Please check these class weeks:';
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
      -- The status in the board's words, with the instructor who is confirmed, asked or proposing a time.
      v_status := private.week_status_text(w.id, p_now)
        || case when w.at_risk then ' (at risk: ' || coalesce(w.at_risk_reason, '') || ')' else '' end;
      v_text := v_text || E'\n\n• ' || private.mw_label(w.id) || ': ' || v_status
        || E'\n  👍 All good: ' || private.link_for(v_req, 'OwnerAllGood')
        || E'\n  🙋 Need help: ' || private.link_for(v_req, 'OwnerNeedHelp');
    end loop;
    perform private.queue_team_message('T11', p_domain, 'person', o, '{}',
      'Owner check in: your coming class weeks', v_text,
      'T11:' || o || ':' || md5(array_to_string(array(select x::text from unnest(v_due) x order by 1), ',')), p_now, true);
    n := n + 1;
  end loop;
  update public.module_week set owner_checkin_sent_at = p_now where id = any (v_due);
  return n;
end;
$$;
