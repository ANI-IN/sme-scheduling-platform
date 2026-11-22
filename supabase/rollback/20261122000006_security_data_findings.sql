-- Rollback for 20261122000006_security_data_findings.sql: puts back every changed function exactly as it was.

-- public.claim_outbound_messages, as in 20261122000004_beta_guard.sql.
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

-- public.report_message_result, as in 20261113000006_demo_messages.sql.
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
  perform private.require_team();
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

-- public.record_bounce, as in 20261111000002_release_routing_settings.sql.
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
    v_urgent := private.days_until(q.module_week_id, private.domain_now(v_dom)) < private.setting_int(q.module_week_id, 'short_notice_days');
  end if;
  perform private.raise_attention(v_dom, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
    'Email bounced: ' || i.full_name || ' (' || p_email || ')',
    coalesce(p_detail, 'The email address may be wrong.') || ' Discord is still used. Fix the email in Instructors.',
    'bounce:' || i.id, coalesce(nullif(private.domain_role_ids(v_dom, 'Ops'), '{}'),
      private.all_operations_ids()),
    coalesce(private.domain_now(v_dom), now()), jsonb_build_object('instructor_id', i.id), true, 'T14');
  perform private.log_event('Messages', 'Email bounced: ' || i.full_name, 'instructor', i.id, null, null, p_detail,
    v_dom, null, null, null, i.id);
  return jsonb_build_object('ok', true, 'matched', true);
end;
$$;

-- public.engine_tick_all, as in 20261122000002_database_clock.sql.
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
  perform private.count_n8n_run('WF1');
  perform private.require_team();
  for d in select * from public.domain where status in ('Test', 'Live', 'Paused') and archived_at is null order by name loop
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

-- public.next_actions, as in 20261122000002_database_clock.sql.
create or replace function public.next_actions(p_limit int default 20)
returns setof public.action_queue language plpgsql security definer set search_path = ''
as $$
begin
  perform private.count_n8n_run('WF4');
  perform private.require_team();
  return query
  with c as (select a.id from public.action_queue a where a.status = 'Queued' and left(a.action, 8) <> 'discord_' order by a.created_at limit p_limit for update skip locked)
  update public.action_queue a set status = 'Processing' from c where a.id = c.id returning a.*;
end;
$$;

-- public.complete_action, as in 20261110000003_engine.sql.
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

-- public.daily_jobs, as in 20261122000002_database_clock.sql.
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
    || coalesce(E'\nIn TEST MODE: ' || (select string_agg(d.name, ', ') from public.domain d where private.is_test_domain(d.id)), '')
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

