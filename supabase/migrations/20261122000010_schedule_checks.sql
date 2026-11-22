-- Release 3, M7 part 2a (decisions 295 and 297): the schedule checks.
--
-- One set of rules that every save, every preview and the Schedule board use, so the screen never saves what the
-- database would refuse. Each problem has a level: Block (cannot be saved), Warning (saved only with a reason, kept
-- in Activity history) or Information.
--
-- 1. Settings for the limits, with the owner's numbers as defaults: classes are unusual before 6 AM or after 10 PM
--    (in the cohort's time zone), under 30 minutes between two of an instructor's classes is a tight gap, and more
--    than 2 classes in one day is a full day.
-- 2. private.instructor_warnings: an instructor's day at a given time. Unavailable dates (Block), a tight gap and a
--    full day (Warning).
-- 3. Moving a class of a confirmed week, adding a class to it, and assigning or recording an instructor now check
--    the instructor's day too; assigning also warns about the monthly limit.
-- 4. Going ahead despite a Warning needs a reason (Information alone, such as short notice, does not).
-- 5. private.week_problems and public.schedule_problems: every problem of a class week as it is now, with its
--    level, plain words and the suggested fixes, for the class drawer and the Schedule board.

insert into public.setting_definition (key, group_name, label, value_type, default_value, min_value, max_value, help, sort_order) values
  ('odd_hours_start', 'Planning', 'Classes are unusual if they start before', 'time', '"06:00"', null, null,
   'In the cohort''s time zone. Planning or moving a class outside these hours needs a reason.', 371),
  ('odd_hours_end', 'Planning', 'Classes are unusual if they end after', 'time', '"22:00"', null, null,
   'In the cohort''s time zone. Planning or moving a class outside these hours needs a reason.', 372),
  ('tight_gap_minutes', 'Planning', 'Shortest break between two classes of one instructor (minutes)', 'int', '30', 0, 240,
   'A shorter break is a warning: the instructor may not make it on time.', 373),
  ('max_classes_per_day', 'Planning', 'Most classes one instructor teaches in a day', 'int', '2', 1, 6,
   'More classes than this on one day is a warning.', 374);

create or replace function private.fmt_hour(p_time time)
returns text language sql immutable set search_path = ''
as $$
  select to_char(timestamp '2000-01-01' + p_time, case when extract(minute from p_time) = 0 then 'FMHH12 AM' else 'FMHH12:MI AM' end);
$$;

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

-- An instructor's day if they teach p_start to p_end: unavailable dates block; a tight gap or a full day warns.
-- Their other confirmed classes count, except p_exclude_class (the class being moved).
create or replace function private.instructor_warnings(p_domain uuid, p_instructor uuid, p_start timestamptz,
  p_end timestamptz, p_region text default 'US', p_exclude_class uuid default null, p_label text default null)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with i as (select id, full_name from public.instructor where id = p_instructor),
  cfg as (select greatest(0, coalesce(private.setting_int(p_domain, 'tight_gap_minutes'), 30)) as gap,
                 greatest(1, coalesce(private.setting_int(p_domain, 'max_classes_per_day'), 2)) as per_day,
                 private.region_tz(coalesce(p_region, 'US')) as tz),
  t as (select (p_start at time zone cfg.tz)::date as day,
               coalesce(p_label || ' on ', 'The class on ') || private.fmt_class_range(p_start, p_end, coalesce(p_region, 'US')) as what
          from cfg),
  o as (select c.id, c.title, c.starts_at, c.ends_at, c.region
          from public.booking_slot s join public.class_session c on c.id = s.class_id
         where s.instructor_id = p_instructor and s.active and c.status = 'Planned' and c.id is distinct from p_exclude_class)
  select coalesce(jsonb_agg(x.w), '[]') from (
    select jsonb_build_object('code', 'unavailable', 'level', 'Block', 'instructor_id', i.id, 'text',
             i.full_name || ' cannot teach ' || t.what || '. Unavailable ' || to_char(u.from_date, 'Mon FMDD') || ' to '
             || to_char(u.to_date, 'Mon FMDD') || coalesce(' (' || nullif(trim(u.reason), '') || ')', '') || '.') as w
      from i, t join public.instructor_unavailability u on u.instructor_id = p_instructor and t.day between u.from_date and u.to_date
    union all
    (select jsonb_build_object('code', 'tight_gap', 'level', 'Warning', 'instructor_id', i.id, 'text',
             i.full_name || ' has only '
             || floor(extract(epoch from case when o.starts_at >= p_end then o.starts_at - p_end else p_start - o.ends_at end) / 60)::int
             || ' minutes between ' || t.what || ' and ' || o.title || ' (' || private.fmt_class_range(o.starts_at, o.ends_at, o.region)
             || ').')
       from i, t, cfg, o
      where (o.starts_at >= p_end and o.starts_at - p_end < make_interval(mins => cfg.gap))
         or (p_start >= o.ends_at and p_start - o.ends_at < make_interval(mins => cfg.gap))
      order by o.starts_at limit 1)
    union all
    select jsonb_build_object('code', 'busy_day', 'level', 'Warning', 'instructor_id', i.id, 'text',
             i.full_name || ' would teach ' || (k.n + 1) || ' classes on ' || to_char(t.day, 'Dy Mon FMDD')
             || ', more than ' || cfg.per_day || '.')
      from i, t, cfg,
           (select count(*)::int as n from o, cfg, t where (o.starts_at at time zone cfg.tz)::date = t.day) k
     where k.n + 1 > cfg.per_day
  ) x;
$$;

-- Going ahead despite a Warning needs a reason, kept in Activity history. Information alone does not.
create or replace function private.log_accepted_warnings(p_warnings jsonb, p_reason text, p_domain uuid,
  p_module uuid default null, p_mw uuid default null, p_class uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_first text;
begin
  if coalesce(jsonb_array_length(p_warnings), 0) = 0 then return; end if;
  select x ->> 'text' into v_first from jsonb_array_elements(p_warnings) x
   where coalesce(x ->> 'level', 'Warning') = 'Warning' limit 1;
  if v_first is not null and nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'Say why you are going ahead despite the warning: %', v_first using errcode = '22023';
  end if;
  perform private.log_event('Team actions', 'Warnings accepted', 'domain', p_domain, null,
    jsonb_build_object('warnings', p_warnings), nullif(trim(coalesce(p_reason, '')), ''), p_domain, p_module, p_mw, p_class);
end;
$$;

revoke execute on function private.fmt_hour(time) from public, anon, authenticated;
revoke execute on function private.instructor_warnings(uuid, uuid, timestamptz, timestamptz, text, uuid, text) from public, anon, authenticated;

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
  v_iw jsonb;
  v_block text;
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
  -- M7: the confirmed instructor's day at the new time (unavailable dates block; a tight gap or a full day warns).
  select * into v_booking from public.booking where module_week_id = c.module_week_id and status = 'Active';
  if v_booking.id is not null then
    v_iw := private.instructor_warnings(v_week.domain_id, v_booking.instructor_id, v_start, v_end, v_region, c.id, c.title);
    v_block := (select x ->> 'text' from jsonb_array_elements(v_iw) x where x ->> 'level' = 'Block' limit 1);
    if v_block is not null then
      raise exception '% Choose another time, or release the instructor first.', v_block using errcode = '23P01';
    end if;
    v_warn := v_warn || v_iw;
  end if;
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
  v_iw jsonb;
  v_block text;
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
    -- M7: the confirmed instructor's day with the new class.
    if v_booking.id is not null then
      v_iw := private.instructor_warnings(m.domain_id, v_booking.instructor_id, v_start, v_end, v_region, null, v_title);
      v_block := (select x ->> 'text' from jsonb_array_elements(v_iw) x where x ->> 'level' = 'Block' limit 1);
      if v_block is not null then
        raise exception '%', v_block using errcode = '23P01';
      end if;
      if jsonb_array_length(v_iw) > 0 and not p_accept_warnings then
        return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn || v_iw);
      end if;
      v_warn := v_warn || v_iw;
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


-- Assigning or recording an instructor: the instructor's day with this class week and their monthly limit warn
-- first; going ahead needs a reason. The same checks as moving or adding a class.
drop function if exists public.assign_manually(uuid, uuid, text);
drop function if exists public.record_offline_confirmation(uuid, uuid, text);
drop function if exists private.manual_booking(uuid, uuid, text, text);

create function private.manual_booking(p_mw uuid, p_instructor uuid, p_via text, p_note text,
  p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v jsonb;
  w public.module_week;
  v_warn jsonb;
  v_soft text;
  v_block text;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_mw;
  -- A Block comes before any warning: a clash or unavailable dates are refused straight away.
  v_block := private.week_clash(p_instructor, p_mw);
  if v_block is null then
    select x ->> 'text' into v_block from public.class_session c,
           jsonb_array_elements(private.instructor_warnings(w.domain_id, p_instructor, c.starts_at, c.ends_at, c.region, null, c.title)) x
     where c.module_week_id = p_mw and c.status = 'Planned' and x ->> 'level' = 'Block' limit 1;
  end if;
  if v_block is not null then
    raise exception 'Can''t book: %', v_block using errcode = '22023';
  end if;
  v_warn := coalesce((select jsonb_agg(distinct x) from public.class_session c,
                        jsonb_array_elements(private.instructor_warnings(w.domain_id, p_instructor, c.starts_at, c.ends_at,
                                                                         c.region, null, c.title)) x
                       where c.module_week_id = p_mw and c.status = 'Planned' and x ->> 'level' = 'Warning'), '[]');
  v_soft := private.instructor_soft_warning(p_instructor, p_mw);
  if v_soft is not null then
    v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'monthly_limit', 'level', 'Warning',
      'instructor_id', p_instructor,
      'text', (select full_name from public.instructor where id = p_instructor) || ': ' || lower(left(v_soft, 1)) || substr(v_soft, 2)));
  end if;
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;
  v := private.confirm_booking(p_mw, p_instructor, null, p_via, private.mw_now(p_mw), p_note);
  if not (v ->> 'ok')::boolean then
    raise exception 'Can''t book: %', v ->> 'message' using errcode = '22023';
  end if;
  perform private.log_accepted_warnings(v_warn, p_reason, w.domain_id, w.module_id, p_mw, null);
  perform private.queue_deliver('manual booking');
  return v;
