-- Rollback of 20261122000014_cohort_breaks.sql (decision 301). Removes cohort breaks, program breaks and cohort
-- holidays (the classes stay where they are now) and the M17 template, and restores the checks, the nightly snapshot
-- and the templates as they were, copied byte for byte from the migrations that defined them last.

drop function if exists public.keep_class_on_holiday(uuid, text);
drop function if exists public.remove_cohort_holiday(uuid);
drop function if exists public.add_cohort_holiday(uuid, date, text);
drop function if exists public.remove_break(uuid, uuid, boolean, boolean, text, uuid[]);
drop function if exists public.add_break(uuid, uuid[], date, int, text, boolean, boolean, boolean, text, uuid[]);
drop function if exists private.break_messages(uuid[], text, timestamptz);
drop function if exists private.apply_cohort_move(uuid, date, int, uuid[], timestamptz);
drop function if exists private.break_checks(jsonb, uuid[]);
drop function if exists private.break_preview(uuid, date, int, date, int, text, uuid);
drop function if exists private.move_cohort_weeks(uuid, date, int);
drop function if exists private.break_rule_blocks(uuid, date, int, date, int, uuid);
drop function if exists private.cohort_today(uuid);

create or replace function private.class_warnings(p_domain uuid, p_cohort uuid, p_start timestamptz, p_end timestamptz,
  p_exclude_week uuid default null, p_label text default null, p_region text default 'US')
returns jsonb language sql stable security definer set search_path = ''
as $$
  with t as (
    select (p_start at time zone private.region_tz(p_region)) as s, (p_end at time zone private.region_tz(p_region)) as e,
           coalesce(p_label || ' on ', '') || private.fmt_class_range(p_start, p_end, p_region) as what,
           coalesce(private.setting_text(p_domain, 'odd_hours_start'), '06:00')::time as h1,
           coalesce(private.setting_text(p_domain, 'odd_hours_end'), '22:00')::time as h2)
  select coalesce(jsonb_agg(x.w), '[]') from (
    select jsonb_build_object('code', 'holiday', 'level', 'Warning', 'text', t.what || ' is on a holiday (' || h.name || ').') as w
      from t join public.holiday h on h.date = t.s::date and (h.domain_id is null or h.domain_id = p_domain)
                                   and (h.region is null or h.region = p_region)
    union all
    select jsonb_build_object('code', 'unusual_hours', 'level', 'Warning', 'text', t.what || ' is outside '
             || private.fmt_hour(t.h1) || ' to ' || private.fmt_hour(t.h2) || ' '
             || case when p_region = 'India' then 'India time.' else 'US Pacific time.' end)
      from t where t.s::time < t.h1 or t.e::time > t.h2 or t.e::date > t.s::date
    union all
    select jsonb_build_object('code', 'cohort_overlap', 'level', 'Warning', 'text',
             t.what || ' overlaps ' || c.title || ' (' || private.fmt_class_range(c.starts_at, c.ends_at, c.region) || ') in the same cohort.')
      from t, public.class_session c join public.module_week w on w.id = c.module_week_id
     where p_cohort is not null and w.cohort_id = p_cohort and c.status = 'Planned'
       and (p_exclude_week is null or w.id <> p_exclude_week)
       and tstzrange(c.starts_at, c.ends_at, '[)') && tstzrange(p_start, p_end, '[)')
    union all
    select jsonb_build_object('code', 'short_notice', 'level', 'Information', 'text',
             t.what || ' is only ' || greatest(0, floor(extract(epoch from (p_start - private.domain_now(p_domain))) / 86400))::int
             || ' days away, so instructors are asked straight away with short reply times.')
      from t where p_start - private.domain_now(p_domain) < make_interval(days => private.setting_int(p_domain, 'outreach_days'))
                and p_start > private.domain_now(p_domain)
  ) x;
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
      select jsonb_agg(x || jsonb_build_object('class_id', c.id, 'fixes',
               case x ->> 'code' when 'holiday' then '["move_class", "cancel_class", "keep"]'::jsonb
                                 else '["move_class", "keep"]'::jsonb end))
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

create or replace function public.export_snapshot()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare t text; v jsonb := '{}'; r jsonb;
begin
  if not private.is_service() then raise exception 'Not allowed' using errcode = '42501'; end if;
  foreach t in array array['team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
    'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'module_week',
    'class_session', 'request', 'booking', 'checklist_item', 'help_request', 'attention_item', 'setting', 'holiday',
    'standard_schedule', 'standard_schedule_module', 'standard_schedule_break', 'standard_schedule_class'] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x', t) into r;
    v := v || jsonb_build_object(t, r);
  end loop;
  return v || jsonb_build_object('exported_at', now());
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
      'required', jsonb_build_array('module', 'classes')));
$$;

delete from public.message_template where template_id = 'M17';
alter table public.class_session drop column if exists holiday_kept_on, drop column if exists holiday_kept_reason;
drop table if exists public.cohort_holiday;
drop table if exists public.cohort_break;
drop table if exists public.program_break;
drop function if exists private.break_part_fill();
drop function if exists private.fmt_break(date, int);
