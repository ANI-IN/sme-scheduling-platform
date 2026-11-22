-- Release 3, M9 (decision 302): an instructor proposes another time; Ops accepts or rejects.
--
-- The request to teach (M1, M2) and the time change message (M5, and M17 for each class week) get a third answer,
-- "Propose another time". Its page shows each class of the class week with its date and times in the class's own
-- time zone; the instructor changes any of them and can add a note. Sending it stores a proposal and changes nothing
-- confirmed: the request stays open (its reply time is extended by up to 48 hours, so it does not run out while Ops
-- decides), a task goes to the operations team, and the instructor is told the team will reply.
--
-- Ops sees the proposal checked with every schedule check (private.week_problems) as if the classes had moved, the
-- same way as the break preview: clashes and the instructor's other bookings, the cohort's other classes, holidays,
-- cohort holidays, odd hours, unavailable dates, and times that do not exist. A Block can't be accepted; a new Warning
-- needs a reason. Accepting moves the classes (for the whole cohort) and either confirms the instructor at the new
-- time (a request to teach) or keeps them confirmed without asking them again (a time change). Rejecting tells them
-- the time stays, with the buttons of their request again. A proposal made before the class times changed again can't
-- be accepted.
--
-- Every moved class now keeps its previous time, so the class week and the Schedule board can show "Moved" with the old
-- and new time, and "Waiting for the instructor to confirm the new time" until the confirmed instructor answers.

alter table public.attention_item drop constraint attention_item_type_check;
alter table public.attention_item add constraint attention_item_type_check check (type in (
    'RankingExhausted', 'ClassAtRisk', 'TypedReply', 'HelpRequest', 'ReadinessFailed',
    'ChecklistOverdue', 'MessageFailed', 'LateReply', 'ScheduleLow', 'TimeChangeNotConfirmed',
    'CheckInNoReply', 'ThinBench', 'UnverifiedInRanking', 'OwnerCheckIn', 'Other', 'TimeProposal'));

-- The time a class had before it last moved.
alter table public.class_session add column previous_starts_at timestamptz, add column previous_ends_at timestamptz,
  add column moved_at timestamptz;

create table public.time_proposal (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.request (id) on delete cascade,
  module_week_id uuid not null references public.module_week (id) on delete cascade,
  domain_id uuid not null references public.domain (id) on delete cascade,
  instructor_id uuid not null references public.instructor (id) on delete cascade,
  -- [{class_id, title, region, from, to, starts_at, ends_at}]: each class, as it is and as proposed.
  proposed jsonb not null,
  note text check (length(note) <= 500),
  status text not null default 'Pending' check (status in ('Pending', 'Accepted', 'Rejected', 'Superseded')),
  time_version int not null,
  decided_at timestamptz,
  decided_by uuid,
  decision_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index time_proposal_one_pending on public.time_proposal (module_week_id) where status = 'Pending';
create index time_proposal_request_idx on public.time_proposal (request_id);
create index time_proposal_domain_idx on public.time_proposal (domain_id);
create index time_proposal_instructor_idx on public.time_proposal (instructor_id);
create trigger time_proposal_touch before update on public.time_proposal for each row execute function private.touch_row();
alter table public.time_proposal enable row level security;
revoke all on public.time_proposal from anon;
grant all on public.time_proposal to service_role;
grant select on public.time_proposal to authenticated;
create policy time_proposal_team_read on public.time_proposal for select to authenticated using (private.is_team_user());

-- private.answer_label: Propose another time (was 20261110000002_messaging.sql).
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
    when 'ProposeTime' then '🕒 Propose another time'
    else p_answer end;
$$;

-- private.buttons: the request to teach and the time change message also offer Propose another time (was 20261110000002_messaging.sql).
create or replace function private.buttons(p_request uuid, p_answers text[])
returns jsonb language sql volatile security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', private.answer_label(a),
           'answer', case when a = 'CantMakeItAnymore' then 'CantMakeIt' when a = 'NeedMoreHelp' then 'NeedHelp' else a end,
           'url', private.link_for(p_request, case when a = 'CantMakeItAnymore' then 'CantMakeIt' when a = 'NeedMoreHelp' then 'NeedHelp' else a end))
         order by o), '[]'::jsonb)
    from unnest(p_answers || case when p_answers = array['Yes', 'No'] or p_answers = array['StillWorks', 'DoesntWork']
                               then array['ProposeTime'] else '{}'::text[] end) with ordinality as x(a, o);