end;
$$;

create function public.assign_manually(p_module_week_id uuid, p_instructor_id uuid, p_note text default null,
  p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language sql security definer set search_path = ''
as $$ select private.manual_booking(p_module_week_id, p_instructor_id, 'Manual', p_note, p_accept_warnings, p_reason); $$;

create function public.record_offline_confirmation(p_module_week_id uuid, p_instructor_id uuid, p_note text default null,
  p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language sql security definer set search_path = ''
as $$ select private.manual_booking(p_module_week_id, p_instructor_id, 'Offline', p_note, p_accept_warnings, p_reason); $$;

revoke execute on function private.manual_booking(uuid, uuid, text, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.assign_manually(uuid, uuid, text, boolean, text) from public, anon;
revoke execute on function public.record_offline_confirmation(uuid, uuid, text, boolean, text) from public, anon;
grant execute on function public.assign_manually(uuid, uuid, text, boolean, text) to authenticated, service_role;
grant execute on function public.record_offline_confirmation(uuid, uuid, text, boolean, text) to authenticated, service_role;

-- Every problem of a class week as it is now: the classes themselves (holidays, unusual hours, the cohort's other
-- classes) and the confirmed instructor, or the one being asked (clash, unavailable dates, a tight gap, a full day,
-- the monthly limit, an instructor no longer in use), plus "busy with a sooner class" as information. Each problem
-- names its suggested fixes; the screens offer them as buttons.
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

create or replace function public.schedule_problems(p_module_week_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if cardinality(p_module_week_ids) > 1000 then
    raise exception 'Ask for at most 1,000 class weeks at a time.' using errcode = '22023';
  end if;
  return coalesce((select jsonb_object_agg(w.id, private.week_problems(w.id))
                     from public.module_week w where w.id = any (p_module_week_ids)), '{}');
end;
$$;

revoke execute on function private.week_problems(uuid) from public, anon, authenticated;
revoke execute on function public.schedule_problems(uuid[]) from public, anon;
grant execute on function public.schedule_problems(uuid[]) to authenticated, service_role;
