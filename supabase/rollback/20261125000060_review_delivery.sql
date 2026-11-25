-- Rollback of 20261125000060_review_delivery.sql. Deletes no data (only the retry and pause times it added).
drop trigger if exists message_blocked_ask on public.message;
drop trigger if exists system_pause_shift on public.system_state;
drop trigger if exists domain_pause_times on public.domain;
drop trigger if exists week_pause_times on public.module_week;
drop function if exists private.message_blocked_ask();
drop function if exists private.system_pause_shift();
drop function if exists private.domain_pause_times();
drop function if exists private.week_pause_times();
drop function if exists public.report_message_result(uuid, boolean, text, text, boolean, int, timestamptz);

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
  -- A late answer for a message waiting for a check (decision 341) settles the check by itself.
  if m.status = 'CheckNeeded' then
    update public.attention_item set status = 'Done', done_at = now(),
           done_note = case when p_ok then 'The automation said later that it was sent.'
                            else 'The automation said later that it was not sent.' end
     where dedupe_key = 'msgcheck:' || m.id and status <> 'Done';
    if not p_ok then
      -- It did not go out: from here it is a failed message like any other, with its own task, never retried by itself.
      p_permanent := true;
    end if;
  end if;
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

create or replace function public.claim_outbound_messages(p_limit int default 25)
returns setof public.message language plpgsql security definer set search_path = ''
as $$
declare v_stuck uuid;
begin
  perform private.require_service();
  -- OUT-2: drop what should no longer go out before handing messages to n8n.
  perform private.cancel_stale_messages();
  -- DIS-13 and decision 341: never send again by itself what may already have arrived (Discord only drops a repeated
  -- nonce for a few minutes, and Gmail never does). A message the automation took 15 minutes ago without saying how
  -- it went becomes "Check needed": the team is told and chooses Send again or It arrived, mark as sent.
  for v_stuck in select id from public.message where status = 'Sending' and claimed_at < now() - interval '15 minutes' loop
    perform private.mark_check_needed(v_stuck);
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
    from u
   -- Review R2 (decision 346): the beta guard runs again in the update above and may cancel a row there ("blocked").
   -- RETURNING gives the row as the guard left it, so only rows really taken for sending go to n8n.
   where u.status = 'Sending';
end;
$$;

create or replace function private.clock_work(p_now timestamptz default null)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_interval interval := private.clock_reply_interval(public.n8n_runs_this_month(v_now));
  v_read timestamptz := (select last_reply_read_at from public.clock_state where id = 1);
begin
  if exists (select 1 from public.message m left join public.domain d on d.id = m.domain_id
              where m.status = 'Pending' and m.direction = 'Outbound'
                and (m.channel <> 'Email' or (select private.email_cap_left()) > 0)
                and (m.audience <> 'Instructor'
                     or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                         and coalesce(d.status, 'Live') <> 'Paused' and d.archived_at is null))) then
    return 'messages to send';
  end if;
  if exists (select 1 from public.action_queue a where a.status = 'Queued' and left(a.action, 8) <> 'discord_') then
    return 'app actions';
  end if;
  if exists (select 1 from public.action_queue a where a.status = 'Queued' and left(a.action, 8) = 'discord_') then
    return 'Discord checks';
  end if;
  -- An open conversation: something was sent to an instructor in the last 3 days, so a typed reply may come.
  if v_interval is not null and (v_read is null or v_read <= v_now - v_interval)
     and exists (select 1 from public.message m where m.direction = 'Outbound' and m.audience = 'Instructor'
                    and m.status = 'Sent' and m.sent_at > v_now - interval '3 days') then
    return 'reading replies';
  end if;
  return null;
end;
$$;

create or replace function private.clock_reply_interval(p_runs int)
returns interval language sql immutable set search_path = ''
as $$
  select case when p_runs < 8000 then interval '10 minutes' when p_runs < 9300 then interval '20 minutes' end;
$$;

