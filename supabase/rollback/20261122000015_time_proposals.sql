-- Rollback of 20261122000015_time_proposals.sql (decision 302). Removes proposed times (the classes stay where they
-- are now), the previous times of moved classes, the TimeProposal task type and the templates M18 to M20, and restores
-- the answers, the pages, the checks and the templates as they were, copied byte for byte from the migrations that
-- defined them last.

drop function if exists public.decide_time_proposal(uuid, boolean, text, boolean, text);
drop function if exists public.time_proposal_preview(uuid);
drop function if exists private.proposal_check(uuid);

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
  -- SEC 8: a link closes when its classes are over, and every link expires after 90 days.
  if lnk.created_at < now() - interval '90 days'
     or exists (select 1 from public.module_week mw where mw.id = r.module_week_id and mw.status = 'Completed') then
    return private.page_message('Link closed', 'This link has closed. If you need anything, reply in your Discord channel or by email.');
  end if;
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
  -- SEC 8: a link closes when its classes are over, and every link expires after 90 days.
  if w.status = 'Completed' or lnk.created_at < now() - interval '90 days' then
    return private.page_message('Link closed', 'This link has closed. If you need anything, reply in your Discord channel or by email.', v_details);
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

drop function if exists private.create_time_proposal(text, jsonb);
drop function if exists private.proposal_form_fields(uuid);
drop function if exists private.zone_name(text);

create or replace function private.move_class(p_class uuid, p_start timestamptz, p_end timestamptz)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare
  c public.class_session;
  w public.module_week;
  v_booking uuid;
begin
  select * into c from public.class_session where id = p_class for update;
  if p_end <= p_start then raise exception 'The class must end after it starts.' using errcode = '22023'; end if;
  if c.starts_at = p_start and c.ends_at = p_end then return false; end if;
  update public.class_session set starts_at = p_start, ends_at = p_end where id = p_class;
  select * into w from public.module_week where id = c.module_week_id;
  perform private.log_event('Team actions', 'Class time changed', 'class_session', p_class,
    jsonb_build_object('starts_at', c.starts_at, 'ends_at', c.ends_at, 'shown', private.fmt_class_range(c.starts_at, c.ends_at, c.region)),
    jsonb_build_object('starts_at', p_start, 'ends_at', p_end, 'shown', private.fmt_class_range(p_start, p_end, c.region)), null,
    w.domain_id, w.module_id, w.id, p_class);
  select b.id into v_booking from public.booking b where b.module_week_id = w.id and b.status = 'Active';
  if v_booking is not null then
    begin
      update public.booking_slot set time_range = tstzrange(p_start, p_end, '[)') where booking_id = v_booking and class_id = p_class;
    exception when exclusion_violation then
      return true;
    end;
  end if;
  return false;
end;
$$;

create or replace function private.buttons(p_request uuid, p_answers text[])
returns jsonb language sql volatile security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', private.answer_label(a),
           'answer', case when a = 'CantMakeItAnymore' then 'CantMakeIt' when a = 'NeedMoreHelp' then 'NeedHelp' else a end,
           'url', private.link_for(p_request, case when a = 'CantMakeItAnymore' then 'CantMakeIt' when a = 'NeedMoreHelp' then 'NeedHelp' else a end))
         order by o), '[]'::jsonb)
    from unnest(p_answers) with ordinality as x(a, o);
$$;

create or replace function private.answer_label(p_answer text)
returns text language sql immutable set search_path = ''
as $$
  select case p_answer
    when 'Yes' then '✅ Yes, I can teach'
    when 'No' then '❌ No, I can''t'
    when 'NeedHelp' then '🙋 Need help'
    when 'CantMakeIt' then 'Can''t make it'
    when 'CantMakeItAnymore' then 'Can''t make it anymore'
    when 'AllSet' then '👍 All set'
    when 'StillWorks' then '✅ Still works'
    when 'DoesntWork' then '❌ Doesn''t work'
    when 'GotIt' then '✅ Got it'
    when 'OwnerAllGood' then '👍 All good'
    when 'OwnerNeedHelp' then '🙋 Need help'
    when 'NeedMoreHelp' then '🙋 Need more help'
    else p_answer end;