$$;

-- private.move_class: a moved class keeps its previous time (was 20261112000002_r2_regions_time_zones.sql).
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
  update public.class_session set starts_at = p_start, ends_at = p_end, previous_starts_at = c.starts_at,
         previous_ends_at = c.ends_at, moved_at = now() where id = p_class;
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

/** "US Pacific time" or "India time". */
create or replace function private.zone_name(p_region text)
returns text language sql immutable set search_path = ''
as $$ select case when p_region = 'India' then 'India time' else 'US Pacific time' end; $$;

-- The proposal form: each class of the class week with its date, start and end in its own time zone, and a note.
create or replace function private.proposal_form_fields(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(string_agg(
           '<fieldset><legend>' || private.html_escape(c.title) || '</legend>'
           || '<input type="hidden" name="c_' || n || '" value="' || c.id || '">'
           || '<label>Date <input type="date" name="d_' || n || '" required style="font:inherit;padding:6px" value="'
           || to_char(c.starts_at at time zone private.region_tz(c.region), 'YYYY-MM-DD') || '"></label>'
           || '<label>Starts <input type="time" name="s_' || n || '" required style="font:inherit;padding:6px" value="'
           || to_char(c.starts_at at time zone private.region_tz(c.region), 'HH24:MI') || '"></label>'
           || '<label>Ends <input type="time" name="e_' || n || '" required style="font:inherit;padding:6px" value="'
           || to_char(c.ends_at at time zone private.region_tz(c.region), 'HH24:MI') || '"></label>'
           || '<p class="muted">' || private.zone_name(c.region) || '</p></fieldset>', '' order by n), '')
      || '<label for="note"><strong>Note for the team</strong> (optional)</label>'
      || '<textarea id="note" name="note" maxlength="500"></textarea>'
    from (select c.*, row_number() over (order by c.starts_at, c.id) as n
            from public.class_session c where c.module_week_id = p_mw and c.status = 'Planned') c;
$$;

-- public.response_page_text: the Propose another time page (was 20261122000006_security_data_findings.sql).
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

  if lnk.answer = 'ProposeTime' then
    if not v_open or w.id is null or r.kind not in ('Outreach', 'TimeChange') then
      return private.page_message('Request closed', 'This request has closed, so nothing is needed from you. Thank you!', v_details);
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

-- public.submit_response_page_text: sending a proposed time (was 20261122000006_security_data_findings.sql).
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

-- Stores the instructor's proposed time from the page. Nothing confirmed changes; the request stays open.
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
    'message', 'Thanks! The team checks your proposed time with the cohort and replies to you soon. Until then, nothing changes.');
end;
$$;

