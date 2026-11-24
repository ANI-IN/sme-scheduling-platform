-- Rollback of 20261124000054_request_loop_current_rows.sql: step_requests as in 20261124000043_live_findings.sql.
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