create or replace function private.clock_tick(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_reason text;
  v_result text;
  v_runs int;
  st public.clock_state;
begin
  -- Owner, 23 November 2026: a Discord check finishes or fails within a few minutes, never "Checking" for hours.
  perform private.expire_stuck_checks(coalesce(p_now, now()));
  if not coalesce((select c.clock_enabled from public.app_config c where c.id = 1), false) then
    return jsonb_build_object('skipped', 'clock off');
  end if;
  select * into st from public.clock_state where id = 1 for update;
  -- One alert a month when the brakes start.
  v_runs := public.n8n_runs_this_month(v_now);
  if v_runs >= 8000 and st.budget_alert_month is distinct from date_trunc('month', v_now at time zone 'UTC')::date then
    perform private.log_event('System', 'n8n budget: replies read less often', null, null, null,
      jsonb_build_object('runs_this_month', v_runs,
        'reading', case when v_runs < 9300 then 'every 20 minutes' else 'only when n8n runs for other work' end));
    update public.clock_state set budget_alert_month = date_trunc('month', v_now at time zone 'UTC')::date where id = 1;
  end if;
  -- Decision 332: no class week is left Asking with no request open (only while the clock is on).
  perform private.settle_asking_weeks(p_now);
  v_reason := private.clock_work(v_now);
  if v_reason is null then return jsonb_build_object('work', false); end if;
  if st.last_poke_at is not null and st.last_poke_at > v_now - interval '1 minute' then
    return jsonb_build_object('work', true, 'reason', v_reason, 'skipped', 'called less than a minute ago');
  end if;
  v_result := private.poke_n8n(v_reason);
  update public.clock_state
     set last_poke_at = case when v_result = 'sent' then v_now else last_poke_at end,
         last_reason = v_reason, last_result = v_result, updated_at = now()
   where id = 1;
  return jsonb_build_object('work', true, 'reason', v_reason, 'result', v_result);
end;
$$;

create or replace function private.poke_soon(p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_id int;
begin
  if not coalesce((select c.clock_enabled from public.app_config c where c.id = 1), false) then return; end if;
  select s.id into v_id from public.clock_state s
   where s.id = 1 and (s.last_poke_at is null or s.last_poke_at < now() - interval '5 seconds')
   for update skip locked;
  if v_id is null then return; end if;
  if private.poke_n8n(p_reason) = 'sent' then
    update public.clock_state set last_poke_at = now(), last_reason = p_reason, last_result = 'sent', updated_at = now()
     where id = 1;
  end if;
exception when others then
  null;
end;
$$;

create or replace function private.poke_on_message()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from new_rows n where n.status = 'Pending' and n.direction = 'Outbound') then
    perform private.poke_soon('a message to send');
  end if;
  return null;
end;
$$;

create or replace function private.daily_summary_usage(p_runs int, p_db_bytes bigint)
returns text language sql immutable set search_path = ''
as $$
  select 'n8n runs this month: ' || to_char(p_runs, 'FM999,999,990') || ' of 10,000 ('
      || round(p_runs * 100.0 / 10000) || '%)'
      || E'\nDatabase size: ' || to_char(round(p_db_bytes / 1048576.0, 1), 'FM999,990.0') || ' MB of 500 MB ('
      || round(p_db_bytes * 100.0 / (500 * 1048576.0)) || '%)'
      || case when p_runs >= 8000 then
           E'\nWarning: n8n runs this month have passed 80% of the 10,000 limit. Replies are read every 20 minutes'
           || ' from 8,000 runs, and only when other work runs from 9,300. Check Usage in Settings, Connections.'
         else '' end
      || case when p_db_bytes >= 0.8 * 500 * 1048576 then
           E'\nWarning: the database has passed 80% of the 500 MB free limit. Purge the old run logs and archive old'
           || ' Activity history now (see docs/STORAGE_FORECAST.md).'
         else '' end;
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
  v_status text;
  v_deadline timestamptz;
  v_reminder timestamptz;
begin
  for r in select q.*, mw.module_id, mw.first_class_at
             from public.request q join public.module_week mw on mw.id = q.module_week_id
            where mw.domain_id = p_domain and not mw.paused
              and q.kind in ('Outreach', 'TimeChange') and q.status in ('Sent', 'Reminded')
            -- Sooner classes first, the same order as asking (decision 296), so every run gives the same result.
            order by mw.first_class_at, q.created_at
            for update of q skip locked loop
    -- Act on the request as it is now (decision 340). Earlier in this loop, asking for a sooner class can withdraw
    -- this request ("Sooner class") and ask someone else for its week; the copy taken when the loop started would
    -- still read Sent, and marking it Reminded or Expired would reopen or overwrite a closed request.
    select q.status, q.deadline_at, q.reminder_at into v_status, v_deadline, v_reminder
      from public.request q where q.id = r.id;
    if v_status is null or v_status not in ('Sent', 'Reminded') then
      continue;
    end if;
    r.status := v_status;
    r.deadline_at := v_deadline;
    r.reminder_at := v_reminder;
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
                        and m.status in ('Sending', 'Sent', 'CheckNeeded'));
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

create or replace function public.resolve_message_check(p_message_id uuid, p_arrived boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  m public.message;
  v_who text;
  v_res jsonb;
begin
  perform private.require_team();
  select * into m from public.message where id = p_message_id for update;
  if m.id is null then raise exception 'That message was not found.' using errcode = '22023'; end if;
  if m.status <> 'CheckNeeded' then
    raise exception 'This message no longer needs a check: it is %.', case m.status
      when 'Sent' then 'marked as sent' when 'Failed' then 'marked as not delivered' else lower(m.status) end
      using errcode = '22023';
  end if;
  v_who := coalesce((select t.name from public.team_member t where t.id = private.current_team_member_id()), 'someone on the team');
  if p_arrived then
    update public.message set status = 'Sent', sent_at = coalesce(claimed_at, now()), last_error = null where id = m.id;
    perform private.log_event('Team actions', 'Marked as arrived: ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?')
        || ' via ' || private.message_route(m),
      'message', m.id, null, null, v_who || ' checked that it arrived.', m.domain_id, null, m.module_week_id, null, m.instructor_id);
    v_res := jsonb_build_object('ok', true, 'status', 'Sent');
  else
    update public.message set status = 'Failed', last_error = 'It did not arrive (checked by ' || v_who || ').' where id = m.id;
    v_res := public.resend_message(m.id);
  end if;
  update public.attention_item set status = 'Done', done_at = now(), done_by = private.current_team_member_id(),
         done_note = case when p_arrived then 'It arrived, marked as sent' else 'It did not arrive, sent again' end
   where dedupe_key = 'msgcheck:' || m.id and status <> 'Done';
  return v_res;
end;
$$;

grant execute on function public.report_message_result(uuid, boolean, text, text, boolean) to service_role;
drop function if exists private.shift_windows(interval, uuid, uuid);
drop function if exists private.ask_delivered(uuid, timestamptz);
drop function if exists private.check_ask_sent(uuid, timestamptz);
drop function if exists private.ask_state(uuid);
drop function if exists private.waits_for_check(text, uuid);
drop function if exists private.poke_gap(int);
drop function if exists private.clock_gap(int);
alter table public.message drop column retry_at;
alter table public.domain drop column paused_at;
alter table public.module_week drop column paused_at;