-- A proposal checked as if its classes had moved: the classes are moved inside a block that is always rolled back,
-- so every check reads them at the proposed times. Each problem says whether the move creates it.
create or replace function private.proposal_check(p_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  p public.time_proposal;
  r public.request;
  w public.module_week;
  x jsonb;
  v_before jsonb;
  v_keys text[];
  v_problems jsonb;
  v_blocks text[] := '{}';
  v_out jsonb;
  v_clash boolean := false;
begin
  select * into p from public.time_proposal where id = p_id;
  select * into r from public.request where id = p.request_id;
  select * into w from public.module_week where id = p.module_week_id;
  if p.status <> 'Pending' then v_blocks := v_blocks || 'This proposal was already decided.'::text; end if;
  if w.status in ('Cancelled', 'Completed') then v_blocks := v_blocks || 'This class week is no longer scheduled.'::text; end if;
  if r.status not in ('Sent', 'Reminded') then
    v_blocks := v_blocks || ('This request has closed (' || coalesce(r.close_reason, r.status) || '), so the proposal can''t be accepted. Reject it to tell them.');
  end if;
  if w.time_version <> p.time_version then
    v_blocks := v_blocks || 'The class times changed after this proposal was made, so it can''t be accepted. Reject it, or change the times on the class week.'::text;
  end if;
  if r.kind = 'TimeChange' and not exists (select 1 from public.booking b where b.id = r.booking_id and b.status = 'Active') then
    v_blocks := v_blocks || 'They are no longer confirmed for this class week.'::text;
  end if;
  v_before := private.week_problems(w.id);
  v_keys := array(select (e ->> 'code') || ':' || coalesce(e ->> 'class_id', '') || ':' || coalesce(e ->> 'instructor_id', '')
                    from jsonb_array_elements(v_before) e);
  begin
    for x in select * from jsonb_array_elements(p.proposed) loop
      if exists (select 1 from public.class_session c where c.id = (x ->> 'class_id')::uuid and c.status = 'Planned') then
        v_clash := private.move_class((x ->> 'class_id')::uuid, (x ->> 'starts_at')::timestamptz, (x ->> 'ends_at')::timestamptz) or v_clash;
      else
        v_blocks := v_blocks || ((x ->> 'title') || ' was cancelled after this proposal was made.');
      end if;
    end loop;
    if exists (select 1 from public.class_session a join public.class_session b on a.module_week_id = b.module_week_id and a.id < b.id
                where a.module_week_id = w.id and a.status = 'Planned' and b.status = 'Planned'
                  and tstzrange(a.starts_at, a.ends_at, '[)') && tstzrange(b.starts_at, b.ends_at, '[)')) then
      v_blocks := v_blocks || 'Two classes of this class week would overlap at the proposed times.'::text;
    end if;
    select coalesce(jsonb_agg(e || jsonb_build_object('new',
             not ((e ->> 'code') || ':' || coalesce(e ->> 'class_id', '') || ':' || coalesce(e ->> 'instructor_id', '') = any (v_keys)))), '[]')
      into v_problems from jsonb_array_elements(private.week_problems(w.id)) e
     where e ->> 'code' not in ('proposed_time', 'waiting_new_time');
    v_out := jsonb_build_object('problems', v_problems, 'slot_clash', v_clash);
    raise exception 'proposal check' using errcode = 'P0B02';
  exception when sqlstate 'P0B02' then
    null;
  end;
  if (v_out ->> 'slot_clash')::boolean and not exists (select 1 from jsonb_array_elements(v_out -> 'problems') e where e ->> 'code' = 'clash') then
    v_blocks := v_blocks || 'The proposed time clashes with another class of the instructor.'::text;
  end if;
  return jsonb_build_object('id', p.id, 'status', p.status, 'proposed', p.proposed, 'note', p.note,
    'kind', case when r.kind = 'TimeChange' then 'Confirmed' else 'Asked' end,
    'instructor', (select full_name from public.instructor where id = p.instructor_id),
    'blocks', to_jsonb(v_blocks) || coalesce((select jsonb_agg(e ->> 'text') from jsonb_array_elements(v_out -> 'problems') e
                                               where e ->> 'level' = 'Block' and (e ->> 'new')::boolean), '[]'),
    'warnings', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_out -> 'problems') e
                           where e ->> 'level' in ('Warning', 'Information') and (e ->> 'new')::boolean), '[]'));
end;
$$;

