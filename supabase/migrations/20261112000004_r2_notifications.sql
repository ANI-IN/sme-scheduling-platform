-- Release 2 Milestone D: notifications.
-- Instructors: a post in their channel for the class's domain, tagging them, plus email. Without a
-- channel: a direct message plus email. The confirmation also tags every owner and the operations
-- team in the instructor's channel, and goes to the instructor by direct message and email too.
-- Team members: tagged in posts, plus a direct message each (or email when they have no Discord).
-- unique_key on every message keeps all of this free of duplicates.
-- A message that keeps failing: email to the operations team plus a task saying exactly what to fix.

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
  v_chan text;
  v_team text[] := '{}';
  v_dm boolean;
  v_targets text[];
  v_t text;
begin
  select * into i from public.instructor where id = p_instructor;
  if p_mw is not null then
    select w.domain_id, w.time_version into v_domain, v_tv from public.module_week w where w.id = p_mw;
  end if;
  if p_request is not null then
    select r.time_version into v_tv from public.request r where r.id = p_request;
  end if;
  select * into d from public.domain where id = v_domain;
  -- The instructor's channel in this domain (Release 2: one channel per domain).
  -- An older single channel (from a channel link) is used when no channel is chosen for this domain.
  -- A message without a domain (the contact check) uses the instructor's first channel.
  v_chan := coalesce((select ic.channel_id from public.instructor_channel ic
                       where ic.instructor_id = p_instructor and (ic.domain_id = v_domain or v_domain is null)
                       order by ic.created_at limit 1),
                     i.discord_channel_id);
  v_test := private.is_test_domain(d.id);
  v_channels := 'Both';
  v_r := private.render_instructor(p_template, p_mw, p_instructor, p_extra);
  if v_test then
    v_prefix := '[TEST → would go to ' || i.full_name || '] ';
  end if;
  v_send := private.instructor_send_time(v_domain, p_now, p_urgent, coalesce(private.week_region(p_mw), 'US'));

  select coalesce(string_agg(format('<a href="%s" style="display:inline-block;margin:4px 8px 4px 0;padding:10px 16px;background:#1f6feb;color:#fff;border-radius:6px;text-decoration:none;font-weight:600">%s</a>',
                                    private.html_escape(b ->> 'url'), private.html_escape(b ->> 'label')), ''), '')
    into v_btn_html from jsonb_array_elements(p_buttons) b;

  -- Where the Discord copy goes: the test channel (testing), the instructor's channel, or a direct message.
  v_dm := not v_test and v_chan is null and i.discord_user_id is not null;
  -- The confirmation tags every owner and the operations team in the instructor's channel.
  if p_template = 'M4' and p_mw is not null and not v_test then
    v_team := private.team_discord_ids(array(select distinct x from unnest(
      private.owners_or_leads((select w.module_id from public.module_week w where w.id = p_mw))
      || private.ops_for_week(p_mw)) x));
  end if;
  -- Discord, email, and for a confirmation in a channel also a direct message to the instructor.
  v_targets := array['Discord', 'Email'];
  if p_template = 'M4' and not v_test and v_chan is not null and i.discord_user_id is not null then
    v_targets := array['Discord', 'DM', 'Email'];
  end if;

  foreach v_t in array v_targets loop
    v_ch := case v_t when 'DM' then 'Discord' else v_t end;
    continue when p_only_channel is not null and v_ch <> p_only_channel;
    continue when v_ch = 'Discord' and v_channels = 'EmailOnly';
    continue when v_ch = 'Email' and v_channels = 'DiscordOnly';
    continue when v_t = 'Discord' and not v_test and v_chan is null and not v_dm;
    continue when v_ch = 'Email' and not v_test and coalesce(i.primary_email, '') = '';
    v_key := p_template || ':' || coalesce(p_request::text, coalesce(p_mw::text, '-') || ':' || p_instructor::text)
             || ':' || coalesce(v_tv, 0) || ':' || v_t || coalesce(nullif(':' || p_key_suffix, ':'), '');
    if v_ch = 'Discord' then
      v_text := v_prefix || 'Hi ' ||
                case when i.discord_user_id is not null and (not v_test or i.is_test) then '<@' || i.discord_user_id || '>'
                     else (v_r ->> 'first_name') end
                || ' 👋 ' || (v_r ->> 'body')
                || case when v_t = 'Discord' and cardinality(v_team) > 0
                        then E'

