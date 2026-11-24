-- Leftover findings of the live journey of 24 November 2026 (decision 345).
-- 39: going back to Draft also withdraws open time change requests (it withdrew only asking requests); nothing is sent.
-- 38: in a Testing domain, a typed reply from the testing mailbox is matched to the test instructor by its email
-- thread (WF4 passes the thread). pgTAP 760.

-- The old form without the thread goes, so a call that names its arguments has one function to choose.
drop function if exists public.record_inbound_message(text, text, text, text, text, timestamptz, text);

create or replace function public.set_domain_status(p_domain_id uuid, p_status text)
returns void language plpgsql security definer set search_path = ''
as $$
declare d public.domain;
  v_msgs int := 0;
  v_reqs int := 0;
begin
  perform private.require_team();
  select * into d from public.domain where id = p_domain_id for update;
  if d.id is null then raise exception 'Domain not found.' using errcode = '22023'; end if;
  if d.status = p_status then return; end if;
  -- Owner, 23 November 2026: what is missing is said exactly, and nothing changes.
  if jsonb_array_length(public.domain_status_problems(p_domain_id, p_status)) > 0 then
    raise exception '%', (select string_agg(x ->> 'text', ' ') from jsonb_array_elements(public.domain_status_problems(p_domain_id, p_status)) x)
      using errcode = '22023';
  end if;
  perform set_config('app.suppress_setup_log', 'on', true);
  update public.domain set status = p_status,
         test_clock_at = case when p_status = 'Test' or (p_status = 'Paused' and status = 'Test') then test_clock_at end
   where id = p_domain_id;
  perform set_config('app.suppress_setup_log', 'off', true);
  -- Decision 333: back to Draft, nothing waiting may still reach an instructor.
  if p_status = 'Draft' then
    update public.message set status = 'Cancelled',
           last_error = 'Cancelled before sending: ' || d.name || ' went back to Draft.'
     where domain_id = d.id and audience = 'Instructor' and status in ('Scheduled', 'Pending');
    get diagnostics v_msgs = row_count;
    -- Finding 39: open time change requests too; nothing is sent (the messages above are already cancelled).
    update public.request r set status = 'Withdrawn', close_reason = 'Domain set to Draft', answered_at = null
     where r.kind in ('Outreach', 'TimeChange') and r.status in ('Queued', 'Sent', 'Reminded')
       and r.module_week_id in (select w.id from public.module_week w where w.domain_id = d.id);
    get diagnostics v_reqs = row_count;
  end if;
  perform private.log_event('Setup changes',
    case p_status when 'Live' then 'Went live' when 'Test' then 'Testing turned on' when 'Paused' then 'Domain paused'
                  else 'Moved back to Draft' end,
    'domain', d.id, jsonb_build_object('status', d.status), jsonb_build_object('status', p_status),
    case when v_msgs + v_reqs > 0 then v_msgs || ' messages to instructors cancelled before sending, ' || v_reqs || ' open requests withdrawn.' end, d.id);
end;
$$;

create or replace function public.record_inbound_message(p_channel text, p_from text, p_subject text, p_body text,
  p_external_id text, p_received_at timestamptz default null, p_summary text default null, p_thread_id text default null)
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

revoke all on function public.record_inbound_message(text, text, text, text, text, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.record_inbound_message(text, text, text, text, text, timestamptz, text, text) to service_role;