-- For the class week: the proposal waiting for a decision, with its checks.
create or replace function public.time_proposal_preview(p_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if not exists (select 1 from public.time_proposal where id = p_id) then
    raise exception 'This proposal no longer exists.' using errcode = '22023';
  end if;
  return private.proposal_check(p_id);
end;
$$;

-- Accept (move the classes, and confirm the instructor or keep them confirmed) or reject (tell them the time stays).
create or replace function public.decide_time_proposal(p_id uuid, p_accept boolean, p_note text default null,
  p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  p public.time_proposal;
  r public.request;
  w public.module_week;
  x jsonb;
  v_check jsonb;
  v_now timestamptz;
  v_tv int;
  v_res jsonb;
  v_clash boolean := false;
  v_name text;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  perform private.require_team();
  select * into p from public.time_proposal where id = p_id for update;
  if p.id is null then raise exception 'This proposal no longer exists.' using errcode = '22023'; end if;
  if p.status <> 'Pending' then raise exception 'This proposal was already decided.' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('plan:' || p.domain_id::text));
  select * into w from public.module_week where id = p.module_week_id for update;
  select * into r from public.request where id = p.request_id for update;
  v_now := private.domain_now(p.domain_id);
  select full_name into v_name from public.instructor where id = p.instructor_id;

  if not p_accept then
    update public.time_proposal set status = 'Rejected', decided_at = now(), decided_by = private.current_team_member_id(),
           decision_note = v_note where id = p.id;
    perform private.resolve_attention('proposal:' || p.id, 'Proposed time rejected');
    -- They can propose another time from the same link.
    update public.response_link set used_at = null where request_id = r.id and answer = 'ProposeTime';
    perform private.queue_instructor_message('M20', p.instructor_id, w.id, r.id, v_now,
      case when r.status in ('Sent', 'Reminded') and w.status not in ('Cancelled', 'Completed')
           then private.buttons(r.id, case when r.kind = 'TimeChange' then array['StillWorks', 'DoesntWork'] else array['Yes', 'No'] end)
           else '[]'::jsonb end,
      jsonb_build_object('text', coalesce(E'\n\n' || v_note, ''),
        'deadline', case when r.status in ('Sent', 'Reminded') then private.fmt_local(r.deadline_at, private.week_region(w.id)) end),
      false, 'proposal:' || p.id);
    perform private.log_event('Team actions', 'Proposed time rejected: ' || v_name, 'time_proposal', p.id, null, null, v_note,
      w.domain_id, w.module_id, w.id, null, p.instructor_id);
    perform private.queue_deliver('proposal rejected');
    return jsonb_build_object('ok', true, 'decided', 'Rejected');
  end if;

  v_check := private.proposal_check(p.id);
  if jsonb_array_length(v_check -> 'blocks') > 0 then
    return jsonb_build_object('ok', false, 'blocks', v_check -> 'blocks', 'warnings', v_check -> 'warnings');
  end if;
  if exists (select 1 from jsonb_array_elements(v_check -> 'warnings') e where e ->> 'level' = 'Warning') and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'blocks', '[]'::jsonb, 'warnings', v_check -> 'warnings');
  end if;
  perform private.log_accepted_warnings(v_check -> 'warnings', p_reason, w.domain_id, w.module_id, w.id);
  for x in select * from jsonb_array_elements(p.proposed) order by (x ->> 'starts_at')::timestamptz desc loop
    v_clash := private.move_class((x ->> 'class_id')::uuid, (x ->> 'starts_at')::timestamptz, (x ->> 'ends_at')::timestamptz) or v_clash;
  end loop;
  if v_clash then
    raise exception 'The proposed time clashes with another class of %.', v_name using errcode = '23P01';
  end if;
  update public.module_week set time_version = time_version + 1 where id = w.id returning time_version into v_tv;
  update public.time_proposal set status = 'Accepted', decided_at = now(), decided_by = private.current_team_member_id(),
         decision_note = v_note where id = p.id;
  perform private.resolve_attention('proposal:' || p.id, 'Proposed time accepted');
  if r.kind = 'TimeChange' then
    -- They proposed it, so they are not asked again about it.
    update public.booking set time_version_confirmed = v_tv where id = r.booking_id;
    update public.request set status = 'Accepted', answer = 'ProposeTime', answered_at = v_now, time_version = v_tv where id = r.id;
    perform private.resolve_attention('timechange:' || w.id, 'The instructor proposed the new time');
    perform private.queue_instructor_message('M19', p.instructor_id, w.id, r.id, v_now, '[]', '{}', false, 'proposal:' || p.id);
  else
    update public.request set time_version = v_tv where id = r.id;
    v_res := private.confirm_booking(w.id, p.instructor_id, r.id, 'Instructor', v_now);
    if not coalesce((v_res ->> 'ok')::boolean, false) then
      raise exception 'Could not confirm %: %', v_name, coalesce(v_res ->> 'message', 'unknown reason') using errcode = '22023';
    end if;
    update public.request set answer = 'ProposeTime' where id = r.id;
  end if;
  -- Anyone else confirmed at the old time is asked about the new one as usual (nobody, for a request to teach).
  perform private.log_event('Team actions', 'Proposed time accepted: ' || v_name, 'time_proposal', p.id, null,
    jsonb_build_object('proposed', p.proposed), v_note, w.domain_id, w.module_id, w.id, null, p.instructor_id);
  perform private.queue_deliver('proposal accepted');
  return jsonb_build_object('ok', true, 'decided', 'Accepted', 'confirmed', r.kind <> 'TimeChange');
