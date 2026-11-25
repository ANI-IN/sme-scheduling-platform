-- Decision 349: findings of the independent review of 25 November 2026 (docs/REVIEW_REPORT.md).
--
-- R8: a typed Discord reply belongs to the instructor whose channel it was posted in.
-- R11: sending a message again goes to the recipient's current address, channel and Discord account, one copy at a time.
-- R16: a refused login makes the message wait and raises one alert; nobody is marked as failing.
-- R18: each bounce is handled once.
-- R19: automatic replies raise no task; unknown senders share one task a day.
-- R28: an app action taken and never finished goes back in the queue.
-- R9: the app can say what a domain status change will do.

create table private.seen_bounce (external_id text primary key, seen_at timestamptz not null default now());

create or replace function private.connection_broken(p_error text)
returns boolean language sql immutable set search_path = ''
as $$
  select coalesce(p_error, '') ~* '(^|[^0-9])401([^0-9]|$)|unauthorized|(^|[^0-9])40001([^0-9]|$)|invalid_grant|invalid_client';
$$;

-- R9: what changing a domain's status will do, said before it happens.
create or replace function public.domain_status_effects(p_domain_id uuid, p_status text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare d public.domain;
begin
  perform private.require_team();
  select * into d from public.domain where id = p_domain_id;
  if d.id is null then raise exception 'Domain not found.' using errcode = '22023'; end if;
  return jsonb_build_object('from', d.status,
    'open_requests', case when p_status = 'Draft' then (select count(*) from public.request r join public.module_week w on w.id = r.module_week_id
       where w.domain_id = d.id and r.kind in ('Outreach', 'TimeChange') and r.status in ('Queued', 'Sent', 'Reminded')) else 0 end,
    'waiting_messages', case when p_status = 'Draft' then (select count(*) from public.message m
       where m.domain_id = d.id and m.audience = 'Instructor' and m.status in ('Scheduled', 'Pending')) else 0 end,
    'waiting_requests', (select count(*) from public.request r join public.module_week w on w.id = r.module_week_id
       where w.domain_id = d.id and r.kind in ('Outreach', 'TimeChange') and r.status in ('Queued', 'Sent', 'Reminded')));
end;
$$;
revoke execute on function public.domain_status_effects(uuid, text) from public, anon;
grant execute on function public.domain_status_effects(uuid, text) to authenticated, service_role;

drop function if exists public.record_inbound_message(text, text, text, text, text, timestamptz, text, text);

create or replace function public.record_inbound_message(p_channel text, p_from text, p_subject text, p_body text,
  p_external_id text, p_received_at timestamptz default null, p_summary text default null, p_thread_id text default null,
  p_channel_id text default null, p_automatic boolean default false)
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
  v_chan_dom uuid;
  v_unknown public.attention_item;
  v_line text;
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
    -- Review R8 (decision 349): the instructor whose channel it was posted in; otherwise the same one every time.
    select x.* into i from public.instructor x
     where x.discord_user_id = p_from
     order by exists (select 1 from public.instructor_channel c where c.instructor_id = x.id and c.channel_id = p_channel_id) desc,
              x.is_test, x.created_at, x.id
     limit 1;
    v_chan_dom := (select c.domain_id from public.instructor_channel c
                    where c.instructor_id = i.id and c.channel_id = p_channel_id limit 1);
  end if;
  -- Finding 38: in a Testing domain every email to an instructor goes to the testing mailbox, so a reply typed there
  -- comes from the testing mailbox, not the instructor. It belongs to the test instructor whose email started the
  -- thread (a new email's Gmail id is its thread's id), and only when it comes from that domain's testing email.
  if i.id is null and p_channel = 'Email' and p_thread_id is not null then
    select ins.* into i
      from public.message m
      join public.domain dm on dm.id = m.domain_id
      join public.instructor ins on ins.id = m.instructor_id
     where m.external_id = p_thread_id and m.direction = 'Outbound' and m.channel = 'Email' and m.is_test
       and dm.test_email is not null
       and lower(dm.test_email) = lower(trim(regexp_replace(coalesce(p_from, ''), '^.*<([^>]+)>.*$', '\1')))
     order by m.created_at desc limit 1;
  end if;
  if i.id is not null then
    perform private.set_actor('Instructor', i.id, i.full_name);
    select r.* into q from public.request r join public.module_week w on w.id = r.module_week_id
     where r.instructor_id = i.id and r.status in ('Sent', 'Reminded')
     order by (w.domain_id = v_chan_dom) desc nulls last, r.created_at desc limit 1;
    v_mw := coalesce(q.module_week_id,
      (select b.module_week_id from public.booking b join public.module_week w on w.id = b.module_week_id
        where b.instructor_id = i.id and b.status = 'Active' order by w.first_class_at limit 1));
    v_dom := coalesce((select w.domain_id from public.module_week w where w.id = v_mw), v_chan_dom);
  end if;
  v_now := case when v_dom is not null then private.domain_now(v_dom) else now() end;
  insert into public.message (domain_id, direction, audience, template_id, channel, unique_key, status, instructor_id,
    module_week_id, request_id, from_address, subject, body_text, summary, external_id, recipient_label)
  values (v_dom, 'Inbound', 'Instructor', 'IN', p_channel, v_key, 'Received', i.id, v_mw, q.id, p_from, p_subject,
    left(p_body, 5000), p_summary, p_external_id, coalesce(i.full_name, p_from))
  returning id into v_msg;

  -- Review R19 (decision 349): an automatic reply (out of office, bulk mail) is kept and logged, never a task.
  if p_automatic then
    perform private.log_event('Instructor responses', 'Automatic reply from ' || coalesce(i.full_name, p_from, '?'),
      'message', v_msg, null, null, left(p_body, 300), v_dom, null, v_mw, null, i.id);
    return jsonb_build_object('ok', true, 'matched', i.id is not null, 'automatic', true);
  end if;

  if i.id is null then
    -- One task a day for senders nobody knows.
    v_line := coalesce(p_from, '?') || ': ' || coalesce(p_summary, left(p_body, 300), '');
    select * into v_unknown from public.attention_item
     where dedupe_key = 'typed:unknown:' || to_char(v_now at time zone 'UTC', 'YYYY-MM-DD') and status <> 'Done';
    perform private.raise_attention(null, 'TypedReply', 'Normal',
      case when v_unknown.id is null then 'Message from an unknown sender: ' || coalesce(p_from, '?')
           else 'Messages from unknown senders today' end,
      case when v_unknown.id is null then v_line else left(coalesce(v_unknown.detail, '') || E'\n' || v_line, 4000) end,
      'typed:unknown:' || to_char(v_now at time zone 'UTC', 'YYYY-MM-DD'),
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

create or replace function public.record_bounce(p_email text, p_external_id text default null, p_detail text default null,
  p_thread_id text default null, p_report boolean default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  q record;
  v_urgent boolean := false;
  v_dom uuid;
  v_sent public.message;
begin
  perform private.require_service();
  perform private.set_actor('System', null, 'System');
  -- Review R18 (decision 349): a bounce read again (for example when labelling it failed) changes nothing.
  if p_external_id is not null then
    insert into private.seen_bounce (external_id) values (p_external_id) on conflict do nothing;
    if not found then return jsonb_build_object('ok', true, 'matched', false, 'duplicate', true); end if;
  end if;
  select ins.* into i from public.instructor_email e join public.instructor ins on ins.id = e.instructor_id
   where lower(e.email) = lower(trim(p_email));
  if i.id is null then
    return jsonb_build_object('ok', true, 'matched', false);
  end if;
  -- SEC 9: a bounce counts only when it is in the Gmail thread of an email the app really sent to that address
  -- (Gmail puts the delivery report in the thread of the message it is about; a new message's thread id is its own
  -- id, which the app keeps as external_id). Anything else is logged and ignored, so nobody can mark an
  -- instructor's address as broken by sending a fake "Undeliverable" email.
  select m.* into v_sent from public.message m
   where m.channel = 'Email' and m.direction = 'Outbound' and m.status = 'Sent'
     and lower(m.to_address) = lower(trim(p_email)) and p_thread_id is not null and m.external_id = p_thread_id
   order by m.sent_at desc limit 1;
  if v_sent.id is null then
    perform private.log_event('Messages', 'Bounce ignored: ' || i.full_name, 'instructor', i.id, null,
      jsonb_build_object('email', p_email, 'delivery_report', p_report),
      'An email that looked like a bounce for ' || p_email || ' was ignored: it is not about an email the app sent to '
        || 'that address. Nothing was changed.', null, null, null, null, i.id);
    return jsonb_build_object('ok', true, 'matched', false, 'trusted', false);
  end if;
  update public.instructor set email_bounced_at = now() where id = i.id;
  select r.*, w.domain_id as dom into q from public.request r join public.module_week w on w.id = r.module_week_id
   where r.instructor_id = i.id and r.status in ('Sent', 'Reminded') order by r.created_at desc limit 1;
  v_dom := q.dom;
  if q.id is not null then
    v_urgent := private.days_until(q.module_week_id, private.domain_now(v_dom)) < private.setting_int(q.module_week_id, 'short_notice_days');
  end if;
  perform private.raise_attention(v_dom, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
    'Email bounced: ' || i.full_name || ' (' || p_email || ')',
    coalesce(p_detail, 'The email address may be wrong.') || ' Discord is still used. Fix the email in Instructors.',
    'bounce:' || i.id, coalesce(nullif(private.domain_role_ids(v_dom, 'Ops'), '{}'),
      private.all_operations_ids()),
    coalesce(private.domain_now(v_dom), now()), jsonb_build_object('instructor_id', i.id), true, 'T14');
  perform private.log_event('Messages', 'Email bounced: ' || i.full_name, 'instructor', i.id, null, null, p_detail,
    v_dom, null, v_sent.module_week_id, null, i.id);
  return jsonb_build_object('ok', true, 'matched', true, 'trusted', true);
end;
$$;

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
  -- Review R16 (decision 349): an expired or refused login is the connection's fault, not the message's or the
  -- person's: it waits 15 minutes without using up a try, and one alert a day says which connection is broken.
  if m.status = 'Sending' and private.connection_broken(p_error) then
    update public.message set status = 'Pending', last_error = p_error, attempts = greatest(attempts - 1, 0),
           retry_at = now() + interval '15 minutes' where id = m.id;
    perform private.raise_attention(null, 'Other', 'Urgent',
      'The ' || case when m.channel = 'Discord' then 'Discord' else 'email' end || ' connection is broken',
      'Sending fails because the login was refused (' || left(coalesce(p_error, ''), 200) || '). Messages wait and go out '
        || 'by themselves once it works. An admin signs the connection in again in n8n.',
      'connection:' || m.channel || ':' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD'),
      private.all_operations_ids(), now(), '{}', true, 'T14');
    return jsonb_build_object('ok', true, 'status', 'Retry', 'connection', true);
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

create or replace function public.next_actions(p_limit int default 20)
returns setof public.action_queue language plpgsql security definer set search_path = ''
as $$
begin
  perform private.count_n8n_run('WF4');
  perform private.require_service();
  -- Review R28 (decision 349): taken more than 15 minutes ago and never finished (the answer was lost): again.
  update public.action_queue set status = 'Queued'
   where status = 'Processing' and left(action, 8) <> 'discord_' and updated_at < now() - interval '15 minutes';
  return query
  with c as (select a.id from public.action_queue a where a.status = 'Queued' and left(a.action, 8) <> 'discord_' order by a.created_at limit p_limit for update skip locked)
  update public.action_queue a set status = 'Processing' from c where a.id = c.id returning a.*;
end;
$$;

create or replace function public.resend_message(p_message_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  m public.message; v_id uuid; v_now timestamptz; v_send timestamptz;
  i public.instructor;
  t public.team_member;
  dm public.domain;
  v_to text; v_chan text; v_dm text; v_old text; v_new text; v_mentions text[]; v_text text; v_html text;
begin
  perform private.require_team();
  select * into m from public.message where id = p_message_id;
  if m.id is null or m.direction <> 'Outbound' then raise exception 'Choose a sent message to resend.'; end if;
  -- A message a beta rule stopped can be sent again once the rule allows it (owner, 23 November 2026).
  if m.status not in ('Sent', 'Failed') and not (m.status = 'Cancelled' and coalesce(m.blocked, false)) then
    raise exception 'That message hasn''t gone out yet (it is %), so there is nothing to resend.', lower(m.status);
  end if;
  if m.domain_id is not null and m.audience <> 'Admin' and m.is_test <> private.is_test_domain(m.domain_id) then
    raise exception 'Testing was switched on or off since this message was sent. Send a new message instead, from Instructor requests after the next check.';
  end if;
  if exists (select 1 from public.message x
              where starts_with(x.unique_key, coalesce(m.unique_key, m.id::text) || ':resend:')
                and x.status in ('Scheduled', 'Pending', 'Sending')) then
    raise exception 'This message is already being sent again. Wait for that copy.' using errcode = '22023';
  end if;
  -- Review R11 (decision 349): to the address, channel and Discord account they have now, not the old ones.
  v_to := m.to_address; v_chan := m.discord_channel_id; v_dm := m.discord_dm_user_id;
  v_mentions := m.mention_user_ids; v_text := m.body_text; v_html := m.body_html;
  select * into dm from public.domain where id = m.domain_id;
  if m.audience = 'Instructor' and m.instructor_id is not null then
    select * into i from public.instructor where id = m.instructor_id;
    if m.is_test then
      if m.channel = 'Email' then v_to := coalesce(dm.test_email, m.to_address);
      elsif v_chan is not null then v_chan := coalesce(dm.test_discord_channel_id, v_chan); end if;
    elsif m.channel = 'Email' then
      v_to := i.primary_email;
    else
      v_old := coalesce(m.discord_dm_user_id, (regexp_match(m.body_text, 'Hi <@(\d+)>'))[1]);
      v_new := i.discord_user_id;
      if v_old is not null and v_old is distinct from v_new then
        v_mentions := case when v_new is null then array_remove(v_mentions, v_old) else array_replace(v_mentions, v_old, v_new) end;
        v_text := replace(v_text, '<@' || v_old || '>', coalesce('<@' || v_new || '>', private.first_name(i.full_name)));
      end if;
      if v_dm is not null then
        if v_new is null then
          raise exception '% has no Discord account now, so this message cannot be sent again.', i.full_name using errcode = '22023';
        end if;
        v_dm := v_new;
      elsif v_chan is not null then
        v_chan := (select c.channel_id from public.instructor_channel c
                    where c.instructor_id = i.id and (m.domain_id is null or c.domain_id = m.domain_id)
                    order by (c.ready_at is not null) desc, c.created_at desc limit 1);
        if v_chan is null then
          raise exception '% has no Discord channel here now. Choose one on Setup, Instructors, then send again.', i.full_name
            using errcode = '22023';
        end if;
      end if;
    end if;
  elsif m.audience = 'Team' and m.team_member_id is not null and not m.is_test then
    select * into t from public.team_member where id = m.team_member_id;
    if m.channel = 'Email' then v_to := t.email;
    elsif v_dm is not null and t.discord_user_id is not null then
      v_text := replace(v_text, '<@' || v_dm || '>', '<@' || t.discord_user_id || '>');
      v_mentions := array_replace(v_mentions, v_dm, t.discord_user_id);
      v_dm := t.discord_user_id;
    end if;
  end if;
  v_now := coalesce(private.domain_now(m.domain_id), now());
  v_send := case when m.audience = 'Instructor' then private.instructor_send_time(coalesce(m.module_week_id, m.domain_id), v_now, false, coalesce(private.week_region(m.module_week_id), 'US'), m.instructor_id) else v_now end;
  if m.request_id is not null and exists (select 1 from public.request r where r.id = m.request_id
       and r.status not in ('Queued', 'Sent', 'Reminded', 'Accepted')) then
    raise exception 'That request has closed, so the message would confuse the instructor. Ask again instead.';
  end if;
  insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id,
    team_member_id, module_week_id, request_id, help_request_id, attention_item_id, recipient_label, to_address,
    discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html, buttons, is_test)
  select domain_id, audience, template_id, channel,
         coalesce(unique_key, id::text) || ':resend:' || (extract(epoch from clock_timestamp()) * 1000000)::bigint,
         case when v_send > v_now then 'Scheduled' else 'Pending' end, v_send, instructor_id, team_member_id, module_week_id, request_id, help_request_id, attention_item_id,
         recipient_label, v_to, v_chan, v_dm, v_mentions, subject, v_text, v_html,
         buttons, is_test
    from public.message where id = p_message_id
  returning id into v_id;
  perform private.log_event('Team actions', case when m.status = 'Cancelled' then 'Sent again after it was blocked: ' else 'Resent ' end
      || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
    'message', v_id, null, null, null, m.domain_id, null, m.module_week_id, null, m.instructor_id);
  perform private.queue_deliver('resend');
  return jsonb_build_object('ok', true, 'message_id', v_id);
end;
$$;

create or replace function public.log_system_error(p_workflow text, p_message text, p_url text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_service();
  perform private.set_actor('System', null, 'n8n');
  perform private.log_event('System', 'Automation error: ' || coalesce(p_workflow, '?'), null, null, null,
    jsonb_build_object('url', p_url), p_message);
  perform private.queue_team_message('T14', null, 'admin', null, '{}', 'Automation error: ' || coalesce(p_workflow, '?'),
    '❗ n8n workflow "' || coalesce(p_workflow, '?') || '" failed: ' || coalesce(p_message, '?') || coalesce(E'\n' || p_url, ''),
    'T14:wf:' || md5(coalesce(p_workflow, '') || coalesce(p_message, '') || to_char(now(), case when p_message like '%Discord channels could not be read%' then 'YYYYMMDD' else 'YYYYMMDDHH24' end)), now());
end;
$$;

grant execute on function public.record_inbound_message(text, text, text, text, text, timestamptz, text, text, text, boolean) to service_role;