-- public.log_system_error, as in 20261110000006_app_support.sql.
create or replace function public.log_system_error(p_workflow text, p_message text, p_url text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  perform private.set_actor('System', null, 'n8n');
  perform private.log_event('System', 'Automation error: ' || coalesce(p_workflow, '?'), null, null, null,
    jsonb_build_object('url', p_url), p_message);
  perform private.queue_team_message('T14', null, 'admin', null, '{}', 'Automation error: ' || coalesce(p_workflow, '?'),
    '❗ n8n workflow "' || coalesce(p_workflow, '?') || '" failed: ' || coalesce(p_message, '?') || coalesce(E'\n' || p_url, ''),
    'T14:wf:' || md5(coalesce(p_workflow, '') || coalesce(p_message, '') || to_char(now(), 'YYYYMMDDHH24')), now());
end;
$$;

-- public.set_discord_cursor, as in 20261110000003_engine.sql.
create or replace function public.set_discord_cursor(p_channel_id text, p_last_message_id text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  insert into public.discord_cursor (channel_id, last_message_id, updated_at) values (p_channel_id, p_last_message_id, now())
  on conflict (channel_id) do update set last_message_id = excluded.last_message_id, updated_at = now();
end;
$$;

-- public.record_inbound_message, as in 20261111000002_release_routing_settings.sql.
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
    'Typed reply from ' || i.full_name || coalesce(' — ' || private.mw_label(v_mw), ''),
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

-- public.response_page_text, as in 20261122000001_baseline_fixes.sql.
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
  perform private.require_team();
  select * into lnk from public.response_link where token = p_token;
  if lnk.token is null then
    return private.page_message('Link not valid', 'This link isn''t valid. If you need anything, reply in your Discord channel or by email.');
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
    return private.page_message('Already recorded', 'Already recorded — thank you!', v_details);
  end if;
  if w.status in ('Cancelled') then
    return private.page_message('No longer needed', 'This class is no longer scheduled, so nothing is needed from you.', v_details);
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

  if not v_open then
    if lnk.answer = 'Yes' and r.kind = 'Outreach' and r.status <> 'Accepted' then
      return private.page('Request closed',
        '<h1>This request has closed</h1>' || v_details
        || '<p>We''ve already moved on for this class. If you can still teach, tap below and we''ll let the team know — they''ll be in touch if the slot is still free.</p>'
        || private.page_form(p_token, 'Tell the team I can still teach', 'secondary') || v_who);
    end if;
    return private.page_message(case when r.status = 'Accepted' then 'Already recorded' else 'Request closed' end,
      case when r.status = 'Accepted' then 'Already recorded — thank you!' else 'This request has closed, so nothing is needed from you. Thank you!' end,
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

-- public.submit_response_page_text, as in 20261110000004_pages.sql.
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
    return private.page_message('Link not valid', 'This link isn''t valid.');
  end if;
  select * into r from public.request where id = lnk.request_id;
  if lnk.answer in ('NeedHelp', 'OwnerNeedHelp') then
    select coalesce(array_agg(substr(k, 5)), '{}') into v_cats
      from jsonb_object_keys(coalesce(p_form, '{}')) k
     where k like 'cat\_%' and coalesce(p_form ->> k, '') <> '';
    v_res := public.submit_help_request(p_token, v_cats, nullif(trim(coalesce(p_form ->> 'details', '')), ''),
      coalesce(p_form ->> 'urgency', 'NoRush'), coalesce(p_form ->> 'reply_channel', 'Either'));
    return private.page_message(case when v_res ->> 'result' = 'help_created' then 'Thanks!' else 'Sorry' end, v_res ->> 'message');
  end if;

  v_res := public.record_response(p_token, null);
  v_title := case v_res ->> 'result'
    when 'confirmed' then 'You''re confirmed 🎉'
    when 'declined' then 'Thanks for letting us know'
    when 'all_set' then 'Great — thanks!'
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

-- public.submit_help_request, as in 20261112000005_r2_review_fixes.sql.
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
    'message', 'Thanks! ' || (v_res ->> 'helper') || ' will reply by ' || private.fmt_local((v_res ->> 'target_at')::timestamptz, private.week_region(w.id)) || '.');
end;
$$;

-- private.step_complete, as in 20261112000005_r2_review_fixes.sql.
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
            for update skip locked loop
    -- OUT-6: a week that was never filled is over too: it is closed, and so are its tasks.
    update public.booking set status = 'Completed' where module_week_id = w.id and status = 'Active';
    update public.module_week set status = 'Completed', at_risk = false where id = w.id;
    update public.attention_item set status = 'Done', done_at = now(),
           done_note = case when exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Completed')
                            then 'The classes are over' else 'The classes are over (no instructor was confirmed)' end
     where module_week_id = w.id and status <> 'Done';
    update public.request set status = 'Superseded', close_reason = 'Classes completed'
     where module_week_id = w.id and status in ('Queued', 'Sent', 'Reminded');
    perform private.log_event('System',
      case when exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Completed')
           then 'Module week completed' else 'Class week ended without a confirmed instructor' end,
      'module_week', w.id, null, null, null, w.domain_id, w.module_id, w.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- public.set_week_same_instructor, as in 20261112000002_r2_regions_time_zones.sql.
create or replace function public.set_week_same_instructor(p_module_week_id uuid, p_on boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  c record;
  v_new uuid;
  v_group uuid;
  v_weeks uuid[];
  n int := 0;
  v_seq int;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.id is null then raise exception 'Class week not found.' using errcode = '22023'; end if;
  v_group := coalesce(w.split_group, w.id);
  v_weeks := case when p_on then array(select id from public.module_week where split_group = v_group order by first_class_at)
                  else array[w.id] end;
  if exists (select 1 from public.booking b where b.module_week_id = any (v_weeks) and b.status = 'Active')
     or exists (select 1 from public.request r where r.module_week_id = any (v_weeks) and r.kind = 'Outreach'
                   and r.status in ('Queued', 'Sent', 'Reminded')) then
    raise exception 'Someone is confirmed or being asked for this class week. Release them or pause requests first.' using errcode = '22023';
  end if;

  if not p_on then
    if not w.same_instructor then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update public.module_week set same_instructor = false, split_group = v_group where id = w.id;
    for c in select * from public.class_session where module_week_id = w.id and status = 'Planned' order by starts_at offset 1 loop
      select coalesce(max(seq), 0) + 1 into v_seq from public.module_week
       where module_id = w.module_id and cohort_id = w.cohort_id and week_start_date = (c.starts_at at time zone private.region_tz(c.region))::date;
      insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour, paused,
                                      same_instructor, split_group, status)
      values (w.module_id, w.cohort_id, (c.starts_at at time zone private.region_tz(c.region))::date, v_seq, w.outreach_mode,
              w.manual_end_behaviour, w.paused, false, v_group,
              case when w.status in ('Planned', 'NotReady', 'Ready') then w.status else 'Planned' end)
      returning id into v_new;
      update public.class_session set module_week_id = v_new where id = c.id;
      n := n + 1;
    end loop;
  else
    if w.same_instructor and coalesce(array_length(v_weeks, 1), 0) <= 1 then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update public.class_session set module_week_id = v_weeks[1] where module_week_id = any (v_weeks[2:]);
    update public.module_week set status = 'Cancelled', same_instructor = true where id = any (v_weeks[2:]);
    delete from public.module_week x where x.id = any (v_weeks[2:])
       and not exists (select 1 from public.request r where r.module_week_id = x.id)
       and not exists (select 1 from public.booking b where b.module_week_id = x.id)
       and not exists (select 1 from public.help_request h where h.module_week_id = x.id)
       and not exists (select 1 from public.attention_item a where a.module_week_id = x.id)
       and not exists (select 1 from public.message g where g.module_week_id = x.id)
       and not exists (select 1 from public.manual_queue_item q where q.module_week_id = x.id);
    update public.module_week set same_instructor = true, split_group = null where id = v_weeks[1];
    n := coalesce(array_length(v_weeks, 1), 1) - 1;
    w.id := v_weeks[1];
  end if;
  perform private.log_event('Team actions', case when p_on then 'Same instructor turned on for the class week'
                                                 else 'Same instructor turned off for the class week' end,
    'module_week', w.id, null, jsonb_build_object('class_weeks_changed', n), nullif(trim(coalesce(p_reason, '')), ''),
    w.domain_id, w.module_id, w.id);
  return jsonb_build_object('ok', true, 'changed', n, 'module_week_id', w.id);
end;
$$;

-- public.shift_classes, as in 20261112000005_r2_review_fixes.sql.
create or replace function public.shift_classes(p_module_week_id uuid, p_weeks int, p_include_later boolean default true)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w0 public.module_week;
  w record;
  c record;
  n int := 0;
  v_now timestamptz;
  v_msg text;
  v_clash boolean;
begin
  perform private.require_team();
  if p_weeks = 0 or abs(p_weeks) > 26 then raise exception 'Shift by 1 to 26 weeks.'; end if;
  select * into w0 from public.module_week where id = p_module_week_id;
  v_now := private.domain_now(w0.domain_id);
  -- Refuse (in plain words) a shift that would land on a week the same module already has.
  select m.name || ' already has a week starting ' || to_char(t.week_start_date, 'Mon FMDD, YYYY')
    into v_msg
    from public.module_week mw
    join public.module_week t on t.module_id = mw.module_id and t.cohort_id = mw.cohort_id and t.seq = mw.seq
                             and t.week_start_date = mw.week_start_date + 7 * p_weeks
    join public.module m on m.id = mw.module_id
   where mw.domain_id = w0.domain_id and mw.cohort_id = w0.cohort_id and mw.status not in ('Completed', 'Cancelled')
     and (mw.id = w0.id or (p_include_later and mw.week_start_date > w0.week_start_date))
     and not (t.id = w0.id or (p_include_later and t.week_start_date > w0.week_start_date and t.status not in ('Completed', 'Cancelled')))
   limit 1;
  if v_msg is not null then
    raise exception 'Can''t shift: %. Move or cancel that week first, or shift all later weeks too.', v_msg;
  end if;
  for w in select mw.* from public.module_week mw
            where mw.domain_id = w0.domain_id and mw.cohort_id = w0.cohort_id and mw.status not in ('Completed', 'Cancelled')
              and (mw.id = w0.id or (p_include_later and mw.week_start_date > w0.week_start_date))
            order by case when p_weeks > 0 then mw.week_start_date end desc, case when p_weeks < 0 then mw.week_start_date end asc loop
    update public.module_week set week_start_date = week_start_date + 7 * p_weeks where id = w.id;
    v_clash := false;
    -- Move every class of the week first (latest first when moving forward), then recalculate once,
    -- so the instructor gets one message with the final times.
    for c in select * from public.class_session where module_week_id = w.id and status = 'Planned'
              order by case when p_weeks > 0 then starts_at end desc, case when p_weeks < 0 then starts_at end asc loop
      -- keep the same Pacific wall-clock time across daylight saving changes
      v_clash := private.move_class(c.id,
        private.local_to_utc((c.starts_at at time zone private.region_tz(c.region))::date + 7 * p_weeks, (c.starts_at at time zone private.region_tz(c.region))::time, c.region),
        private.local_to_utc((c.ends_at at time zone private.region_tz(c.region))::date + 7 * p_weeks, (c.ends_at at time zone private.region_tz(c.region))::time, c.region))
        or v_clash;
    end loop;
    if v_clash then
      -- Nothing is saved: the person moving the dates sees who clashes and where.
      raise exception '% cannot teach % at the new dates: %. Release them first, or move fewer weeks.',
        (select i.full_name from public.booking b join public.instructor i on i.id = b.instructor_id
          where b.module_week_id = w.id and b.status = 'Active'),
        private.mw_label(w.id),
        coalesce(private.week_clash((select b.instructor_id from public.booking b where b.module_week_id = w.id and b.status = 'Active'), w.id),
                 'another class at the same time')
        using errcode = '23P01';
    end if;
    perform private.week_times_changed(w.id, v_now, v_clash);
    n := n + 1;
  end loop;
  perform private.log_event('Team actions', 'Shifted ' || n || ' module week(s) by ' || p_weeks || ' week(s)', 'module_week',
    p_module_week_id, null, null, null, w0.domain_id, w0.module_id, w0.id);
  perform private.queue_deliver('shift');
  return jsonb_build_object('ok', true, 'weeks_shifted', n);
end;
$$;

-- public.create_module_weeks, as in 20261112000005_r2_review_fixes.sql.
create or replace function public.create_module_weeks(p_domain_id uuid, p_rows jsonb, p_accept_warnings boolean default false,
  p_reason text default null, p_fold int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  c jsonb;
  m public.module;
  v_mw uuid;
  v_group uuid;
  v_cohort uuid;
  v_ids uuid[] := '{}';
  v_problems text[] := '{}';
  v_warn jsonb := '[]';
  v_start timestamptz;
  v_end timestamptz;
  v_first date;
  v_seq int;
  v_batch jsonb := '[]';
  v_mode text := private.setting_text(p_domain_id, 'default_outreach_mode');
  v_end_b text := private.setting_text(p_domain_id, 'manual_end_behaviour');
  v_region text;
  v_amb jsonb;
begin
  perform private.require_team();
  -- SCH-5: one planner at a time per domain, so two people planning the same weeks cannot both save them.
  perform pg_advisory_xact_lock(hashtext('plan:' || p_domain_id::text));
  -- Checks first: nothing is saved when anything is blocked or warnings need confirming.
  for r in select * from jsonb_array_elements(p_rows) loop
    select * into m from public.module where id = (r ->> 'module_id')::uuid;
    if m.domain_id is distinct from p_domain_id then
      v_problems := v_problems || 'A module does not belong to this domain.'::text;
      continue;
    end if;
    if jsonb_array_length(coalesce(r -> 'classes', '[]')) = 0 then
      v_problems := v_problems || (m.name || ' has no classes in this plan. Add class times on the module page first.');
      continue;
    end if;
    v_cohort := coalesce((r ->> 'cohort_id')::uuid,
                         (select id from public.cohort where domain_id = p_domain_id and lower(name) = lower(coalesce(nullif(trim(r ->> 'cohort'), ''), 'Main cohort'))));
    select min((x ->> 'date')::date) into v_first from jsonb_array_elements(r -> 'classes') x;
    if v_cohort is not null and m.same_instructor_for_module_week and exists (
         select 1 from public.module_week w where w.module_id = m.id and w.cohort_id = v_cohort and w.week_start_date = v_first
                                              and w.status <> 'Cancelled') then
      v_problems := v_problems || ('Already planned: ' || m.name || ' starting ' || to_char(v_first, 'Dy, Mon FMDD, YYYY')
        || ' in ' || (select name from public.cohort where id = v_cohort) || '.');
    end if;
    for c in select * from jsonb_array_elements(r -> 'classes') loop
      v_region := coalesce(c ->> 'region', r ->> 'region', (select co.region from public.cohort co where co.id = v_cohort), 'US');
      v_start := private.local_to_utc((c ->> 'date')::date, (c ->> 'start_time')::time, v_region,
                                      coalesce((c ->> 'fold')::int, p_fold, 1));
      v_end := private.local_to_utc((c ->> 'date')::date + case when (c ->> 'end_time')::time <= (c ->> 'start_time')::time then 1 else 0 end,
                                    (c ->> 'end_time')::time, v_region, coalesce((c ->> 'fold')::int, p_fold, 1));
      -- SCH-5: a class of this module and cohort already planned at the same moment.
      if v_cohort is not null and exists (
           select 1 from public.class_session cs join public.module_week mw on mw.id = cs.module_week_id
            where mw.module_id = m.id and mw.cohort_id = v_cohort and cs.status <> 'Cancelled' and cs.starts_at = v_start) then
        v_problems := v_problems || ('Already planned: ' || coalesce(c ->> 'title', m.name) || ' on '
          || private.fmt_class_range(v_start, v_end, v_region) || '.');
      end if;
      -- SCH-1: classes of one class week (one instructor) never overlap each other.
      if m.same_instructor_for_module_week and exists (
           select 1 from jsonb_array_elements(r -> 'classes') o
            where o <> c
              and tstzrange(private.local_to_utc((o ->> 'date')::date, (o ->> 'start_time')::time, v_region, coalesce((o ->> 'fold')::int, p_fold, 1)),
                            private.local_to_utc((o ->> 'date')::date + case when (o ->> 'end_time')::time <= (o ->> 'start_time')::time then 1 else 0 end,
                                                 (o ->> 'end_time')::time, v_region, coalesce((o ->> 'fold')::int, p_fold, 1)), '[)')
                  && tstzrange(v_start, v_end, '[)')) then
        v_problems := v_problems || (coalesce(c ->> 'title', 'A class') || ' on ' || private.fmt_class_range(v_start, v_end, v_region)
          || ' overlaps another class of the same class week. One instructor teaches the whole week, so change one of the times.');
      end if;
      if (c ->> 'end_time')::time = (c ->> 'start_time')::time then
        v_problems := v_problems || (coalesce(c ->> 'title', 'A class') || ' must end after it starts.');
      end if;
      v_warn := v_warn || private.class_warnings(p_domain_id, v_cohort, v_start, v_end, null, c ->> 'title', v_region);
      v_amb := private.ambiguous_warning((c ->> 'date')::date, (c ->> 'start_time')::time, v_region, c ->> 'title');
      if v_amb is not null and coalesce((c ->> 'fold')::int, p_fold) is null then v_warn := v_warn || jsonb_build_array(v_amb); end if;
      -- Overlaps inside this plan (same cohort).
      if exists (select 1 from jsonb_array_elements(v_batch) b
                  where (b ->> 'cohort') = coalesce(v_cohort::text, lower(coalesce(r ->> 'cohort', '')))
                    and tstzrange((b ->> 's')::timestamptz, (b ->> 'e')::timestamptz, '[)') && tstzrange(v_start, v_end, '[)')) then
        v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'cohort_overlap',
          'text', coalesce(c ->> 'title', 'A class') || ' on ' || private.fmt_class_range(v_start, v_end, v_region) || ' overlaps another class in this plan for the same cohort.'));
      end if;
      v_batch := v_batch || jsonb_build_object('cohort', coalesce(v_cohort::text, lower(coalesce(r ->> 'cohort', ''))), 's', v_start, 'e', v_end);
    end loop;
  end loop;
  if cardinality(v_problems) > 0 then
    raise exception '%', array_to_string(v_problems, E'\n') using errcode = '23505';
  end if;
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    select * into m from public.module where id = (r ->> 'module_id')::uuid;
    v_cohort := coalesce((r ->> 'cohort_id')::uuid, private.cohort_by_name(p_domain_id, r ->> 'cohort'));
    -- A cohort created by this plan gets the region chosen for it.
    if r ? 'region' and not exists (select 1 from public.module_week x where x.cohort_id = v_cohort) then
      update public.cohort set region = r ->> 'region' where id = v_cohort;
    end if;
    v_mw := null;
    v_group := null;
    for c in select * from jsonb_array_elements(r -> 'classes') x order by (x ->> 'date')::date, (x ->> 'start_time')::time loop
      v_region := coalesce(c ->> 'region', r ->> 'region', (select co.region from public.cohort co where co.id = v_cohort), 'US');
      v_start := private.local_to_utc((c ->> 'date')::date, (c ->> 'start_time')::time, v_region,
                                      coalesce((c ->> 'fold')::int, p_fold, 1));
      v_end := private.local_to_utc((c ->> 'date')::date + case when (c ->> 'end_time')::time <= (c ->> 'start_time')::time then 1 else 0 end,
                                    (c ->> 'end_time')::time, v_region, coalesce((c ->> 'fold')::int, p_fold, 1));
      if v_mw is null or not m.same_instructor_for_module_week then
        select coalesce(max(seq), 0) + 1 into v_seq from public.module_week
         where module_id = m.id and cohort_id = v_cohort and week_start_date = (c ->> 'date')::date;
        insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour,
                                        same_instructor, split_group)
        values (m.id, v_cohort, (c ->> 'date')::date, v_seq,
                private.setting_text(coalesce(v_cohort, p_domain_id), 'default_outreach_mode'),
                private.setting_text(coalesce(v_cohort, p_domain_id), 'manual_end_behaviour'),
                m.same_instructor_for_module_week, v_group)
        returning id into v_mw;
        if not m.same_instructor_for_module_week then
          v_group := coalesce(v_group, v_mw);
          update public.module_week set split_group = v_group where id = v_mw;
        end if;
        v_ids := v_ids || v_mw;
      end if;
      insert into public.class_session (module_week_id, pattern_item_id, class_type, title, starts_at, ends_at, region)
      values (v_mw, nullif(c ->> 'pattern_item_id', '')::uuid, coalesce(nullif(c ->> 'class_type', ''), 'Other'),
              coalesce(nullif(c ->> 'title', ''), 'Class'), v_start, v_end, v_region);
    end loop;
  end loop;
  perform private.log_accepted_warnings(v_warn, p_reason, p_domain_id);
  perform private.log_event('Team actions', 'Planned ' || cardinality(v_ids) || ' class week(s)', 'domain', p_domain_id,
    null, jsonb_build_object('module_week_ids', to_jsonb(v_ids)), nullif(trim(coalesce(p_reason, '')), ''), p_domain_id);
  return jsonb_build_object('ok', true, 'created', cardinality(v_ids), 'module_week_ids', to_jsonb(v_ids), 'warnings', v_warn);
end;
$$;

-- public.record_response, as in 20261111000002_release_routing_settings.sql.
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
          case when v_days < private.setting_int(w.id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'Late "Yes" from ' || v_name || ' — ' || private.mw_label(w.id),
          'They said yes after the request closed (' || coalesce(r.close_reason, r.status) || '). Assign them manually if the slot is still free.',
          'late:' || r.id, private.ops_for_week(w.id), v_now,
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

-- public.reply_to_instructor, as in 20261110000009_reply.sql.
create or replace function public.reply_to_instructor(p_item_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  a public.attention_item;
  v_from text := coalesce((select t.name from public.team_member t where t.id = private.current_team_member_id()), 'SME Scheduling');
  v_n int;
begin
  perform private.require_team();
  if coalesce(trim(p_text), '') = '' then raise exception 'Write a reply first.'; end if;
  select * into a from public.attention_item where id = p_item_id;
  if a.instructor_id is null then raise exception 'This item is not about an instructor.'; end if;
  v_n := private.queue_instructor_message('M14', a.instructor_id, a.module_week_id, null,
    coalesce(private.domain_now(a.domain_id), now()), '[]',
    jsonb_build_object('text', p_text, 'from', v_from), false,
    'reply:' || a.id || ':' || extract(epoch from clock_timestamp())::bigint);
  update public.attention_item set status = 'Acknowledged', acknowledged_by = private.current_team_member_id(),
         ack_until = coalesce(private.domain_now(a.domain_id), now()) + interval '24 hours',
         assigned_to = coalesce(assigned_to, private.current_team_member_id())
   where id = a.id and status <> 'Done';
  perform private.log_event('Team actions', 'Replied to ' || (select i.full_name from public.instructor i where i.id = a.instructor_id),
    'attention_item', a.id, null, jsonb_build_object('text', p_text), null, a.domain_id, a.module_id, a.module_week_id,
    null, a.instructor_id);
  perform private.queue_deliver('reply');
  return jsonb_build_object('ok', true, 'messages', v_n);
end;
$$;

-- public.set_instructor_channel, as in 20261122000005_discord_server_approval.sql.
create or replace function public.set_instructor_channel(p_instructor_id uuid, p_domain_id uuid, p_channel_id text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  c public.discord_channel;
begin
  perform private.require_team();
  if p_channel_id is null then
    delete from public.instructor_channel where instructor_id = p_instructor_id and domain_id = p_domain_id;
    return;
  end if;
  select * into c from public.discord_channel where id = p_channel_id;
  if c.id is null then
    raise exception 'That channel is not in the list. Press Refresh channels on Connections, then choose again.' using errcode = '22023';
  end if;
  if not private.server_allowed(c.server_id, p_domain_id) then
    raise exception 'An admin must approve the Discord server of #% for this domain first (Settings, Connections).', c.name
      using errcode = '22023';
  end if;
  if c.bot_can_post = false then
    raise exception 'The bot cannot post in #%. Give the bot''s role View Channels and Send Messages there, press Check on Connections, then choose it again.', c.name
      using errcode = '22023';
  end if;
  if exists (select 1 from public.instructor_channel x join public.instructor i on i.id = x.instructor_id
              where x.domain_id = p_domain_id and x.channel_id = p_channel_id and x.instructor_id <> p_instructor_id and i.status = 'Active') then
    raise exception '#% is already the channel of %. Each instructor needs their own channel, so nobody else can answer for them.',
      c.name, (select i.full_name from public.instructor_channel x join public.instructor i on i.id = x.instructor_id
                where x.domain_id = p_domain_id and x.channel_id = p_channel_id and x.instructor_id <> p_instructor_id limit 1)
      using errcode = '22023';
  end if;
  insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name)
  values (p_instructor_id, p_domain_id, c.id, c.name)
  on conflict (instructor_id, domain_id) do update set channel_id = excluded.channel_id, channel_name = excluded.channel_name;
  -- A new channel needs a new contact check.
  update public.instructor set verified_at = null, discord_failed_at = null, version = version
   where id = p_instructor_id and verified_at is not null;
end;
$$;

-- public.pause_outreach, as in 20261113000008_final_round.sql.
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

drop function if exists private.strip_answer_links(text);
drop function if exists private.require_service();