Team: ' || (select string_agg('<@' || x || '>', ' ') from unnest(v_team) x) else '' end;
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
      request_id, help_request_id, recipient_label, to_address, discord_channel_id, discord_dm_user_id, mention_user_ids, subject,
      body_text, body_html, buttons, is_test)
    values (
      v_domain, 'Instructor', p_template, v_ch, v_key,
      case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, p_instructor, p_mw,
      p_request, p_help_request, i.full_name,
      case when v_ch = 'Email' then case when v_test then d.test_email else i.primary_email end end,
      case when v_t = 'Discord' then case when v_test then d.test_discord_channel_id when v_dm then null else v_chan end end,
      case when v_t = 'DM' or (v_t = 'Discord' and v_dm) then i.discord_user_id end,
      case when v_ch = 'Discord' and i.discord_user_id is not null and (not v_test or i.is_test)
           then array[i.discord_user_id] || case when v_t = 'Discord' then v_team else '{}' end else '{}' end,
      v_prefix || (v_r ->> 'subject'), v_text, v_html, p_buttons, v_test)
    on conflict (unique_key) where unique_key is not null do nothing;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
  end loop;
  return v_count;
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

  -- 'people': no channel post (the people are already tagged elsewhere), only their own copies below.
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
  end if;

  if p_target in ('alert', 'people', 'email') then
    -- Everyone tagged also gets their own copy: a direct message, or email when they have no Discord.
    -- 'email': email only (used when Discord itself is the problem).
    for t in select * from public.team_member where id = any (coalesce(p_mentions, '{}')) and active loop
      v_ch := case when p_target <> 'email' and t.discord_user_id is not null then 'Discord' else 'Email' end;
      continue when v_ch = 'Email' and coalesce(t.email, '') = '';
      insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before,
        team_member_id, module_week_id, help_request_id, attention_item_id, recipient_label, to_address,
        discord_dm_user_id, subject, body_text, is_test)
      values (p_domain, 'Team', p_template, v_ch, p_key || ':' || t.id || ':copy',
        case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, t.id, p_mw, p_help, p_attention, t.name,
        case when v_ch = 'Email' then t.email end,
        case when v_ch = 'Discord' then t.discord_user_id end,
        v_prefix || p_subject, v_prefix || v_text, v_test)
      on conflict (unique_key) where unique_key is not null do nothing;
      get diagnostics v_n = row_count;
      v_count := v_count + v_n;
    end loop;
  elsif p_target = 'person' then
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
      return jsonb_build_object('ok', false, 'reason', 'stale', 'message', 'The class times changed — please use the latest message.');
    end if;
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
  update public.module_week set status = 'Confirmed', at_risk = false, at_risk_reason = null where id = p_mw;
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
create or replace function private.template_defaults()
returns jsonb language sql immutable set search_path = ''
as $$
  select jsonb_build_object(
    'M1', jsonb_build_object('name', 'Request to teach', 'subject', 'Can you teach {module}? ({first_class})',
      'body', E'Hi {first_name},\n\nCan you teach {module} for the {domain} cohort?\n\n{classes}\n\nPlease reply by {deadline}.',
      'required', jsonb_build_array('module', 'classes', 'deadline')),
    'M2', jsonb_build_object('name', 'Reminder about the request', 'subject', 'Reminder: can you teach {module}?',
      'body', E'Hi {first_name},\n\nA friendly reminder: can you teach {module} for the {domain} cohort?\n\n{classes}\n\nPlease reply by {deadline}.',
      'required', jsonb_build_array('module', 'classes', 'deadline')),
    'M3', jsonb_build_object('name', 'Request closed', 'subject', '{module}: no worries',
      'body', 'No worries. We will check with you next time. (We have closed the request for {module}.)',
      'required', jsonb_build_array('module')),
    'M4', jsonb_build_object('name', 'Confirmation', 'subject', 'You are confirmed for {module} 🎉',
      'body', E'Thank you, {first_name}. You are confirmed for {module} 🎉\n\n{classes}{materials}\n\nYour contact: {contact}',
      'required', jsonb_build_array('module', 'classes')),
    'M5', jsonb_build_object('name', 'Class time change', 'subject', '{module} moved: does this still work?',
      'body', E'{module} moved to new times:\n\n{classes}\n\nDoes this still work?{reply_by}',
      'required', jsonb_build_array('module', 'classes')),
    'M6', jsonb_build_object('name', 'Reminder before class', 'subject', '{module} is in {days} days: all set?',
      'body', E'{module} is {days} days away ({first_class}). Anything you need?\n\n{classes}{materials}',
      'required', jsonb_build_array('module', 'classes')),
    'M7', jsonb_build_object('name', 'Final reminder before class', 'subject', '{module} is on {weekday}',
      'body', E'{module} is on {first_class}.\n\n{classes}{materials}\n\nAll set?',
      'required', jsonb_build_array('module', 'classes')),
    'M8', jsonb_build_object('name', 'Early reminder before class', 'subject', '{module} in {days} days: how is your prep going?',
      'body', E'{module} is {days} days away ({first_class}). How is your prep going?\n\n{classes}',
      'required', jsonb_build_array('module', 'classes')),
    'M9', jsonb_build_object('name', 'Follow up reminder', 'subject', 'Reminder: {module} is coming up',
      'body', 'A quick reminder: {module} is coming up ({first_class}). Please let us know you are all set.',
      'required', jsonb_build_array('module')),
    'M10', jsonb_build_object('name', 'Cancellation received', 'subject', '{module}: thanks for letting us know',
      'body', 'Thanks for letting us know. We will take it from here.', 'required', '[]'::jsonb),
    'M11', jsonb_build_object('name', 'Class cancelled', 'subject', '{module}: class cancelled',
      'body', E'We are sorry, we have had to cancel {what}:\n\n{classes}\n\nThank you for your flexibility. Nothing else is needed from you.',
      'required', jsonb_build_array('classes')),
    'M12', jsonb_build_object('name', 'Request withdrawn', 'subject', '{module}: no longer needed',
      'body', 'Thanks. This one is no longer needed ({module}). No action required.', 'required', jsonb_build_array('module')),
    'M13', jsonb_build_object('name', 'Help request received', 'subject', '{module}: help request received',
      'body', 'Got it. {helper} will reply by {by}.', 'required', jsonb_build_array('helper', 'by')),
    'M14', jsonb_build_object('name', 'Reply to a help request', 'subject', '{module}: reply to your help request',
      'body', E'{text}\n\nFrom {from}', 'required', jsonb_build_array('text')),
    'M15', jsonb_build_object('name', 'Contact check', 'subject', 'Test message from SME Scheduling',
      'body', 'This is a test from SME Scheduling. Please tap the button to confirm you received it.', 'required', '[]'::jsonb),
    'M16', jsonb_build_object('name', 'Release note', 'subject', '{module}: thank you',
      'body', E'Thank you for being ready to teach {module}. Plans have changed, so you are no longer needed for these classes:\n\n{classes}\n\nNothing else is needed from you. We hope to work with you again soon.',
      'required', jsonb_build_array('module', 'classes')));