end;
$$;

-- private.week_problems: a proposed time waiting for Ops, and a confirmed instructor not yet answering about a moved class (was 20261122000014_cohort_breaks.sql).
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

  -- A proposed time waiting for a decision.
  select tp.instructor_id, i.full_name into v_gone from public.time_proposal tp join public.instructor i on i.id = tp.instructor_id
   where tp.module_week_id = p_mw and tp.status = 'Pending';
  if v_gone.instructor_id is not null then
    v := v || jsonb_build_array(jsonb_build_object('code', 'proposed_time', 'level', 'Information', 'instructor_id', v_gone.instructor_id,
           'text', v_gone.full_name || ' proposed another time.', 'fixes', '["accept_proposal", "reject_proposal"]'::jsonb));
  end if;
  -- A class moved and the confirmed instructor has not answered yet.
  if v_booked and exists (select 1 from public.request q where q.module_week_id = p_mw and q.kind = 'TimeChange'
                            and q.status in ('Queued', 'Sent', 'Reminded')) then
    v := v || jsonb_build_array(jsonb_build_object('code', 'waiting_new_time', 'level', 'Information', 'instructor_id', v_person,
           'text', 'Waiting for ' || v_name || ' to confirm the new time.', 'fixes', '[]'::jsonb));
  end if;

  -- One line per problem: a full day or the monthly limit is the same problem for each class of the day.
  return coalesce((
    select jsonb_agg(e order by ord)
      from (select distinct on (e ->> 'code', e ->> 'text') e, ord
              from jsonb_array_elements(v) with ordinality as t(e, ord)
             order by e ->> 'code', e ->> 'text', ord) s), '[]');
end;
$$;

-- private.template_defaults: M18 to M20 for proposed times (was 20261122000014_cohort_breaks.sql).
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
      'required', jsonb_build_array('classes')),
    'M18', jsonb_build_object('name', 'Proposed time received', 'subject', '{module}: we got your proposed time',
      'body', 'Thanks for proposing another time for {module}. The team checks it with the cohort and replies to you soon. Until then, nothing changes.',
      'required', jsonb_build_array('module')),
    'M19', jsonb_build_object('name', 'Proposed time accepted', 'subject', '{module}: your proposed time is accepted',
      'body', E'Good news: {module} moved to the time you proposed, and you stay confirmed.\n\n{classes}{help}',
      'required', jsonb_build_array('module', 'classes')),
    'M20', jsonb_build_object('name', 'Proposed time not possible', 'subject', '{module}: we kept the original time',
      'body', E'Thanks for proposing another time for {module}. We could not move the class, so the time stays:\n\n{classes}{text}\n\nPlease answer with the buttons below.{reply_by}',
      'required', jsonb_build_array('module', 'classes')));
$$;

revoke execute on function private.zone_name(text) from public, anon, authenticated;
revoke execute on function private.proposal_form_fields(uuid) from public, anon, authenticated;
revoke execute on function private.create_time_proposal(text, jsonb) from public, anon, authenticated;
revoke execute on function private.proposal_check(uuid) from public, anon, authenticated;
revoke execute on function public.time_proposal_preview(uuid) from public, anon;
revoke execute on function public.decide_time_proposal(uuid, boolean, text, boolean, text) from public, anon;
grant execute on function public.time_proposal_preview(uuid) to authenticated, service_role;
grant execute on function public.decide_time_proposal(uuid, boolean, text, boolean, text) to authenticated, service_role;
