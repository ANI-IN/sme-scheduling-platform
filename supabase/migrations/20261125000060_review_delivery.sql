-- Decision 348: message delivery findings of the independent review of 25 November 2026 (docs/REVIEW_REPORT.md).
--
-- R4: only a message being sent (or waiting for its check) takes the automation's answer, and only from the run that
-- took it, so a late or repeated answer never sends a message again.
-- R6: a retry waits about 1, 5, then 15 minutes (or Discord's retry_after) without calling n8n at once; reply
-- reading and calls to n8n slow from 5,000 runs a month, and from 8,000 only the clock calls, rarely.
-- R30: one claim at a time, taking no more emails than the daily limit leaves.
-- R43: "no longer needed" waits while the request it answers is waiting for a check.
-- R5: a request's answer window starts when it is sent; one that cannot be sent raises a task and nobody else is
-- asked; time paused (Pause all, a paused domain or class week) is added to open windows.

alter table public.message add column retry_at timestamptz;
alter table public.domain add column paused_at timestamptz;
alter table public.module_week add column paused_at timestamptz;

-- R43: "no longer needed" waits while the request it answers is waiting for a check.
create or replace function private.waits_for_check(p_template text, p_request uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select p_template in ('M3', 'M12') and p_request is not null
     and exists (select 1 from public.message x where x.request_id = p_request and x.template_id in ('M1', 'M2', 'M5')
                  and x.status = 'CheckNeeded');
$$;

-- R5: where the request message itself stands: sent; held (waiting longer than 10 minutes, being sent or checked);
-- dead (every copy blocked, cancelled or failed); or open (nothing to wait for: its window runs as usual).
create or replace function private.ask_state(p_request uuid)
returns text language sql stable security definer set search_path = ''
as $$
  with c as (select m.status, m.created_at from public.message m
              where m.request_id = p_request and m.direction = 'Outbound' and m.audience = 'Instructor'
                and m.template_id in ('M1', 'M5', 'M17', 'M20'))
  select case
    when not exists (select 1 from c) then 'open'
    when exists (select 1 from c where status = 'Sent') then 'sent'
    when exists (select 1 from c where status in ('CheckNeeded', 'Sending')
                  or (status = 'Pending' and created_at < now() - interval '10 minutes')) then 'held'
    when not exists (select 1 from c where status in ('Scheduled', 'Pending')) then 'dead'
    else 'open' end;
$$;

create or replace function private.check_ask_sent(p_request uuid, p_now timestamptz)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  q public.request;
  m public.message;
  v_dom uuid;
begin
  select * into q from public.request where id = p_request;
  if q.id is null or q.status not in ('Sent', 'Reminded') or private.ask_state(q.id) <> 'dead' then return; end if;
  select * into m from public.message x where x.request_id = q.id and x.direction = 'Outbound' and x.audience = 'Instructor'
     and x.template_id in ('M1', 'M5', 'M17', 'M20') order by x.blocked desc, x.created_at desc limit 1;
  select w.domain_id into v_dom from public.module_week w where w.id = q.module_week_id;
  perform private.raise_attention(v_dom, 'MessageFailed',
    case when private.days_until(q.module_week_id, p_now) < private.setting_int(q.module_week_id, 'short_notice_days') then 'Urgent' else 'Normal' end,
    'Request not sent to ' || coalesce(m.recipient_label, 'the instructor') || ': ' || private.mw_label(q.module_week_id),
    'Nobody else is asked and nothing moves on by itself. ' || coalesce(m.last_error, 'The message could not be sent.')
      || ' Once that is fixed, send the message again, or withdraw the request and ask again.',
    'asknotsent:' || q.id, private.recipients_for_week(q.module_week_id, true), p_now,
    private.mw_refs(q.module_week_id, jsonb_build_object('instructor_id', q.instructor_id, 'request_id', q.id, 'message_id', m.id)),
    true, 'T14');
end;
$$;

create or replace function private.ask_delivered(p_message_id uuid, p_at timestamptz)
returns void language plpgsql security definer set search_path = ''
as $$
declare m public.message;
begin
  select * into m from public.message where id = p_message_id;
  if m.request_id is null or m.audience <> 'Instructor' or m.template_id not in ('M1', 'M5', 'M17', 'M20') then return; end if;
  update public.attention_item set status = 'Done', done_at = now(), done_note = 'The request was sent.'
   where dedupe_key = 'asknotsent:' || m.request_id and status <> 'Done';
  -- Only the first copy that arrives moves the window.
  if exists (select 1 from public.message x where x.request_id = m.request_id and x.id <> m.id and x.status = 'Sent'
              and x.audience = 'Instructor' and x.template_id in ('M1', 'M5', 'M17', 'M20')) then return; end if;
  update public.request r
     set sent_at = p_at,
         deadline_at = least(r.deadline_at + (p_at - r.sent_at), w.first_class_at),
         reminder_at = case when r.reminder_at is null then null
                            else least(r.reminder_at + (p_at - r.sent_at), r.deadline_at + (p_at - r.sent_at), w.first_class_at) end
    from public.module_week w
   where r.id = m.request_id and w.id = r.module_week_id and r.status in ('Sent', 'Reminded') and r.sent_at is not null
     and r.deadline_at is not null and p_at > r.sent_at + interval '10 minutes';
end;
$$;

-- A copy blocked as it goes out: if it was the last one, say so.
create or replace function private.message_blocked_ask()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.blocked and old.status is distinct from new.status and new.request_id is not null then
    perform private.check_ask_sent(new.request_id, coalesce(private.domain_now(new.domain_id), now()));
  end if;
  return null;
end;
$$;
drop trigger if exists message_blocked_ask on public.message;
create trigger message_blocked_ask after update of status on public.message
  for each row execute function private.message_blocked_ask();

-- R5: time spent paused does not count against anyone: open windows move by it, never past the first class.
create or replace function private.shift_windows(p_delta interval, p_domain uuid default null, p_week uuid default null)
returns int language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  if p_delta is null or p_delta <= interval '1 minute' then return 0; end if;
  update public.request r
     set deadline_at = least(r.deadline_at + p_delta, w.first_class_at),
         reminder_at = case when r.status = 'Sent' and r.reminder_at is not null then least(r.reminder_at + p_delta, w.first_class_at)
                            else r.reminder_at end
    from public.module_week w join public.domain d on d.id = w.domain_id
   where w.id = r.module_week_id and r.status in ('Sent', 'Reminded') and r.deadline_at is not null
     and (p_domain is null or w.domain_id = p_domain) and (p_week is null or w.id = p_week)
     and (p_domain is not null or p_week is not null or (d.status <> 'Paused' and not w.paused))
     and private.ask_state(r.id) in ('sent', 'open');  -- one not sent yet counts from when it is sent
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function private.system_pause_shift()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.outreach_enabled and not old.outreach_enabled then
    perform private.shift_windows(now() - old.kill_switch_changed_at);
  end if;
  return null;
end;
$$;
drop trigger if exists system_pause_shift on public.system_state;
create trigger system_pause_shift after update on public.system_state
  for each row execute function private.system_pause_shift();

create or replace function private.domain_pause_times()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'Paused' and old.status <> 'Paused' then
    new.paused_at := now();
  elsif old.status = 'Paused' and new.status <> 'Paused' then
    if new.status in ('Test', 'Live') then perform private.shift_windows(now() - old.paused_at, new.id); end if;
    new.paused_at := null;
  end if;
  return new;
end;
$$;
drop trigger if exists domain_pause_times on public.domain;
create trigger domain_pause_times before update of status on public.domain
  for each row execute function private.domain_pause_times();

create or replace function private.week_pause_times()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.paused and not old.paused then
    new.paused_at := now();
  elsif old.paused and not new.paused then
    perform private.shift_windows(now() - old.paused_at, null, new.id);
    new.paused_at := null;
  end if;
  return new;
end;
$$;
drop trigger if exists week_pause_times on public.module_week;
create trigger week_pause_times before update of paused on public.module_week
  for each row execute function private.week_pause_times();

drop function if exists public.report_message_result(uuid, boolean, text, text, boolean);

create or replace function public.report_message_result(p_message_id uuid, p_ok boolean, p_external_id text default null,
  p_error text default null, p_permanent boolean default false, p_retry_after int default null,
  p_claimed_at timestamptz default null)
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
  -- Review R4 (decision 348): only a message being sent (or waiting for its check) takes an answer, and only from
  -- the run that took it. A late or repeated answer must never put a finished message back in the queue.
  if m.status not in ('Sending', 'CheckNeeded') or (p_claimed_at is not null and m.claimed_at is distinct from p_claimed_at) then
    perform private.log_event(case when m.channel = 'Discord' then 'Discord' else 'Messages' end,
      'Late answer ignored: ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || private.message_route(m),
      'message', m.id, null, null, 'The message is ' || lower(m.status) || '; the automation answered ' ||
      case when p_ok then 'sent' else 'not sent' end || ' too late.', m.domain_id, null, m.module_week_id, null, m.instructor_id, null, m.is_test);
    return jsonb_build_object('ok', true, 'status', 'Ignored', 'was', m.status);
  end if;
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
    update public.message set status = 'Sent', sent_at = now(), external_id = p_external_id, last_error = null, retry_at = null where id = m.id;
    perform private.ask_delivered(m.id, v_now);  -- R5: the answer window starts when the request is sent
    perform private.log_event(case when m.channel = 'Discord' then 'Discord' else 'Messages' end,
      m.template_id || ' sent to ' || coalesce(m.recipient_label, '?') || ' via ' || private.message_route(m),
      'message', m.id, null, null, null, m.domain_id, null, m.module_week_id, null, m.instructor_id, null, m.is_test);
    return jsonb_build_object('ok', true, 'status', 'Sent');
  end if;
  if m.attempts < 4 and not p_permanent then
    -- Review R6: wait about 1, 5, then 15 minutes (or as long as Discord says), and let the clock call n8n then.
    update public.message set status = 'Pending', last_error = p_error,
           retry_at = now() + greatest(case when m.attempts <= 1 then interval '1 minute' when m.attempts = 2 then interval '5 minutes'
                                            else interval '15 minutes' end, make_interval(secs => greatest(coalesce(p_retry_after, 0), 0)))
     where id = m.id;
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
  -- Review R30 (decision 348): one claim at a time, so two runs together never take more emails than the limit leaves.
  perform pg_advisory_xact_lock(hashtextextended('claim outbound messages', 0));
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
    select m.id, m.channel, m.created_at from public.message m left join public.domain d on d.id = m.domain_id
     where m.status = 'Pending' and m.direction = 'Outbound'
       and (m.retry_at is null or m.retry_at <= now())  -- R6: a retry waits its time
       and (m.channel <> 'Email' or (select private.email_cap_left()) > 0)
       and (m.audience <> 'Instructor'
            or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                and coalesce(d.status, 'Live') <> 'Paused' and d.archived_at is null))
       and not private.waits_for_check(m.template_id, m.request_id)  -- R43
     order by m.created_at
     limit greatest(1, least(p_limit, 100))
     for update of m skip locked),
  pick as (
    select x.id from (select c.id, c.channel, row_number() over (partition by c.channel order by c.created_at, c.id) n from c) x
     -- R30: only as many emails as the daily limit leaves.
     where x.channel <> 'Email' or x.n <= (select greatest(private.email_cap_left(), 0))),
  u as (
    update public.message m set status = 'Sending', claimed_at = now(), attempts = m.attempts + 1
      from pick where m.id = pick.id
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
                and (m.retry_at is null or m.retry_at <= v_now) and not private.waits_for_check(m.template_id, m.request_id)
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
  -- Review R6 (decision 348): everything slows well before the 10,000 runs a month.
  select case when p_runs < 5000 then interval '10 minutes' when p_runs < 6500 then interval '30 minutes'
              when p_runs < 8000 then interval '60 minutes' end;
$$;

create or replace function private.poke_gap(p_runs int)
returns interval language sql immutable set search_path = ''
as $$
  -- Calls made the moment work arrives; none above 8,000 (the clock still calls).
  select case when p_runs < 5000 then interval '5 seconds' when p_runs < 6500 then interval '1 minute'
              when p_runs < 8000 then interval '5 minutes' end;
$$;

create or replace function private.clock_gap(p_runs int)
returns interval language sql immutable set search_path = ''
as $$
  select case when p_runs < 6500 then interval '1 minute' when p_runs < 8000 then interval '5 minutes' else interval '10 minutes' end;
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
  if v_runs >= 5000 and st.budget_alert_month is distinct from date_trunc('month', v_now at time zone 'UTC')::date then
    perform private.log_event('System', 'n8n budget: replies read less often', null, null, null,
      jsonb_build_object('runs_this_month', v_runs,
        'reading', case when v_runs < 6500 then 'every 30 minutes' when v_runs < 8000 then 'every hour'
                        else 'only when n8n runs for other work' end));
    update public.clock_state set budget_alert_month = date_trunc('month', v_now at time zone 'UTC')::date where id = 1;
  end if;
  -- Decision 332: no class week is left Asking with no request open (only while the clock is on).
  perform private.settle_asking_weeks(p_now);
  v_reason := private.clock_work(v_now);
  if v_reason is null then return jsonb_build_object('work', false); end if;
  if st.last_poke_at is not null and st.last_poke_at > v_now - private.clock_gap(v_runs) then
    return jsonb_build_object('work', true, 'reason', v_reason, 'skipped',
      case when private.clock_gap(v_runs) = interval '1 minute' then 'called less than a minute ago' else 'called a short while ago' end);
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
  v_gap interval;
begin
  if not coalesce((select c.clock_enabled from public.app_config c where c.id = 1), false) then return; end if;
  v_gap := private.poke_gap(public.n8n_runs_this_month(now()));
  if v_gap is null then return; end if;  -- R6: near the monthly limit only the clock calls
  select s.id into v_id from public.clock_state s
   where s.id = 1 and (s.last_poke_at is null or s.last_poke_at < now() - v_gap)
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
  if exists (select 1 from new_rows n where n.status = 'Pending' and n.direction = 'Outbound' and (n.retry_at is null or n.retry_at <= now())) then
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
           E'\nWarning: n8n runs this month have passed 80% of the 10,000 limit. Replies are read less often'
           || ' from 5,000 runs, and only when other work runs from 8,000. Check Usage in Settings, Connections.'
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
  v_ask text;
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
    -- Review R5 (decision 348): a request that has not reached the instructor (waiting, being checked or blocked)
    -- keeps its window: no reminder, no "No reply", and nobody else is asked.
    v_ask := private.ask_state(r.id);
    if v_ask in ('held', 'dead') then
      if v_ask = 'dead' then perform private.check_ask_sent(r.id, p_now); end if;
      continue;
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
  perform private.check_ask_sent(v_req, p_now);  -- R5: if the rules blocked every copy, say so at once

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
    -- R5: the window counts from when it reached them (in the domain's own time).
    perform private.ask_delivered(m.id, coalesce(private.domain_now(m.domain_id), now()) - (now() - coalesce(m.claimed_at, now())));
    perform private.log_event('Team actions', 'Marked as arrived: ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?')
        || ' via ' || private.message_route(m),
      'message', m.id, null, null, v_who || ' checked that it arrived.', m.domain_id, null, m.module_week_id, null, m.instructor_id);
    v_res := jsonb_build_object('ok', true, 'status', 'Sent');
  else
    update public.message set status = 'Failed', last_error = 'It did not arrive (checked by ' || v_who || ').' where id = m.id;
    if m.request_id is not null and exists (select 1 from public.request r where r.id = m.request_id
         and r.status not in ('Queued', 'Sent', 'Reminded', 'Accepted')) then
      -- Review R43: the request closed meanwhile, so there is nothing to send again; and if it never reached them,
      -- no "no longer needed" either.
      update public.message set status = 'Cancelled', last_error = 'Not sent: the request it answers never reached them.'
       where request_id = m.request_id and template_id in ('M3', 'M12') and status in ('Scheduled', 'Pending')
         and not exists (select 1 from public.message x where x.request_id = m.request_id and x.template_id in ('M1', 'M2', 'M5')
                          and x.status in ('Sent', 'Sending', 'CheckNeeded'));
      v_res := jsonb_build_object('ok', true, 'status', 'Failed', 'resent', false);
    else
      v_res := public.resend_message(m.id);
    end if;
  end if;
  update public.attention_item set status = 'Done', done_at = now(), done_by = private.current_team_member_id(),
         done_note = case when p_arrived then 'It arrived, marked as sent' else 'It did not arrive, sent again' end
   where dedupe_key = 'msgcheck:' || m.id and status <> 'Done';
  return v_res;
end;
$$;

grant execute on function public.report_message_result(uuid, boolean, text, text, boolean, int, timestamptz) to service_role;