$$;

create or replace function private.week_problems(p_mw uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  w public.module_week;
  v jsonb := '[]';
  v_person uuid;
  v_booked boolean;
  v_name text;
  v_status text;
  v_limit int;
  v_month_classes int;
  c record;
  v_clash text;
  v_gone record;
  v_now_name text;
begin
  select * into w from public.module_week where id = p_mw;
  if w.id is null or w.status in ('Cancelled', 'Completed') then return '[]'; end if;
  select b.instructor_id into v_person from public.booking b where b.module_week_id = p_mw and b.status = 'Active';
  v_booked := v_person is not null;
  if not v_booked then
    select r.instructor_id into v_person from public.request r
     where r.module_week_id = p_mw and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded');
  end if;
  select i.full_name, i.status, i.monthly_class_limit into v_name, v_status, v_limit
    from public.instructor i where i.id = v_person;

  for c in select * from public.class_session where module_week_id = p_mw and status = 'Planned' order by starts_at loop
    v := v || coalesce((
      select jsonb_agg(case
               when x ->> 'code' = 'cohort_holiday' and c.holiday_kept_on = (c.starts_at at time zone private.region_tz(c.region))::date
                 then x || jsonb_build_object('class_id', c.id, 'level', 'Information',
                        'text', (x ->> 'text') || ' Kept: ' || rtrim(c.holiday_kept_reason, '.') || '.', 'fixes', '[]'::jsonb)
               else x || jsonb_build_object('class_id', c.id, 'fixes',
                        case x ->> 'code' when 'holiday' then '["move_class", "cancel_class", "keep"]'::jsonb
                                          when 'cohort_holiday' then '["move_class", "cancel_class", "keep_with_reason"]'::jsonb
                                          when 'in_break' then '["move_class", "cancel_class"]'::jsonb
                                          else '["move_class", "keep"]'::jsonb end) end)
        from jsonb_array_elements(private.class_warnings(w.domain_id, w.cohort_id, c.starts_at, c.ends_at, p_mw, c.title, c.region)) x
       where x ->> 'code' <> 'short_notice'), '[]');
    if v_person is not null then
      v_clash := private.clash_text(v_person, c.starts_at, c.ends_at, c.region, p_mw);
      if v_clash is not null then
        v := v || jsonb_build_array(jsonb_build_object('code', 'clash', 'level', 'Block', 'class_id', c.id,
               'instructor_id', v_person, 'text', v_name || ' is in two classes at once. ' || v_clash || '.',
               'fixes', '["ask_next", "move_class", "share_class"]'::jsonb));
      end if;
      v := v || coalesce((
        select jsonb_agg(x || jsonb_build_object('class_id', c.id, 'fixes',
                 case x ->> 'code' when 'unavailable' then
                        case when v_booked then '["release_and_ask_next"]'::jsonb else '["ask_next"]'::jsonb end
                      else '["move_class", "ask_next"]'::jsonb end))
          from jsonb_array_elements(private.instructor_warnings(w.domain_id, v_person, c.starts_at, c.ends_at, c.region,
                                                                case when v_booked then c.id end, c.title)) x), '[]');
    end if;
  end loop;

  if v_person is not null and v_limit is not null then
    if v_booked then
      select count(*)::int into v_month_classes
        from public.booking_slot s join public.class_session c2 on c2.id = s.class_id
       where s.instructor_id = v_person and s.active and c2.status <> 'Cancelled'
         and date_trunc('month', c2.starts_at at time zone private.region_tz(c2.region))
           = date_trunc('month', w.first_class_at at time zone private.region_tz(private.week_region(w.id)));
    end if;
    if (v_booked and v_month_classes > v_limit) or (not v_booked and private.instructor_soft_warning(v_person, p_mw) is not null) then
      v := v || jsonb_build_array(jsonb_build_object('code', 'monthly_limit', 'level', 'Warning', 'instructor_id', v_person,
             'text', v_name || ' is over their limit of ' || v_limit || ' classes a month.',
             'fixes', '["ask_next", "keep"]'::jsonb));
    end if;
  end if;
  if v_booked and v_status in ('Inactive', 'Archived') then
    v := v || jsonb_build_array(jsonb_build_object('code', 'not_in_use', 'level', 'Warning', 'instructor_id', v_person,
           'text', v_name || ' is ' || lower(v_status) || ' but still confirmed for this class week.',
           'fixes', '["release_and_ask_next", "keep"]'::jsonb));
  end if;

  -- The last instructor who gave way to a sooner class, while this week is still looking.
  if not v_booked then
    select r.instructor_id, i.full_name into v_gone
      from public.request r join public.instructor i on i.id = r.instructor_id
     where r.module_week_id = p_mw and r.kind = 'Outreach' and r.status = 'Withdrawn' and r.close_reason = 'Sooner class'
     order by r.created_at desc limit 1;
    if v_gone.instructor_id is not null then
      v_now_name := case when v_person is not null then v_name end;
      v := v || jsonb_build_array(jsonb_build_object('code', 'sooner_class_first', 'level', 'Information',
             'instructor_id', v_gone.instructor_id,
             'text', v_gone.full_name || ' is busy with a sooner class at the same time'
                     || coalesce(', so ' || v_now_name || ' is asked instead.', '.'),
             'fixes', '[]'::jsonb));
    end if;
  end if;

  -- One line per problem: a full day or the monthly limit is the same problem for each class of the day.
  return coalesce((
    select jsonb_agg(e order by ord)
      from (select distinct on (e ->> 'code', e ->> 'text') e, ord
              from jsonb_array_elements(v) with ordinality as t(e, ord)
             order by e ->> 'code', e ->> 'text', ord) s), '[]');
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
      'body', E'Thank you, {first_name}. You are confirmed for {module} 🎉\n\n{classes}{help}\n\nYour contact: {contact}',
      'required', jsonb_build_array('module', 'classes')),
    'M5', jsonb_build_object('name', 'Class time change', 'subject', '{module} moved: does this still work?',
      'body', E'{module} moved to new times:\n\n{classes}\n\nDoes this still work?{reply_by}',
      'required', jsonb_build_array('module', 'classes')),
    'M6', jsonb_build_object('name', 'Reminder before class', 'subject', '{module} is in {days} days: all set?',
      'body', E'{module} is {days} days away ({first_class}). Anything you need?\n\n{classes}{help}',
      'required', jsonb_build_array('module', 'classes')),
    'M7', jsonb_build_object('name', 'Final reminder before class', 'subject', '{module} is on {weekday}',
      'body', E'{module} is on {first_class}.\n\n{classes}{help}\n\nAll set?',
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
      'required', jsonb_build_array('module', 'classes')),
    'M17', jsonb_build_object('name', 'Classes moved for a break', 'subject', 'Your classes moved: do they still work?',
      'body', E'{text}

{classes}

Do these still work? Answer for each class week with the buttons.{reply_by}',
      'required', jsonb_build_array('classes')));
$$;

delete from public.message_template where template_id in ('M18', 'M19', 'M20');
delete from public.response_link where answer = 'ProposeTime';
drop table if exists public.time_proposal;
alter table public.class_session drop column if exists previous_starts_at, drop column if exists previous_ends_at,
  drop column if exists moved_at;
delete from public.attention_item where type = 'TimeProposal';
alter table public.attention_item drop constraint attention_item_type_check;
alter table public.attention_item add constraint attention_item_type_check check (type in (
    'RankingExhausted', 'ClassAtRisk', 'TypedReply', 'HelpRequest', 'ReadinessFailed',
    'ChecklistOverdue', 'MessageFailed', 'LateReply', 'ScheduleLow', 'TimeChangeNotConfirmed',
    'CheckInNoReply', 'ThinBench', 'UnverifiedInRanking', 'OwnerCheckIn', 'Other'));