$$;
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
      v_name || ' says they can''t teach ' || private.mw_label(w.id) || ' — the class has already started',
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
    'At risk: ' || private.mw_label(w.id) || ' — ' || v_reason,
    case when p_restart then 'Outreach has restarted automatically.' else 'Outreach is paused for this week — resume it in the class drawer when ready.' end || coalesce(' ' || p_note, ''),
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

/** What to do about a message that keeps failing, in plain words, from the error Discord or email gave. */
create or replace function private.message_fix(m public.message, p_error text)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  e text := lower(coalesce(p_error, ''));
  v_who text := coalesce(m.recipient_label, 'this person');
  v_chan text := (select '#' || c.name from public.discord_channel c where c.id = m.discord_channel_id);
  v_page text := case when m.audience = 'Instructor' then 'Setup, Instructors' else 'Setup, Team' end;
begin
  if m.channel = 'Email' then
    if e ~ '(invalid|not exist|no such user|bounce|address)' then
      return 'The email address of ' || v_who || ' does not work. Correct it on ' || v_page || '.';
    end if;
    return 'Email could not be sent to ' || v_who || '. Check the email connection on Settings, Connections.';
  end if;
  if m.discord_dm_user_id is not null and m.discord_channel_id is null then
    if e ~ '(50007|cannot send messages to this user)' then
      return v_who || ' does not accept direct messages from the server. Ask them to allow direct messages from server members, '
        || case when m.audience = 'Instructor' then 'or choose a channel for them on ' || v_page || '.' else 'or remove their Discord username on ' || v_page || ' so they get email.' end;
    end if;
    return 'The direct message to ' || v_who || ' failed. Press Check Discord for them on ' || v_page || '.';
  end if;
  if e ~ '(10003|unknown channel|404)' then
    return 'The Discord channel ' || coalesce(v_chan, '') || ' no longer exists. Choose a new channel for ' || v_who || ' on ' || v_page || '.';
  end if;
  if e ~ '(50001|50013|missing access|missing permissions|403)' then
    return 'The bot may not post in ' || coalesce(v_chan, 'this channel')
      || '. In Discord, give the bot''s role View Channels, Send Messages, Embed Links and Read Message History there.';
  end if;
  if e ~ '(401|unauthorized)' then
    return 'The bot''s login (token) is wrong. Whoever looks after the automation must update the Discord bot setting.';
  end if;
  return 'Discord did not accept the message to ' || v_who || ' (' || coalesce(p_error, 'no reason given')
    || '). Check the Discord server on Settings, Connections.';
