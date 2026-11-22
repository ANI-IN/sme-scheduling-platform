-- Rollback of 20261122000010_schedule_checks.sql (decision 297): the checks as they were before M7 part 2a.
-- Functions are copied byte for byte from the migrations that defined them last, line endings included.

delete from public.setting where key in ('odd_hours_start', 'odd_hours_end', 'tight_gap_minutes', 'max_classes_per_day');
delete from public.setting_definition where key in ('odd_hours_start', 'odd_hours_end', 'tight_gap_minutes', 'max_classes_per_day');
drop function if exists public.schedule_problems(uuid[]);
drop function if exists private.week_problems(uuid);
drop function if exists public.assign_manually(uuid, uuid, text, boolean, text);
drop function if exists public.record_offline_confirmation(uuid, uuid, text, boolean, text);
drop function if exists private.manual_booking(uuid, uuid, text, text, boolean, text);

create or replace function private.manual_booking(p_mw uuid, p_instructor uuid, p_via text, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  perform private.require_team();
  v := private.confirm_booking(p_mw, p_instructor, null, p_via, private.mw_now(p_mw), p_note);
  if not (v ->> 'ok')::boolean then
    raise exception 'Can''t book: %', v ->> 'message' using errcode = '22023';
  end if;
  perform private.queue_deliver('manual booking');
  return v;
end;
$$;

create or replace function public.assign_manually(p_module_week_id uuid, p_instructor_id uuid, p_note text default null)
returns jsonb language sql security definer set search_path = ''
as $$ select private.manual_booking(p_module_week_id, p_instructor_id, 'Manual', p_note); $$;

create or replace function public.record_offline_confirmation(p_module_week_id uuid, p_instructor_id uuid, p_note text default null)
returns jsonb language sql security definer set search_path = ''
as $$ select private.manual_booking(p_module_week_id, p_instructor_id, 'Offline', p_note); $$;

grant execute on function public.assign_manually(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.record_offline_confirmation(uuid, uuid, text) to authenticated, service_role;

create or replace function private.class_warnings(p_domain uuid, p_cohort uuid, p_start timestamptz, p_end timestamptz,
  p_exclude_week uuid default null, p_label text default null, p_region text default 'US')
returns jsonb language sql stable security definer set search_path = ''
as $$
  with t as (
    select (p_start at time zone private.region_tz(p_region)) as s, (p_end at time zone private.region_tz(p_region)) as e,
           coalesce(p_label || ' on ', '') || private.fmt_class_range(p_start, p_end, p_region) as what)
  select coalesce(jsonb_agg(x.w), '[]') from (
    select jsonb_build_object('code', 'holiday', 'text', t.what || ' is on a holiday (' || h.name || ').') as w
      from t join public.holiday h on h.date = t.s::date and (h.domain_id is null or h.domain_id = p_domain)
                                   and (h.region is null or h.region = p_region)
    union all
    select jsonb_build_object('code', 'unusual_hours', 'text', t.what || ' is outside 6 AM to 10 PM '
             || case when p_region = 'India' then 'India time.' else 'US Pacific time.' end)
      from t where t.s::time < '06:00' or t.e::time > '22:00' or t.e::date > t.s::date
    union all
    select jsonb_build_object('code', 'cohort_overlap', 'text',
             t.what || ' overlaps ' || c.title || ' (' || private.fmt_class_range(c.starts_at, c.ends_at, c.region) || ') in the same cohort.')
      from t, public.class_session c join public.module_week w on w.id = c.module_week_id
     where p_cohort is not null and w.cohort_id = p_cohort and c.status = 'Planned'
       and (p_exclude_week is null or w.id <> p_exclude_week)
       and tstzrange(c.starts_at, c.ends_at, '[)') && tstzrange(p_start, p_end, '[)')
    union all
    select jsonb_build_object('code', 'short_notice', 'text',
             t.what || ' is only ' || greatest(0, floor(extract(epoch from (p_start - private.domain_now(p_domain))) / 86400))::int
             || ' days away, so instructors are asked straight away with short reply times.')
      from t where p_start - private.domain_now(p_domain) < make_interval(days => private.setting_int(p_domain, 'outreach_days'))
                and p_start > private.domain_now(p_domain)
  ) x;
$$;

create or replace function private.log_accepted_warnings(p_warnings jsonb, p_reason text, p_domain uuid,
  p_module uuid default null, p_mw uuid default null, p_class uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(jsonb_array_length(p_warnings), 0) = 0 then return; end if;
  perform private.log_event('Team actions', 'Warnings accepted', 'domain', p_domain, null,
    jsonb_build_object('warnings', p_warnings), nullif(trim(coalesce(p_reason, '')), ''), p_domain, p_module, p_mw, p_class);
end;
$$;

create or replace function public.change_class_time(p_class_id uuid, p_date date, p_start time, p_end time,
  p_expected_version int default null, p_region text default null, p_fold int default null,
  p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  c public.class_session;
  v jsonb;
  v_region text;
  v_start timestamptz;
  v_end timestamptz;
  v_amb jsonb;
  v_booking public.booking;
  v_clash text;
  v_warn jsonb;
  v_week public.module_week;
begin
  perform private.require_team();
  -- SCH-2, SCH-8: lock the class week, then the class, before comparing versions or reading the booking.
  select * into v_week from public.module_week where id = (select module_week_id from public.class_session where id = p_class_id) for update;
  select * into c from public.class_session where id = p_class_id for update;
  if p_expected_version is not null and c.version <> p_expected_version then
    raise exception 'Someone else saved this class after you opened it. Reload the page to see their changes, then try again.' using errcode = '40001';
  end if;
  if c.status <> 'Planned' then raise exception 'Only planned classes can be moved.' using errcode = '22023'; end if;
  v_region := coalesce(p_region, c.region);
  if v_region not in ('US', 'India') then raise exception 'Choose US or India.' using errcode = '22023'; end if;
  v_amb := private.ambiguous_warning(p_date, p_start, v_region, c.title);
  if v_amb is not null and p_fold is null then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'needs_choice', true, 'warnings', jsonb_build_array(v_amb));
  end if;
  if p_end = p_start then raise exception 'The class must end after it starts.' using errcode = '22023'; end if;
  v_start := private.local_to_utc(p_date, p_start, v_region, p_fold);
  v_end := private.local_to_utc(p_date + case when p_end <= p_start then 1 else 0 end, p_end, v_region, p_fold);
  if (c.starts_at, c.ends_at, c.region) = (v_start, v_end, v_region) then
    return jsonb_build_object('unchanged', true);
  end if;
  -- SCH-1: one instructor teaches the whole week, so two of its classes never overlap.
  if v_week.same_instructor and private.week_self_overlap(c.module_week_id, v_start, v_end, c.id) is not null then
    raise exception 'The new time overlaps another class of the same class week: %. Choose another time.',
      private.week_self_overlap(c.module_week_id, v_start, v_end, c.id) using errcode = '23P01';
  end if;
  -- SCH-3: the same warnings as Plan classes and Add class (holidays, early or late hours, the cohort's other classes).
  -- "Short notice" is about planning a new class, not about moving one that is already planned.
  v_warn := coalesce((select jsonb_agg(x) from jsonb_array_elements(
              private.class_warnings(v_week.domain_id, v_week.cohort_id, v_start, v_end, c.module_week_id, c.title, v_region)) x
             where x ->> 'code' <> 'short_notice'), '[]');
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;
  -- A confirmed instructor can never end up with two classes at the same time: block the move and say why.
  select * into v_booking from public.booking where module_week_id = c.module_week_id and status = 'Active';
  if v_booking.id is not null then
    v_clash := private.clash_text(v_booking.instructor_id, v_start, v_end, v_region, c.module_week_id);
    if v_clash is not null then
      raise exception '% cannot teach at the new time: %. Choose another time, or release the instructor first.',
        (select full_name from public.instructor where id = v_booking.instructor_id), v_clash using errcode = '23P01';
    end if;
  end if;
  if c.region <> v_region then
    update public.class_session set region = v_region where id = p_class_id;
  end if;
  v := private.week_times_changed(c.module_week_id, private.mw_now(c.module_week_id), private.move_class(p_class_id, v_start, v_end));
  perform private.log_accepted_warnings(v_warn, p_reason, v_week.domain_id, v_week.module_id, v_week.id, c.id);
  perform private.queue_deliver('time change');
  return v;
end;
$$;

create or replace function public.add_one_class(p_module_week_id uuid, p_module_id uuid, p_cohort_id uuid,
  p_date date, p_start time, p_end time, p_class_type text, p_title text default null,
  p_accept_warnings boolean default false, p_reason text default null, p_region text default null, p_fold int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  m public.module;
  v_cohort uuid := p_cohort_id;
  v_start timestamptz;
  v_end timestamptz;
  v_warn jsonb;
  v_class uuid;
  v_booking public.booking;
  v_clash boolean := false;
  v_title text;
  v_seq int;
  v jsonb := '{}';
  v_region text;
  v_amb jsonb;
begin
  perform private.require_team();
  if p_module_week_id is not null then
    select * into w from public.module_week where id = p_module_week_id for update;
    if w.status in ('Cancelled', 'Completed') then raise exception 'This class week is already finished or cancelled.' using errcode = '22023'; end if;
    select * into m from public.module where id = w.module_id;
    v_cohort := w.cohort_id;
  else
    select * into m from public.module where id = p_module_id;
    if m.id is null then raise exception 'Choose a module.' using errcode = '22023'; end if;
    if v_cohort is null then raise exception 'Choose a cohort.' using errcode = '22023'; end if;
    if (select domain_id from public.cohort where id = v_cohort) <> m.domain_id then
      raise exception 'The cohort belongs to another domain.' using errcode = '22023';
    end if;
  end if;
  if p_start is null or p_end is null or p_date is null then raise exception 'Choose a date, a start time and an end time.' using errcode = '22023'; end if;
  if p_end = p_start then raise exception 'The class must end after it starts.' using errcode = '22023'; end if;
  if coalesce(trim(p_class_type), '') = '' then raise exception 'Choose a class type.' using errcode = '22023'; end if;
  -- The class's region: chosen for this class, else its cohort's.
  v_region := coalesce(p_region, (select co.region from public.cohort co where co.id = v_cohort), 'US');
  if v_region not in ('US', 'India') then raise exception 'Choose US or India.' using errcode = '22023'; end if;
  v_title := coalesce(nullif(trim(p_title), ''), m.name || ': ' || trim(p_class_type));
  v_amb := private.ambiguous_warning(p_date, p_start, v_region, v_title);
  if v_amb is not null and p_fold is null then
    -- A time that happens twice must be chosen, even when other warnings are accepted.
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'needs_choice', true, 'warnings', jsonb_build_array(v_amb));
  end if;
  v_start := private.local_to_utc(p_date, p_start, v_region, p_fold);
  v_end := private.local_to_utc(p_date + case when p_end <= p_start then 1 else 0 end, p_end, v_region, p_fold);
  v_warn := private.class_warnings(m.domain_id, v_cohort, v_start, v_end, null, v_title, v_region);
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;

  if w.id is null or not w.same_instructor then
    select coalesce(max(seq), 0) + 1 into v_seq from public.module_week where module_id = m.id and cohort_id = v_cohort and week_start_date = p_date;
    insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour, same_instructor)
    values (m.id, v_cohort, p_date, v_seq, private.setting_text(coalesce(v_cohort, m.domain_id), 'default_outreach_mode'),
            private.setting_text(coalesce(v_cohort, m.domain_id), 'manual_end_behaviour'), coalesce(w.same_instructor, m.same_instructor_for_module_week))
    returning * into w;
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region)
    values (w.id, trim(p_class_type), v_title, v_start, v_end, v_region) returning id into v_class;
    v := jsonb_build_object('new_class_week', true);
  else
    if private.week_self_overlap(w.id, v_start, v_end) is not null then
      raise exception 'This class overlaps another class of the same class week: %. One instructor teaches the whole week, so choose another time.',
        private.week_self_overlap(w.id, v_start, v_end) using errcode = '23P01';
    end if;
    select * into v_booking from public.booking where module_week_id = w.id and status = 'Active';
    -- The instructor of this class week teaches the new class too: never at the same time as another class.
    if v_booking.id is not null and private.clash_text(v_booking.instructor_id, v_start, v_end, v_region) is not null then
      raise exception '% cannot teach this class: %.', (select full_name from public.instructor where id = v_booking.instructor_id),
        private.clash_text(v_booking.instructor_id, v_start, v_end, v_region) using errcode = '23P01';
    end if;
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region)
    values (w.id, trim(p_class_type), v_title, v_start, v_end, v_region) returning id into v_class;
    if v_booking.id is not null then
      begin
        insert into public.booking_slot (booking_id, class_id, instructor_id, time_range)
        values (v_booking.id, v_class, v_booking.instructor_id, tstzrange(v_start, v_end, '[)'));
      exception when exclusion_violation then
        v_clash := true;
      end;
    end if;
    v := private.week_times_changed(w.id, private.mw_now(w.id), v_clash);
  end if;
  perform private.log_event('Team actions', 'Class added', 'class_session', v_class, null,
    jsonb_build_object('title', v_title, 'shown', private.fmt_class_range(v_start, v_end, v_region), 'region', v_region), nullif(trim(coalesce(p_reason, '')), ''),
    m.domain_id, m.id, w.id, v_class);
  perform private.log_accepted_warnings(v_warn, p_reason, m.domain_id, m.id, w.id, v_class);
  perform private.queue_deliver('class added');
  return jsonb_build_object('ok', true, 'class_id', v_class, 'module_week_id', w.id, 'warnings', v_warn) || v;
end;
$$;

drop function if exists private.instructor_warnings(uuid, uuid, timestamptz, timestamptz, text, uuid, text);
drop function if exists private.fmt_hour(time);