end;
$$;

/** "Discord (#maya-k)", "Discord direct message" or "Email", for Activity history. */
create or replace function private.message_route(m public.message)
returns text language sql stable security definer set search_path = ''
as $$
  select case
    when m.channel = 'Email' then 'Email'
    when m.discord_channel_id is null and m.discord_dm_user_id is not null then 'Discord direct message'
    else 'Discord' || coalesce(' (#' || (select c.name from public.discord_channel c where c.id = m.discord_channel_id) || ')', '') end;
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
  if m.audience <> 'Admin' then
    perform private.raise_attention(m.domain_id, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
      'Message failed: ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
      private.message_fix(m, p_error) || case when m.channel = 'Discord' then ' Email is still sent.' else ' Discord is still used.' end,
      'msgfail:' || m.id,
      coalesce(nullif(private.domain_role_ids(m.domain_id, 'Ops'), '{}'),
               private.all_operations_ids()),
      v_now, jsonb_build_object('module_week_id', m.module_week_id, 'instructor_id', m.instructor_id, 'message_id', m.id), true, 'T14');
    -- The operations team also gets an email: Discord itself may be what is broken.
    perform private.queue_team_message('T14', m.domain_id, 'email', null,
      coalesce(nullif(private.domain_role_ids(m.domain_id, 'Ops'), '{}'), private.all_operations_ids()),
      'Message failed: what to fix',
      m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || private.message_route(m) || ' failed. '
        || private.message_fix(m, p_error),
      'T14mail:' || m.id, now());
    perform private.queue_team_message('T14', m.domain_id, 'admin', null, '{}', 'Message failed',
      '❗ ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel || ' failed: ' || coalesce(p_error, '?'),
      'T14:' || m.id, now());
  end if;
  return jsonb_build_object('ok', true, 'status', 'Failed');
end;
$$;


