-- Release 2 Milestone B: US and India scheduling, exact time zones, conflicts.
-- Every class is stored in UTC. Each class has a region: US (America/Los_Angeles, PST or PDT)
-- or India (Asia/Kolkata, IST). A cohort's region is the default for its classes. Conversions use
-- the named time zone, never a fixed offset. A local time that does not exist (clocks move forward)
-- is refused; a local time that happens twice (clocks move back) must be chosen.

-- =============================================================== regions
alter table public.cohort add column region text not null default 'US' check (region in ('US', 'India'));
alter table public.class_session add column region text not null default 'US' check (region in ('US', 'India'));
alter table public.holiday add column region text check (region in ('US', 'India'));
comment on column public.cohort.region is 'US (US Pacific time) or India (India time). The default for the cohort''s classes.';
comment on column public.class_session.region is 'The time zone this class is planned in: US (America/Los_Angeles) or India (Asia/Kolkata).';
comment on column public.holiday.region is 'US, India, or empty for both.';
-- Every holiday so far was a US holiday (all classes were in US Pacific time).
update public.holiday set region = 'US' where region is null;
alter table public.class_pattern_item rename column start_time_pt to start_time;
comment on column public.class_pattern_item.start_time is 'Local start time in the region of the cohort that uses the pattern.';

-- Holidays are unique per date, region and domain (a US and an India holiday can share a date).
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'public.holiday'::regclass and contype = 'u' loop
    execute format('alter table public.holiday drop constraint %I', c);
  end loop;
end $$;
drop index if exists public.holiday_date_key;
drop index if exists public.holiday_date_uq;
create unique index if not exists holiday_date_region_domain_uq on public.holiday
  (date, coalesce(region, ''), coalesce(domain_id, '00000000-0000-0000-0000-000000000000'::uuid));

create or replace function private.region_tz(p_region text)
returns text language sql immutable set search_path = ''
as $$ select case p_region when 'India' then 'Asia/Kolkata' else 'America/Los_Angeles' end; $$;

/** PST or PDT for US (from the date), IST for India. */
create or replace function private.tz_abbrev(p_ts timestamptz, p_region text)
returns text language sql immutable set search_path = ''
as $$
  select case when p_region = 'India' then 'IST'
              when (p_ts at time zone 'America/Los_Angeles') - (p_ts at time zone 'UTC') = interval '-7 hours' then 'PDT'
              else 'PST' end;
$$;

/** "Sun, Jan 24 · 9:00 AM PST" in the region's own time zone. */
create or replace function private.fmt_local(p_ts timestamptz, p_region text)
returns text language sql immutable set search_path = ''
as $$
  select to_char(p_ts at time zone private.region_tz(p_region), 'Dy, Mon FMDD · FMHH12:MI AM') || ' ' || private.tz_abbrev(p_ts, p_region);
$$;

/** "Sun, Jan 24 · 9:00 AM to 1:00 PM PST" in the region's own time zone. */
create or replace function private.fmt_class_range(p_start timestamptz, p_end timestamptz, p_region text)
returns text language sql immutable set search_path = ''
as $$
  select to_char(p_start at time zone private.region_tz(p_region), 'Dy, Mon FMDD · FMHH12:MI AM') || ' to '
      || to_char(p_end at time zone private.region_tz(p_region), 'FMHH12:MI AM') || ' ' || private.tz_abbrev(p_start, p_region);
$$;

/** For the team: the class in its own time zone, plus the other region's time. */
create or replace function private.fmt_class_both(p_start timestamptz, p_end timestamptz, p_region text)
returns text language sql immutable set search_path = ''
as $$
  select private.fmt_class_range(p_start, p_end, p_region) || ' (' ||
         private.fmt_class_range(p_start, p_end, case when p_region = 'India' then 'US' else 'India' end) || ')';
$$;

/** Every real moment that a local date and time stands for: none, one, or two (when clocks move back). */
create or replace function private.local_candidates(p_date date, p_time time, p_region text)
returns timestamptz[] language sql immutable set search_path = ''
as $$
  select coalesce(array_agg(distinct x order by x), '{}') from (
    select ((p_date + p_time) at time zone private.region_tz(p_region)) + make_interval(hours => h) x
      from generate_series(-2, 2) h) y
   where (x at time zone private.region_tz(p_region)) = p_date + p_time;
$$;

/** A local date and time to UTC. p_fold 1 is the first of two possible times, 2 the second. */
create or replace function private.local_to_utc(p_date date, p_time time, p_region text, p_fold int default 1)
returns timestamptz language plpgsql immutable set search_path = ''
as $$
declare v timestamptz[] := private.local_candidates(p_date, p_time, p_region);
begin
  if cardinality(v) = 0 then
    raise exception '% on % does not exist in US Pacific time: the clocks move forward one hour that night. Choose another time, for example one hour later.',
      to_char(p_time, 'FMHH12:MI AM'), to_char(p_date, 'Dy, Mon FMDD, YYYY') using errcode = '22023';
  end if;
  return v[least(greatest(coalesce(p_fold, 1), 1), cardinality(v))];
end;
$$;

/** The question to ask when a local time happens twice. Null when it happens once. */
create or replace function private.ambiguous_warning(p_date date, p_time time, p_region text, p_label text default null)
returns jsonb language sql immutable set search_path = ''
as $$
  select case when cardinality(v) = 2 then jsonb_build_object('code', 'ambiguous_time',
    'text', coalesce(p_label || ': ', '') || to_char(p_time, 'FMHH12:MI AM') || ' on ' || to_char(p_date, 'Dy, Mon FMDD, YYYY')
            || ' happens twice in US Pacific time, because the clocks move back one hour that night. Choose which one you mean.',
    'options', jsonb_build_array(
      jsonb_build_object('fold', 1, 'label', 'The first time: ' || to_char(p_time, 'FMHH12:MI AM') || ' ' || private.tz_abbrev(v[1], p_region)
                                             || ' (' || private.fmt_local(v[1], 'India') || ')'),
      jsonb_build_object('fold', 2, 'label', 'The second time: ' || to_char(p_time, 'FMHH12:MI AM') || ' ' || private.tz_abbrev(v[2], p_region)
                                             || ' (' || private.fmt_local(v[2], 'India') || ')'))) end
    from (select private.local_candidates(p_date, p_time, p_region) v) x;
$$;

/** The region of a class week: its first class, else its cohort, else US. */
create or replace function private.week_region(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select c.region from public.class_session c where c.module_week_id = p_mw and c.status <> 'Cancelled' order by c.starts_at limit 1),
    (select co.region from public.module_week w join public.cohort co on co.id = w.cohort_id where w.id = p_mw),
    'US');
$$;

-- The old US only helpers stay for team facing texts and call the region aware ones.
create or replace function private.fmt_pt(p_ts timestamptz)
returns text language sql immutable set search_path = ''
as $$ select private.fmt_local(p_ts, 'US'); $$;
create or replace function private.fmt_pt_range(p_start timestamptz, p_end timestamptz)
returns text language sql immutable set search_path = ''
as $$ select private.fmt_class_range(p_start, p_end, 'US'); $$;
create or replace function private.pt_to_utc(p_date date, p_time time)
returns timestamptz language sql immutable set search_path = ''
as $$ select private.local_to_utc(p_date, p_time, 'US'); $$;

grant execute on function private.fmt_local(timestamptz, text) to authenticated, service_role;

-- =============================================================== labels and messages use each class's own time zone
create or replace function private.mw_label(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select m.name || coalesce(' (' || private.cohort_label(w.id) || ')', '') || ' · '
      || coalesce((select string_agg(to_char(c.starts_at at time zone private.region_tz(c.region), 'Dy Mon FMDD'), ' + ' order by c.starts_at)
                     from public.class_session c where c.module_week_id = w.id and c.status <> 'Cancelled'), 'no classes')
    from public.module_week w join public.module m on m.id = w.module_id where w.id = p_mw;
$$;

create or replace function private.class_lines(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(string_agg('• ' || c.class_type || ': ' || private.fmt_class_range(c.starts_at, c.ends_at, c.region), E'\n' order by c.starts_at), '')
    from public.class_session c where c.module_week_id = p_mw and c.status <> 'Cancelled';
$$;

-- Quiet hours for instructors follow the class's region.
drop function if exists private.instructor_send_time(uuid, timestamptz, boolean);
create or replace function private.instructor_send_time(p_domain uuid, p_ts timestamptz, p_urgent boolean, p_region text default 'US')
returns timestamptz language sql stable set search_path = ''
as $$
  select case when p_urgent
    then private.next_allowed(p_ts, private.region_tz(p_region),
           private.setting_text(p_domain, 'instructor_urgent_quiet_start'), private.setting_text(p_domain, 'instructor_urgent_quiet_end'))
    else private.next_allowed(p_ts, private.region_tz(p_region),
           private.setting_text(p_domain, 'instructor_quiet_start'), private.setting_text(p_domain, 'instructor_quiet_end'))
  end;
$$;

-- Holidays: on the local date of the class, in its region (or for both regions).
drop function if exists private.holiday_on(uuid, date);
create or replace function private.holiday_on(p_domain uuid, p_date date, p_region text default null)
returns text language sql stable security definer set search_path = ''
as $$
  select string_agg(h.name, ', ' order by h.name) from public.holiday h
   where h.date = p_date and (h.domain_id is null or h.domain_id = p_domain)
     and (h.region is null or p_region is null or h.region = p_region);
$$;

/** Who is already teaching at this time: the other class, its cohort and domain, and both local times. */
create or replace function private.clash_text(p_instructor uuid, p_start timestamptz, p_end timestamptz, p_region text,
  p_exclude_week uuid default null)
returns text language sql stable security definer set search_path = ''
as $$
  select 'Teaching ' || m.name || ' (' || coalesce(co.name || ', ', '') || d.name || ') on '
      || private.fmt_class_range(c.starts_at, c.ends_at, c.region)
      || ', the same time as this class (' || private.fmt_class_range(p_start, p_end, coalesce(p_region, 'US')) || ')'
    from public.booking_slot s
    join public.class_session c on c.id = s.class_id
    join public.module_week w on w.id = c.module_week_id
    join public.module m on m.id = w.module_id
    join public.domain d on d.id = w.domain_id
    left join public.cohort co on co.id = w.cohort_id
   where s.instructor_id = p_instructor and s.active and (p_exclude_week is null or w.id <> p_exclude_week)
     and s.time_range && tstzrange(p_start, p_end, '[)')
   order by c.starts_at limit 1;
$$;

/** The first clash for an instructor with any class of a class week. */
create or replace function private.week_clash(p_instructor uuid, p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select private.clash_text(p_instructor, c.starts_at, c.ends_at, c.region, p_mw)
    from public.class_session c
   where c.module_week_id = p_mw and c.status <> 'Cancelled'
     and private.clash_text(p_instructor, c.starts_at, c.ends_at, c.region, p_mw) is not null
   order by c.starts_at limit 1;
$$;

drop function if exists private.class_warnings(uuid, uuid, timestamptz, timestamptz, uuid, text);
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

create or replace function private.page_details(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select '<p><strong>' || private.html_escape(m.name) || '</strong>'
      || coalesce(' · ' || private.html_escape(private.cohort_label(w.id)), '') || ' · ' || private.html_escape(d.name) || '</p><ul>'
      || coalesce((select string_agg('<li>' || private.html_escape(c.class_type) || ': ' || private.html_escape(private.fmt_class_range(c.starts_at, c.ends_at, c.region)) || '</li>', '' order by c.starts_at)
                     from public.class_session c where c.module_week_id = w.id and c.status <> 'Cancelled'), '')
      || '</ul>'
    from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id
   where w.id = p_mw;
$$;

create or replace function private.row_label(p_table text, p_row jsonb)
returns text language sql stable security definer set search_path = ''
as $$
  select case p_table
    when 'module_week' then private.mw_label((p_row ->> 'id')::uuid)
    when 'class_session' then (p_row ->> 'title') || ' on '
      || private.fmt_class_range((p_row ->> 'starts_at')::timestamptz, (p_row ->> 'ends_at')::timestamptz, coalesce(p_row ->> 'region', 'US'))
    when 'setting' then coalesce((select d.label from public.setting_definition d where d.key = p_row ->> 'key'), p_row ->> 'key')
    when 'module_owner' then (select t.name from public.team_member t where t.id = (p_row ->> 'team_member_id')::uuid)
    when 'module_operations' then (select t.name from public.team_member t where t.id = (p_row ->> 'team_member_id')::uuid)
    when 'domain_team' then (select t.name from public.team_member t where t.id = (p_row ->> 'team_member_id')::uuid)
    when 'module_ranking' then (select i.full_name from public.instructor i where i.id = (p_row ->> 'instructor_id')::uuid)
    when 'instructor_email' then p_row ->> 'email'
    when 'instructor_unavailability' then (p_row ->> 'from_date') || ' to ' || (p_row ->> 'to_date')
    when 'request' then (select i.full_name from public.instructor i where i.id = (p_row ->> 'instructor_id')::uuid)
    when 'booking' then (select i.full_name from public.instructor i where i.id = (p_row ->> 'instructor_id')::uuid)
    else coalesce(p_row ->> 'name', p_row ->> 'full_name', p_row ->> 'title', p_row ->> 'label', p_row ->> 'email', p_row ->> 'key')
  end;
$$;

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

create or replace function public.cancel_class(p_class_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c public.class_session; w public.module_week; b public.booking; v_now timestamptz;
begin
  perform private.require_team();
  select * into c from public.class_session where id = p_class_id for update;
  if c.status <> 'Planned' then raise exception 'Only planned classes can be cancelled.'; end if;
  if not exists (select 1 from public.class_session x where x.module_week_id = c.module_week_id and x.status = 'Planned' and x.id <> c.id) then
    return public.cancel_module_week(c.module_week_id, p_reason);
  end if;
  select * into w from public.module_week where id = c.module_week_id;
  v_now := private.domain_now(w.domain_id);
  update public.class_session set status = 'Cancelled', cancelled_reason = p_reason where id = p_class_id;
  select * into b from public.booking where module_week_id = w.id and status = 'Active';
  if b.id is not null then
    update public.booking_slot set active = false where booking_id = b.id and class_id = p_class_id;
    perform private.queue_instructor_message('M11', b.instructor_id, w.id, null, v_now, '[]',
      jsonb_build_object('what', c.title, 'classes', '• ' || c.class_type || ': ' || private.fmt_class_range(c.starts_at, c.ends_at, c.region)),
      false, 'cancelclass:' || c.id);
  end if;
  perform private.log_event('Team actions', 'Class cancelled: ' || c.title, 'class_session', c.id, null, null, p_reason,
    w.domain_id, w.module_id, w.id, c.id);
  perform private.queue_deliver('cancel class');
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function private.eligibility(p_instructor uuid, p_mw uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_domain uuid;
  v_status text;
  v_reason text;
begin
  select * into i from public.instructor where id = p_instructor;
  select w.domain_id, d.status into v_domain, v_status
    from public.module_week w join public.domain d on d.id = w.domain_id where w.id = p_mw;
  if i.id is null then return 'Unknown instructor'; end if;
  if i.status = 'Inactive' then return 'Inactive'; end if;
  if i.status = 'Archived' then return 'Archived'; end if;
  if v_status = 'Live' and i.is_test then return 'Test instructor (not allowed in Live domains)'; end if;
  if v_status = 'Live' and i.verified_at is null then return 'Not verified'; end if;
  if i.discord_channel_id is null and i.email_bounced_at is not null then return 'No working contact details'; end if;

  select 'Unavailable ' || to_char(u.from_date, 'Mon FMDD') || ' to ' || to_char(u.to_date, 'Mon FMDD')
    into v_reason
    from public.instructor_unavailability u
   where u.instructor_id = p_instructor
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and (c.starts_at at time zone private.region_tz(c.region))::date between u.from_date and u.to_date)
   order by u.from_date limit 1;
  if v_reason is not null then return v_reason; end if;

  -- Clashes are checked on the real time (UTC), across every cohort, domain and region.
  return private.week_clash(p_instructor, p_mw);
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
  perform private.queue_team_message('T2', w.domain_id, 'alert', null, private.owners_or_leads(w.module_id),
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

create or replace function private.instructor_soft_warning(p_instructor uuid, p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select 'Over their preferred limit of ' || i.monthly_class_limit || ' classes a month.'
    from public.instructor i, public.module_week w
   where i.id = p_instructor and w.id = p_mw and i.monthly_class_limit is not null
     and (select count(*) from public.booking_slot s join public.class_session c on c.id = s.class_id
           where s.instructor_id = i.id and s.active and c.status <> 'Cancelled'
             and date_trunc('month', c.starts_at at time zone private.region_tz(c.region))
               = date_trunc('month', w.first_class_at at time zone private.region_tz(private.week_region(w.id))))
         + (select count(*) from public.class_session c where c.module_week_id = w.id and c.status = 'Planned')
         > i.monthly_class_limit;
$$;

create or replace function private.refresh_module_week_times(p_mw uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.module_week w
     set first_class_at = s.first_at,
         last_class_end_at = s.last_end
    from (select min(c.starts_at) filter (where c.status <> 'Cancelled') as first_at,
                 max(c.ends_at) filter (where c.status <> 'Cancelled') as last_end
            from public.class_session c where c.module_week_id = p_mw) s
   where w.id = p_mw
     and (w.first_class_at is distinct from s.first_at or w.last_class_end_at is distinct from s.last_end);
  update public.module_week w
     set week_start_date = (w.first_class_at at time zone private.region_tz(private.week_region(w.id)))::date
   where w.id = p_mw and w.first_class_at is not null
     and w.week_start_date <> (w.first_class_at at time zone private.region_tz(private.week_region(w.id)))::date
     and not exists (select 1 from public.module_week x
                      where x.module_id = w.module_id and x.cohort_id = w.cohort_id and x.seq = w.seq and x.id <> w.id
                        and x.week_start_date = (w.first_class_at at time zone private.region_tz(private.week_region(w.id)))::date);
$$;

create or replace function private.render_instructor(p_template text, p_mw uuid, p_instructor uuid, p_extra jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_name text;
  v_dom uuid;
  v_vars jsonb;
  v_first timestamptz;
  v_materials text := '';
  v_def jsonb := private.template_defaults() -> p_template;
  v_custom public.message_template;
  v_subject text;
  v_body text;
begin
  if v_def is null then raise exception 'Unknown instructor template %', p_template; end if;
  select i.full_name into v_name from public.instructor i where i.id = p_instructor;
  v_vars := jsonb_build_object('first_name', private.first_name(v_name), 'name', v_name);
  if p_mw is not null then
    select w.domain_id, w.first_class_at into v_dom, v_first from public.module_week w where w.id = p_mw;
    v_materials := private.materials_line(p_mw);
    v_vars := v_vars || (select jsonb_build_object(
        'module', m.name, 'domain', d.name, 'classes', private.class_lines(p_mw),
        'first_class', private.fmt_local(v_first, private.week_region(p_mw)),
        'weekday', to_char(v_first at time zone private.region_tz(private.week_region(p_mw)), 'FMDay'),
        'contact', private.team_names(private.owners_or_leads(m.id)),
        'materials', case when coalesce(v_materials, '') <> '' then E'\n\nMaterials:\n' || v_materials else '' end)
      from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id
     where w.id = p_mw);
  end if;
  v_vars := v_vars || jsonb_build_object(
    'deadline', coalesce(p_extra ->> 'deadline', ''),
    'reply_by', case when p_extra ->> 'deadline' is not null then E'\nPlease reply by ' || (p_extra ->> 'deadline') || '.' else '' end,
    'days', coalesce(p_extra ->> 'days', ''),
    'what', coalesce(p_extra ->> 'what', v_vars ->> 'module', ''),
    'helper', coalesce(p_extra ->> 'helper', ''),
    'by', coalesce(p_extra ->> 'by', ''),
    'text', coalesce(p_extra ->> 'text', ''),
    'from', coalesce(p_extra ->> 'from', ''));
  if p_extra ? 'classes' then v_vars := v_vars || jsonb_build_object('classes', p_extra ->> 'classes'); end if;
  if not v_vars ? 'module' then v_vars := v_vars || jsonb_build_object('module', 'SME Scheduling', 'domain', '', 'classes', '',
    'first_class', '', 'weekday', '', 'contact', '', 'materials', ''); end if;
  if v_dom is not null then
    select * into v_custom from public.message_template where domain_id = v_dom and template_id = p_template;
  end if;
  v_subject := private.fill_template(coalesce(v_custom.subject, v_def ->> 'subject'), v_vars);
  v_body := private.fill_template(coalesce(v_custom.body, v_def ->> 'body'), v_vars);
  return jsonb_build_object('subject', private.plain_message_text(v_subject), 'body', private.plain_message_text(v_body),
    'first_name', private.first_name(v_name), 'name', v_name);
end;
$$;

create or replace function public.preview_message_template(p_domain_id uuid, p_template_id text, p_subject text, p_body text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_mw uuid;
  v_vars jsonb;
begin
  perform private.require_team();
  select w.id into v_mw from public.module_week w
   where w.domain_id = p_domain_id and w.status not in ('Cancelled', 'Completed') and w.first_class_at is not null
   order by (w.first_class_at > now()) desc, w.first_class_at limit 1;
  if v_mw is not null then
    select jsonb_build_object('module', m.name, 'domain', d.name, 'classes', private.class_lines(w.id),
             'first_class', private.fmt_local(w.first_class_at, private.week_region(w.id)), 'weekday', to_char(w.first_class_at at time zone private.region_tz(private.week_region(w.id)), 'FMDay'),
             'contact', private.team_names(private.owners_or_leads(m.id)),
             'materials', coalesce(nullif(E'\n\nMaterials:\n' || nullif(private.materials_line(w.id), ''), E'\n\nMaterials:\n'), ''))
      into v_vars
      from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id where w.id = v_mw;
  else
    v_vars := jsonb_build_object('module', 'Concurrency', 'domain', coalesce((select name from public.domain where id = p_domain_id), 'Backend'),
      'classes', E'• Live class: Sun, Jan 31, 9:00 AM to 1:00 PM PST\n• Assignment review: Thu, Feb 4, 6:00 PM to 8:00 PM PST',
      'first_class', 'Sun Jan 31, 9:00 AM PST', 'weekday', 'Sunday', 'contact', 'Your module owner', 'materials', '');
  end if;
  v_vars := v_vars || jsonb_build_object('first_name', 'Alex', 'name', 'Alex Example', 'deadline', 'Tue Jan 5, 9:00 AM PST',
    'reply_by', E'\nPlease reply by Tue Jan 5, 9:00 AM PST.', 'days', '10', 'what', v_vars ->> 'module',
    'helper', 'Your module owner', 'by', 'Wed Jan 6, 5:00 PM PST', 'text', 'Here is the Zoom link you asked for.', 'from', 'The operations team');
  return jsonb_build_object(
    'subject', private.plain_message_text(private.fill_template(p_subject, v_vars)),
    'body', private.plain_message_text(private.fill_template(p_body, v_vars)),
    'problems', to_jsonb(private.template_problems(p_template_id, p_subject, p_body)));
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
      v_pick := l;
      v_found := true;
      exit;
    elsif l.reason not in ('Already declined this module week', 'Did not reply earlier', 'Skipped by ops',
                           'Cancelled this module week earlier', 'Had a clash when they said yes', 'Being asked now') then
      v_skips := v_skips || l.full_name || ' — ' || l.reason || '; ';
    end if;
  end loop;
  v_test := private.is_test_domain(w.domain_id);

  if not v_found then
    if w.status <> 'NeedsInstructor' then
      update public.module_week set status = 'NeedsInstructor' where id = p_mw;
      perform private.log_event('System', 'Ranking exhausted — needs instructor', 'module_week', p_mw, null, null,
        nullif(v_skips, ''), w.domain_id, w.module_id, p_mw, null, null, null, v_test);
    end if;
    perform private.raise_attention(w.domain_id, 'RankingExhausted', 'Urgent',
      'Needs instructor: ' || private.mw_label(p_mw),
      'Everyone in line has been asked or can''t be asked. Assign someone manually or add instructors to the ranking.'
        || coalesce(E'\nSkipped: ' || nullif(v_skips, ''), ''),
      'exhausted:' || p_mw, private.recipients_for_week(p_mw, true), p_now, private.mw_refs(p_mw),
      true, 'T4');
    return null;
  end if;

  v_win := private.window_hours(p_mw, p_now);
  v_urgent := v_win.band = 'Short';
  v_send := private.instructor_send_time(w.domain_id, p_now, v_urgent, private.week_region(p_mw));
  v_deadline := least(private.instructor_send_time(w.domain_id, v_send + make_interval(hours => v_win.move_h), v_urgent, private.week_region(p_mw)),
                      w.first_class_at);
  insert into public.request (module_week_id, instructor_id, kind, status, time_version, line_source,
    declined_before, sent_at, reminder_at, deadline_at, is_test)
  values (p_mw, v_pick.instructor_id, 'Outreach', 'Sent', w.time_version, v_pick.source,
    v_pick.warning is not null, v_send,
    case when v_win.reminder_h is null then null else least(private.instructor_send_time(w.domain_id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(p_mw)), v_deadline) end,
    v_deadline, v_test)
  returning id into v_req;
  if v_pick.queue_item_id is not null then
    update public.manual_queue_item set asked_request_id = v_req where id = v_pick.queue_item_id;
  end if;
  perform private.queue_instructor_message('M1', v_pick.instructor_id, p_mw, v_req, p_now,
    private.buttons(v_req, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local(v_deadline, private.week_region(p_mw))), v_urgent);

  v_first := w.outreach_started_at is null;
  update public.module_week
     set status = 'Asking', outreach_started_at = coalesce(outreach_started_at, p_now)
   where id = p_mw;
  perform private.log_event('Messages', 'Asked ' || v_pick.full_name, 'request', v_req, null,
    jsonb_build_object('deadline', v_deadline, 'band', v_win.band, 'source', v_pick.source),
    nullif('Skipped: ' || v_skips, 'Skipped: '), w.domain_id, w.module_id, p_mw, null, v_pick.instructor_id, null, v_test);
  if v_first then
    perform private.queue_team_message('T1', w.domain_id, 'alert', null, private.owners_or_leads(w.module_id),
      'Outreach started: ' || private.mw_label(p_mw),
      '📣 Outreach started for ' || private.mw_label(p_mw) || ' — asking ' || v_pick.full_name || '.',
      'T1:' || p_mw, p_now, false, null, p_mw);
  end if;
  if v_urgent then
    perform private.raise_attention(w.domain_id, 'ClassAtRisk', 'Urgent',
      'Under ' || private.setting_int(w.id, 'urgent_band_days') || ' days and no instructor yet: ' || private.mw_label(p_mw),
      'Now asking ' || v_pick.full_name || ' (moves on after ' || v_win.move_h || 'h). Consider phoning people too.',
      'urgentfill:' || p_mw, private.recipients_for_week(p_mw, true), p_now, private.mw_refs(p_mw));
  end if;
  return v_req;
end;
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
begin
  for r in select q.*, mw.module_id, mw.first_class_at
             from public.request q join public.module_week mw on mw.id = q.module_week_id
            where mw.domain_id = p_domain and not mw.paused
              and q.kind in ('Outreach', 'TimeChange') and q.status in ('Sent', 'Reminded')
            for update of q skip locked loop
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
    if r.deadline_at <= p_now then
      if r.kind = 'Outreach' then
        update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
        perform private.queue_instructor_message('M3', r.instructor_id, r.module_week_id, r.id, p_now);
        perform private.log_event('Messages', 'No reply from ' || v_name || ' — moving on', 'request', r.id, null, null,
          null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
        if private.band(r.module_week_id, p_now) <> 'Long' then
          perform private.queue_team_message('T3', p_domain, 'alert', null, private.owners_or_leads(r.module_id),
            'No reply: ' || private.mw_label(r.module_week_id),
            'No reply from ' || v_name || ' for ' || private.mw_label(r.module_week_id) || ' — asking the next instructor.',
            'T3:' || r.id, p_now, false, null, r.module_week_id);
        end if;
        perform private.ask_next(r.module_week_id, p_now);
      else
        update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
        perform private.raise_attention(p_domain, 'TimeChangeNotConfirmed',
          case when private.days_until(r.module_week_id, p_now) < private.setting_int(r.module_week_id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'New time not confirmed: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'No reply to the time-change message. The booking is kept; please check with them.',
          'timechange:' || r.module_week_id, private.recipients_for_week(r.module_week_id, true), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)), true);
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now and (private.window_hours(r.module_week_id, p_now)).reminder_h is not null then
      update public.request set status = 'Reminded', reminded_at = p_now where id = r.id;
      if r.kind = 'Outreach' then
        perform private.queue_instructor_message('M2', r.instructor_id, r.module_week_id, r.id, p_now,
          private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local(r.deadline_at, private.week_region(r.module_week_id))), v_urgent);
      else
        perform private.queue_instructor_message('M5', r.instructor_id, r.module_week_id, r.id, p_now,
          private.buttons(r.id, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_local(r.deadline_at, private.week_region(r.module_week_id))),
          v_urgent, 'reminder');
      end if;
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

create or replace function private.step_time_changes(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare b record; n int := 0; v_req uuid; v_win record; v_send timestamptz; v_deadline timestamptz; v_urgent boolean;
begin
  for b in select bk.*, mw.time_version as mw_tv, mw.first_class_at, mw.domain_id
             from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and not mw.paused
              and mw.time_version > bk.time_version_confirmed and mw.first_class_at > p_now
              and not exists (select 1 from public.request q where q.module_week_id = mw.id and q.kind = 'TimeChange'
                                and q.time_version = mw.time_version)
            for update of bk skip locked loop
    update public.request set status = 'Superseded', close_reason = 'Time changed again'
     where module_week_id = b.module_week_id and kind = 'TimeChange' and status in ('Queued', 'Sent', 'Reminded');
    v_win := private.window_hours(b.module_week_id, p_now);
    v_urgent := v_win.band = 'Short';
    v_send := private.instructor_send_time(p_domain, p_now, v_urgent, private.week_region(b.module_week_id));
    v_deadline := least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_win.move_h), v_urgent, private.week_region(b.module_week_id)), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, status, time_version, sent_at, reminder_at,
      deadline_at, is_test)
    values (b.module_week_id, b.instructor_id, b.id, 'TimeChange', 'Sent', b.mw_tv, v_send,
      case when v_win.reminder_h is null then null else least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(b.module_week_id)), v_deadline) end,
      v_deadline, b.is_test)
    returning id into v_req;
    perform private.queue_instructor_message('M5', b.instructor_id, b.module_week_id, v_req, p_now,
      private.buttons(v_req, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_local(v_deadline, private.week_region(b.module_week_id))), v_urgent);
    perform private.log_event('Messages', 'Time-change request sent', 'request', v_req, null,
      jsonb_build_object('time_version', b.mw_tv), null, p_domain, null, b.module_week_id, null, b.instructor_id, null, b.is_test);
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function private.week_times_changed(p_mw uuid, p_now timestamptz, p_clash boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  b public.booking;
  r public.request;
  v_win record;
  v_urgent boolean;
  v_send timestamptz;
  v_deadline timestamptz;
begin
  update public.module_week set time_version = time_version + 1 where id = p_mw returning * into w;
  select * into b from public.booking where module_week_id = w.id and status = 'Active';
  if b.id is not null then
    if p_clash then
      perform private.release_booking_flow(b.id, 'TimeClash', p_now, true);
      return jsonb_build_object('released', true, 'reason', 'clash');
    end if;
    -- The time-change request (M5) is created by the engine step; run it now unless instructor
    -- messages are paused (then the next allowed hourly run creates it).
    if private.instructor_messages_allowed(w.domain_id) and not w.paused then
      perform private.step_time_changes(w.domain_id, p_now);
    end if;
    return jsonb_build_object('time_change_request', true);
  end if;

  select * into r from public.request
   where module_week_id = w.id and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded') for update;
  if r.id is not null then
    -- Recalculate the response window for the new times (the class may now be much closer).
    v_win := private.window_hours(w.id, p_now);
    v_urgent := v_win.band = 'Short';
    v_send := private.instructor_send_time(w.domain_id, p_now, v_urgent, private.week_region(w.id));
    v_deadline := least(greatest(r.sent_at, p_now) + make_interval(hours => v_win.move_h), w.first_class_at);
    v_deadline := least(private.instructor_send_time(w.domain_id, v_deadline, v_urgent, private.week_region(w.id)), w.first_class_at);
    update public.request
       set time_version = w.time_version,
           deadline_at = least(deadline_at, v_deadline),
           reminder_at = case when v_win.reminder_h is null or reminder_at is null then null else least(reminder_at, private.instructor_send_time(w.domain_id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(w.id)), v_deadline) end
     where id = r.id
    returning * into r;
    perform private.queue_instructor_message('M5', r.instructor_id, w.id, r.id, p_now,
      private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local(r.deadline_at, private.week_region(w.id))), v_urgent);
    return jsonb_build_object('updated_request', true);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function private.step_checkins(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  b record;
  r record;
  n int := 0;
  v_days int[];
  v_last int;
  v_due int;
  v_req uuid;
  v_rem int;
  v_send timestamptz;
  v_deadline timestamptz;
  v_tpl text;
  v_urgent_band int;
  v_name text;
begin

  for b in select bk.*, mw.first_class_at, mw.module_id
             from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and not mw.paused and mw.first_class_at > p_now
            for update of bk skip locked loop
    v_days := private.checkin_days_for(b.module_week_id);
    v_last := private.last_checkin_day(b.module_week_id);
    v_urgent_band := private.setting_int(b.module_week_id, 'urgent_band_days');
    select min(d) into v_due from unnest(v_days) d
     where b.first_class_at - make_interval(days => d) <= p_now
       and b.confirmed_at < b.first_class_at - make_interval(days => d);
    continue when v_due is null;
    continue when exists (select 1 from public.request q where q.booking_id = b.id and q.kind = 'CheckIn' and q.check_in_days <= v_due);
    v_rem := case when v_due > v_urgent_band then 24 else 12 end;
    v_send := private.instructor_send_time(p_domain, p_now, v_due <= v_urgent_band, private.week_region(b.module_week_id));
    v_deadline := least(private.instructor_send_time(p_domain, v_send + make_interval(hours => 2 * v_rem), v_due <= v_urgent_band, private.week_region(b.module_week_id)), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, check_in_days, status, sent_at,
      reminder_at, deadline_at, is_test, time_version)
    values (b.module_week_id, b.instructor_id, b.id, 'CheckIn', v_due, 'Sent', v_send,
      least(private.instructor_send_time(p_domain, v_send + make_interval(hours => v_rem), v_due <= v_urgent_band, private.week_region(b.module_week_id)), v_deadline),
      v_deadline, b.is_test, (select mw.time_version from public.module_week mw where mw.id = b.module_week_id))
    returning id into v_req;
    v_tpl := case when v_due = v_last then 'M7' when v_due = 14 and v_due <> all (array(select x::int from jsonb_array_elements_text(private.get_setting(b.module_week_id, 'checkin_days')) x)) then 'M8' else 'M6' end;
    perform private.queue_instructor_message(v_tpl, b.instructor_id, b.module_week_id, v_req, p_now,
      private.buttons(v_req, case when v_tpl = 'M8' then array['AllSet', 'NeedHelp'] else array['AllSet', 'NeedHelp', 'CantMakeIt'] end),
      jsonb_build_object('days', v_due), v_due <= v_urgent_band);
    perform private.log_event('Messages', v_due || '-day check-in sent', 'request', v_req, null, null, null,
      p_domain, b.module_id, b.module_week_id, null, b.instructor_id, null, b.is_test);
    n := n + 1;
  end loop;

  for r in select q.*, mw.module_id from public.request q join public.module_week mw on mw.id = q.module_week_id
            where mw.domain_id = p_domain and q.kind = 'CheckIn' and q.status in ('Sent', 'Reminded') and not mw.paused
            for update of q skip locked loop
    select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
    v_last := private.last_checkin_day(r.module_week_id);
    v_urgent_band := private.setting_int(r.module_week_id, 'urgent_band_days');
    if r.deadline_at <= p_now then
      update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
      perform private.log_event('Messages', 'No reply to the ' || r.check_in_days || '-day check-in from ' || v_name, 'request', r.id,
        null, null, null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
      if r.check_in_days = v_last and private.setting_text(r.module_week_id, 'last_checkin_no_reply') = 'Release' then
        perform private.release_booking_flow(r.booking_id, 'NoReplyRelease', p_now);
      else
        perform private.raise_attention(p_domain, 'CheckInNoReply',
          case when r.check_in_days = v_last then 'Urgent' else 'Normal' end,
          'No reply to the ' || r.check_in_days || '-day check-in: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'The booking is kept. Please check with them.', 'checkin_noreply:' || r.id,
          private.ops_for_week(r.module_week_id), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)));
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now and private.setting_bool(r.module_week_id, 'remind_instructor_after_assign') then
      update public.request set status = 'Reminded', reminded_at = p_now where id = r.id;
      perform private.queue_instructor_message('M9', r.instructor_id, r.module_week_id, r.id, p_now,
        private.buttons(r.id, array['AllSet', 'NeedHelp', 'CantMakeIt']), '{}', r.check_in_days <= v_urgent_band);
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

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
begin
  select * into i from public.instructor where id = p_instructor;
  if p_mw is not null then
    select w.domain_id, w.time_version into v_domain, v_tv from public.module_week w where w.id = p_mw;
  end if;
  if p_request is not null then
    select r.time_version into v_tv from public.request r where r.id = p_request;
  end if;
  select * into d from public.domain where id = v_domain;
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

  foreach v_ch in array array['Discord', 'Email'] loop
    continue when p_only_channel is not null and v_ch <> p_only_channel;
    continue when v_ch = 'Discord' and v_channels = 'EmailOnly';
    continue when v_ch = 'Email' and v_channels = 'DiscordOnly';
    continue when v_ch = 'Discord' and not v_test and i.discord_channel_id is null;
    continue when v_ch = 'Email' and not v_test and coalesce(i.primary_email, '') = '';
    v_key := p_template || ':' || coalesce(p_request::text, coalesce(p_mw::text, '-') || ':' || p_instructor::text)
             || ':' || coalesce(v_tv, 0) || ':' || v_ch || coalesce(nullif(':' || p_key_suffix, ':'), '');
    if v_ch = 'Discord' then
      v_text := v_prefix || 'Hi ' ||
                case when i.discord_user_id is not null and (not v_test or i.is_test) then '<@' || i.discord_user_id || '>'
                     else (v_r ->> 'first_name') end
                || ' 👋 ' || (v_r ->> 'body');
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
      request_id, help_request_id, recipient_label, to_address, discord_channel_id, mention_user_ids, subject,
      body_text, body_html, buttons, is_test)
    values (
      v_domain, 'Instructor', p_template, v_ch, v_key,
      case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, p_instructor, p_mw,
      p_request, p_help_request, i.full_name,
      case when v_ch = 'Email' then case when v_test then d.test_email else i.primary_email end end,
      case when v_ch = 'Discord' then case when v_test then d.test_discord_channel_id else i.discord_channel_id end end,
      case when v_ch = 'Discord' and i.discord_user_id is not null and (not v_test or i.is_test) then array[i.discord_user_id] else '{}' end,
      v_prefix || (v_r ->> 'subject'), v_text, v_html, p_buttons, v_test)
    on conflict (unique_key) where unique_key is not null do nothing;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
  end loop;
  return v_count;
end;
$$;

create or replace function public.resend_message(p_message_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare m public.message; v_id uuid; v_now timestamptz; v_send timestamptz;
begin
  perform private.require_team();
  select * into m from public.message where id = p_message_id;
  if m.id is null or m.direction <> 'Outbound' then raise exception 'Choose a sent message to resend.'; end if;
  if m.status not in ('Sent', 'Failed') then
    raise exception 'That message hasn''t gone out yet (it is %), so there is nothing to resend.', lower(m.status);
  end if;
  if m.domain_id is not null and m.audience <> 'Admin' and m.is_test <> private.is_test_domain(m.domain_id) then
    raise exception 'Test mode changed since this message was sent. Send a new message instead (e.g. resend the check-in from Outreach after the next run).';
  end if;
  v_now := coalesce(private.domain_now(m.domain_id), now());
  v_send := case when m.audience = 'Instructor' then private.instructor_send_time(m.domain_id, v_now, false, coalesce(private.week_region(m.module_week_id), 'US')) else v_now end;
  if m.request_id is not null and exists (select 1 from public.request r where r.id = m.request_id
       and r.status not in ('Queued', 'Sent', 'Reminded', 'Accepted')) then
    raise exception 'That request has closed, so the message would confuse the instructor. Ask again instead.';
  end if;
  insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id,
    team_member_id, module_week_id, request_id, help_request_id, attention_item_id, recipient_label, to_address,
    discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html, buttons, is_test)
  select domain_id, audience, template_id, channel,
         coalesce(unique_key, id::text) || ':resend:' || extract(epoch from clock_timestamp())::bigint,
         case when v_send > v_now then 'Scheduled' else 'Pending' end, v_send, instructor_id, team_member_id, module_week_id, request_id, help_request_id, attention_item_id,
         recipient_label, to_address, discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html,
         buttons, is_test
    from public.message where id = p_message_id
  returning id into v_id;
  perform private.log_event('Team actions', 'Resent ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
    'message', v_id, null, null, null, m.domain_id, null, m.module_week_id, null, m.instructor_id);
  perform private.queue_deliver('resend');
  return jsonb_build_object('ok', true, 'message_id', v_id);
end;
$$;

create or replace function private.create_help_request(
  p_mw uuid, p_instructor uuid, p_member uuid, p_source text, p_categories text[], p_details text,
  p_urgency text, p_reply text, p_now timestamptz, p_booking uuid default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  h public.help_request;
  v_routing jsonb;
  v_routed uuid[] := '{}';
  v_owners uuid[];
  v_ops uuid[];
  v_leads uuid[];
  c text;
  v_rule text;
  v_days numeric;
  v_h int;
  v_sev text := 'Normal';
  v_name text;
  v_cats text[] := coalesce(p_categories, '{}');
  v_helper text;
begin
  select * into w from public.module_week where id = p_mw;
  if cardinality(v_cats) = 0 then v_cats := array['other']; end if;
  v_name := coalesce((select i.full_name from public.instructor i where i.id = p_instructor),
                     (select t.name from public.team_member t where t.id = p_member), 'Someone');

  -- Duplicates within 1 hour merge into one (PRD 10.6).
  select * into h from public.help_request
   where module_week_id = p_mw and merged_into is null
     and status in ('Open', 'InProgress', 'WaitingOnInstructor')
     and coalesce(requester_instructor_id::text, requester_team_member_id::text) = coalesce(p_instructor::text, p_member::text)
     and raised_at >= p_now - interval '1 hour'
   order by raised_at desc limit 1 for update;
  if h.id is not null then
    update public.help_request
       set categories = (select array_agg(distinct x) from unnest(categories || v_cats) x),
           details = left(concat_ws(E'\n---\n', nullif(details, ''), nullif(p_details, '')), 1000),
           urgency = case when p_urgency = 'Urgent' or urgency = 'Urgent' then 'Urgent'
                          when p_urgency = 'Within24h' or urgency = 'Within24h' then 'Within24h' else 'NoRush' end,
           status = 'Open'
     where id = h.id returning * into h;
    perform private.log_event('Help requests', 'Help request merged (same person within 1 hour)', 'help_request', h.id,
      null, jsonb_build_object('categories', v_cats), p_details, w.domain_id, w.module_id, p_mw, null, p_instructor);
    return jsonb_build_object('id', h.id, 'merged', true, 'target_at', h.response_target_at,
      'helper', private.team_names(coalesce(nullif(array[h.assigned_to], array[null]::uuid[]), h.routed_to[1:1])));
  end if;

  v_routing := private.get_setting(w.id, 'help_routing');
  v_owners := private.owners_or_leads(w.module_id);
  v_ops := private.ops_for_week(w.id);
  v_leads := private.domain_role_ids(w.domain_id, 'Lead');
  if p_source = 'Owner' then
    v_routed := v_ops || v_leads;
  else
    foreach c in array v_cats loop
      v_rule := coalesce(v_routing ->> c, 'Both');
      v_routed := v_routed || case v_rule when 'Owner' then v_owners when 'Ops' then v_ops else v_owners || v_ops end;
    end loop;
  end if;
  v_routed := private.uniq(v_routed);
  if cardinality(v_routed) = 0 then v_routed := private.uniq(v_ops || v_leads); end if;

  -- Response target: whichever is shorter, urgency or time to class (PRD 10.5).
  v_days := private.days_until(p_mw, p_now);
  v_h := case p_urgency when 'Urgent' then private.setting_int(w.id, 'help_target_urgent_h')
                        when 'Within24h' then private.setting_int(w.id, 'help_target_24h_h')
                        else private.setting_int(w.id, 'help_target_norush_h') end;
  if v_days < 2 then
    v_h := least(v_h, private.setting_int(w.id, 'help_target_urgent_h'));
  elsif v_days <= 7 then
    v_h := least(v_h, private.setting_int(w.id, 'help_target_24h_h'));
  end if;
  if p_urgency = 'Urgent' or v_days < 2 then v_sev := 'Urgent'; end if;

  insert into public.help_request (domain_id, module_week_id, booking_id, requester_instructor_id, requester_team_member_id,
    source, categories, details, urgency, reply_channel, routed_to, severity, raised_at, response_target_at, is_test)
  values (w.domain_id, p_mw, coalesce(p_booking, (select b.id from public.booking b where b.module_week_id = p_mw and b.status = 'Active')),
    p_instructor, p_member, p_source, v_cats, left(p_details, 1000), coalesce(p_urgency, 'NoRush'), coalesce(p_reply, 'Either'),
    v_routed, v_sev, p_now, p_now + make_interval(hours => v_h),
    private.is_test_domain(w.domain_id))
  returning * into h;

  v_helper := (select t.name from public.team_member t where t.id = v_routed[1]);
  perform private.raise_attention(w.domain_id, 'HelpRequest', v_sev,
    'Need help: ' || v_name || ' — ' || private.mw_label(p_mw),
    (select string_agg(private.help_category_label(x), ', ') from unnest(v_cats) x) || coalesce(E'\n' || p_details, '')
      || E'\nReply by ' || private.fmt_ist(h.response_target_at),
    'help:' || h.id, v_routed, p_now,
    private.mw_refs(p_mw, jsonb_build_object('help_request_id', h.id, 'instructor_id', p_instructor, 'due_at', h.response_target_at)),
    true, 'T7');
  if p_instructor is not null then
    perform private.queue_instructor_message('M13', p_instructor, p_mw, null, p_now, '[]',
      jsonb_build_object('helper', coalesce(v_helper, 'Our team'), 'by', private.fmt_local(h.response_target_at, coalesce(private.week_region(h.module_week_id), 'US'))),
      v_sev = 'Urgent', 'help:' || h.id, h.id,
      case when coalesce(p_reply, 'Either') = 'Email' then 'Email' when p_reply = 'Discord' then 'Discord' end);
  end if;
  perform private.log_event('Help requests', 'Help requested by ' || v_name, 'help_request', h.id, null,
    jsonb_build_object('categories', v_cats, 'urgency', p_urgency, 'routed_to', private.team_names(v_routed)),
    p_details, w.domain_id, w.module_id, p_mw, null, p_instructor, null, h.is_test);
  return jsonb_build_object('id', h.id, 'merged', false, 'target_at', h.response_target_at, 'helper', coalesce(v_helper, 'Our team'));
end;
$$;

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
    perform private.week_times_changed(w.id, v_now, v_clash);
    n := n + 1;
  end loop;
  perform private.log_event('Team actions', 'Shifted ' || n || ' module week(s) by ' || p_weeks || ' week(s)', 'module_week',
    p_module_week_id, null, null, null, w0.domain_id, w0.module_id, w0.id);
  perform private.queue_deliver('shift');
  return jsonb_build_object('ok', true, 'weeks_shifted', n);
end;
$$;

create or replace function private.pattern_for(p_module uuid, p_cohort uuid)
returns setof public.class_pattern_item language sql stable security definer set search_path = ''
as $$
  select p.* from public.class_pattern_item p
   where p.module_id = p_module
     and p.cohort_id is not distinct from (
       case when p_cohort is not null and exists (select 1 from public.class_pattern_item x where x.module_id = p_module and x.cohort_id = p_cohort)
            then p_cohort end)
   order by p.day_offset, p.start_time, p.sort_order;
$$;

drop function if exists public.generate_classes(uuid, uuid, date[], text);
create or replace function public.generate_classes(p_domain_id uuid, p_start_module_id uuid, p_week_starts date[], p_cohort text default '',
  p_region text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_mods uuid[];
  v_start int;
  v_out jsonb := '[]';
  i int;
  v_mod uuid;
  m public.module;
  v_d date;
  v_cohort uuid;
  v_min int;
  v_classes jsonb;
  v_warn jsonb;
  p record;
  v_s timestamptz;
  v_e timestamptz;
  v_region text;
  v_cand timestamptz[];
  v_problem text;
begin
  perform private.require_team();
  select array_agg(id order by rotation_order, name) into v_mods from public.module where domain_id = p_domain_id and status = 'Active';
  if v_mods is null then raise exception 'This domain has no active modules yet.'; end if;
  v_start := coalesce(array_position(v_mods, p_start_module_id), 1);
  select id, region into v_cohort, v_region from public.cohort where domain_id = p_domain_id and lower(name) = lower(coalesce(nullif(trim(p_cohort), ''), 'Main cohort'));
  -- A new cohort uses the region chosen for it; an existing cohort keeps its own.
  v_region := coalesce(case when v_cohort is null then p_region end, v_region, p_region, 'US');
  for i in 1 .. coalesce(cardinality(p_week_starts), 0) loop
    v_d := p_week_starts[i];
    v_mod := v_mods[((v_start - 1 + i - 1) % cardinality(v_mods)) + 1];
    select * into m from public.module where id = v_mod;
    select min(day_offset) into v_min from private.pattern_for(v_mod, v_cohort);
    v_classes := '[]';
    v_warn := '[]';
    v_problem := null;
    for p in select * from private.pattern_for(v_mod, v_cohort) loop
      v_cand := private.local_candidates(v_d + (p.day_offset - v_min), p.start_time, v_region);
      if cardinality(v_cand) = 0 then
        v_problem := coalesce(v_problem || ' ', '') || to_char(p.start_time, 'FMHH12:MI AM') || ' on '
          || to_char(v_d + (p.day_offset - v_min), 'Dy, Mon FMDD') || ' does not exist in US Pacific time (the clocks move forward). Change this class after planning, or plan this week by itself.';
        continue;
      end if;
      v_s := v_cand[1];
      v_e := v_s + make_interval(mins => p.duration_minutes);
      v_classes := v_classes || jsonb_build_object(
        'pattern_item_id', p.id, 'class_type', p.class_type,
        'title', replace(replace(p.title_template, '{module}', m.name), '{class_type}', p.class_type),
        'date', v_d + (p.day_offset - v_min), 'start_time', to_char(p.start_time, 'HH24:MI'),
        'end_time', to_char(p.start_time + make_interval(mins => p.duration_minutes), 'HH24:MI'),
        'region', v_region, 'ambiguous', cardinality(v_cand) = 2,
        'starts_at', v_s, 'ends_at', v_e, 'shown', private.fmt_class_range(v_s, v_e, v_region),
        'holiday', private.holiday_on(p_domain_id, v_d + (p.day_offset - v_min), v_region));
      v_warn := v_warn || private.class_warnings(p_domain_id, v_cohort, v_s, v_e, null,
        replace(replace(p.title_template, '{module}', m.name), '{class_type}', p.class_type), v_region)
        || coalesce(jsonb_path_query_array(jsonb_build_array(private.ambiguous_warning(v_d + (p.day_offset - v_min), p.start_time, v_region,
             replace(replace(p.title_template, '{module}', m.name), '{class_type}', p.class_type))), '$[*] ? (@ != null)'), '[]');
    end loop;
    v_out := v_out || jsonb_build_object('week_start_date', v_d, 'module_id', v_mod, 'module_name', m.name,
      'cohort', coalesce(nullif(trim(p_cohort), ''), 'Main cohort'), 'same_instructor', m.same_instructor_for_module_week,
      'classes', v_classes, 'warnings', v_warn,
      'region', v_region,
      'problem', case when jsonb_array_length(v_classes) = 0 and v_problem is null
                      then m.name || ' has no class times yet. Add them on the module page before planning.' else v_problem end,
      'duplicate', v_cohort is not null and exists (select 1 from public.module_week w where w.module_id = v_mod and w.cohort_id = v_cohort
                                                      and w.week_start_date = v_d and w.status <> 'Cancelled'),
      'holidays', (select coalesce(jsonb_agg(h.name), '[]') from public.holiday h where h.date between v_d and v_d + 6
                                  and (h.domain_id is null or h.domain_id = p_domain_id) and (h.region is null or h.region = v_region)));
  end loop;
  return v_out;
end;
$$;

grant execute on function public.generate_classes(uuid, uuid, date[], text, text) to authenticated, service_role;
revoke execute on function public.generate_classes(uuid, uuid, date[], text, text) from anon;

drop function if exists public.create_module_weeks(uuid, jsonb, boolean, text);
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
        values (m.id, v_cohort, (c ->> 'date')::date, v_seq, v_mode, v_end_b, m.same_instructor_for_module_week, v_group)
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

grant execute on function public.create_module_weeks(uuid, jsonb, boolean, text, int) to authenticated;
revoke execute on function public.create_module_weeks(uuid, jsonb, boolean, text, int) from anon;

drop function if exists public.add_one_class(uuid, uuid, uuid, date, time, time, text, text, boolean, text);
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
    select * into w from public.module_week where id = p_module_week_id;
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
    values (m.id, v_cohort, p_date, v_seq, private.setting_text(m.id, 'default_outreach_mode'),
            private.setting_text(m.id, 'manual_end_behaviour'), coalesce(w.same_instructor, m.same_instructor_for_module_week))
    returning * into w;
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region)
    values (w.id, trim(p_class_type), v_title, v_start, v_end, v_region) returning id into v_class;
    v := jsonb_build_object('new_class_week', true);
  else
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

grant execute on function public.add_one_class(uuid, uuid, uuid, date, time, time, text, text, boolean, text, text, int) to authenticated;
revoke execute on function public.add_one_class(uuid, uuid, uuid, date, time, time, text, text, boolean, text, text, int) from anon;

drop function if exists public.change_class_time(uuid, date, time, time, int);
create or replace function public.change_class_time(p_class_id uuid, p_date date, p_start time, p_end time,
  p_expected_version int default null, p_region text default null, p_fold int default null)
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
begin
  perform private.require_team();
  select * into c from public.class_session where id = p_class_id;
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
  v_start := private.local_to_utc(p_date, p_start, v_region, p_fold);
  v_end := private.local_to_utc(p_date + case when p_end <= p_start then 1 else 0 end, p_end, v_region, p_fold);
  if (c.starts_at, c.ends_at, c.region) = (v_start, v_end, v_region) then
    return jsonb_build_object('unchanged', true);
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
  perform private.queue_deliver('time change');
  return v;
end;
$$;
grant execute on function public.change_class_time(uuid, date, time, time, int, text, int) to authenticated;
revoke execute on function public.change_class_time(uuid, date, time, time, int, text, int) from anon;

create or replace function private.load_sandbox_seed(p_test_email text default null, p_test_discord_user_id text default null,
  p_test_channel_id text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_local text := coalesce(nullif(split_part(coalesce(p_test_email, ''), '@', 1), ''), 'sandbox.instructor');
  v_mail_domain text := coalesce(nullif(split_part(coalesce(p_test_email, ''), '@', 2), ''), 'example.com');
  v_chan text := coalesce(p_test_channel_id, '100000000000000002');
  v_owner uuid; v_ops uuid; v_esc uuid;
  v_dom uuid; v_mod uuid; v_coh_we uuid; v_coh_wd uuid;
  v_tests uuid[] := '{}';
  v_i uuid;
  d record; m record;
  k int;
  v_first_we date; v_first_wd date;
  n_weeks int := 0;
  v_rows jsonb;
begin
  perform set_config('app.actor_kind', 'System', true);
  perform set_config('app.actor_label', 'Sandbox data', true);

  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Owner', 'sandbox.owner@' || v_mail_domain, 'Product manager', true) returning id into v_owner;
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Operations', 'sandbox.operations@' || v_mail_domain, 'Operations', true) returning id into v_ops;
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Escalation', 'sandbox.escalation@' || v_mail_domain, 'Lead', true) returning id into v_esc;

  for k in 1 .. 6 loop
    insert into public.instructor (full_name, primary_email, discord_user_id, is_test, verified_at, notes)
    values ('Test Instructor ' || chr(64 + k), lower(v_local || '+' || chr(96 + k) || '@' || v_mail_domain),
            p_test_discord_user_id, true, now(), 'Sandbox test instructor. Messages go to the testing channel.')
    returning id into v_i;
    v_tests := v_tests || v_i;
  end loop;

  -- Next Saturday and next Tuesday (Pacific), so both cohorts start within two weeks.
  v_first_we := (now() at time zone 'America/Los_Angeles')::date + ((6 - extract(dow from now() at time zone 'America/Los_Angeles')::int + 7) % 7) + 7;
  v_first_wd := (now() at time zone 'America/Los_Angeles')::date + ((2 - extract(dow from now() at time zone 'America/Los_Angeles')::int + 7) % 7) + 7;

  for d in select * from (values ('Backend', array['Database Design', 'API Design', 'Concurrency']),
                                 ('Fullstack', array['React Basics', 'Node Services', 'Deployment'])) x(name, mods) loop
    insert into public.domain (name, status, alert_discord_channel_id, test_discord_channel_id, test_email)
    values (d.name, 'Test', v_chan, v_chan, lower(v_local || '+testing@' || v_mail_domain))
    returning id into v_dom;
    insert into public.domain_team (domain_id, team_member_id, role)
    values (v_dom, v_ops, 'Operations'), (v_dom, v_esc, 'Escalation');
    insert into public.cohort (domain_id, name, start_date, status) values (v_dom, 'Weekend cohort', v_first_we, 'Running')
    returning id into v_coh_we;
    insert into public.cohort (domain_id, name, start_date, status, region)
    values (v_dom, 'Weekday cohort', v_first_wd, 'Running', case when d.name = 'Fullstack' then 'India' else 'US' end)
    returning id into v_coh_wd;
    for k in 1 .. cardinality(d.mods) loop
      insert into public.module (domain_id, name, rotation_order) values (v_dom, d.mods[k], k) returning id into v_mod;
      insert into public.module_owner (module_id, team_member_id) values (v_mod, v_owner);
      insert into public.module_resource (module_id, title, url)
      values (v_mod, d.mods[k] || ' module page', 'https://example.com/sandbox/' || lower(replace(d.mods[k], ' ', '-')));
      -- Module default (used by the weekend cohort): Saturday live class and Sunday review.
      insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
      values (v_mod, 'Live class', '{module}: Live class', 0, '09:00', 240, 1),
             (v_mod, 'Assignment review', '{module}: Assignment review', 1, '10:00', 120, 2);
      -- Weekday cohort: Tuesday and Thursday evenings.
      insert into public.class_pattern_item (module_id, cohort_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
      values (v_mod, v_coh_wd, 'Live class', '{module}: Live class', 0, case when d.name = 'Fullstack' then '19:30' else '18:00' end::time, 120, 1),
             (v_mod, v_coh_wd, 'Assignment review', '{module}: Assignment review', 2, case when d.name = 'Fullstack' then '19:30' else '18:00' end::time, 90, 2);
      -- Instructor order: three test instructors, rotated so each module has a different Primary.
      insert into public.module_ranking (module_id, instructor_id, rank)
      select v_mod, v_tests[((k - 1 + j) % 6) + 1], j + 1 from generate_series(0, 2) j;
    end loop;
    select id into v_mod from public.module where domain_id = v_dom and rotation_order = 1;
    v_rows := public.generate_classes(v_dom, v_mod, array(select v_first_we + 7 * j from generate_series(0, 7) j), 'Weekend cohort');
    n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Sandbox data') ->> 'created')::int, 0);
    v_rows := public.generate_classes(v_dom, v_mod, array(select v_first_wd + 7 * j from generate_series(0, 7) j), 'Weekday cohort');
    n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Sandbox data') ->> 'created')::int, 0);
  end loop;
  perform private.log_event('System', 'Sandbox data loaded', null, null, null,
    jsonb_build_object('domains', 2, 'class_weeks', n_weeks, 'test_instructors', cardinality(v_tests)));
  return jsonb_build_object('class_weeks', n_weeks, 'test_instructors', cardinality(v_tests));
end;
$$;

create or replace function public.reset_sandbox_data(p_confirm text, p_test_email text default null,
  p_test_discord_user_id text default null, p_test_channel_id text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_env text := (select environment from public.app_config where id = 1); v jsonb;
begin
  perform private.require_team();
  if v_env = 'Production' then
    raise exception 'Sandbox data can never be reset in Production.' using errcode = '42501';
  end if;
  if p_confirm is distinct from 'RESET' then
    raise exception 'Type RESET to confirm.' using errcode = '22023';
  end if;
  perform private.log_event('System', 'Sandbox data reset started');
  -- Run any checks still waiting in this transaction (instructor order) before clearing tables.
  set constraints all immediate;
  -- Keep holidays and settings that apply to every domain (truncating domains would remove them).
  create temp table reset_keep_holiday on commit drop as select date, name, region from public.holiday where domain_id is null;
  create temp table reset_keep_setting on commit drop as select key, value from public.setting where scope = 'Global';
  truncate table public.message, public.request, public.response_link, public.booking_slot, public.booking,
    public.checklist_item, public.help_request, public.reminder, public.attention_item, public.manual_queue_item,
    public.class_session, public.module_week, public.setting, public.module_operations, public.module_ranking,
    public.module_owner, public.module_resource, public.class_pattern_item, public.module, public.cohort,
    public.class_type, public.message_template, public.domain_team, public.instructor_unavailability,
    public.instructor_email, public.instructor, public.action_queue, public.app_error, public.domain,
    public.discord_cursor
    restart identity cascade;
  -- Real people keep their sign in and profile; only the made up Sandbox people are replaced.
  -- The made up Sandbox people are found by their Sandbox email too: saving one on the Team page
  -- clears "needs real details", and the reset must still replace them.
  delete from public.team_member
   where is_placeholder or split_part(lower(email), '@', 1) in ('sandbox.owner', 'sandbox.operations', 'sandbox.escalation');
  insert into public.holiday (date, name, region) select date, name, region from reset_keep_holiday on conflict do nothing;
  insert into public.setting (scope, key, value) select 'Global', key, value from reset_keep_setting;
  update public.system_state set outreach_enabled = true where id = 1;
  v := private.load_sandbox_seed(p_test_email, p_test_discord_user_id, p_test_channel_id);
  set constraints all deferred;
  return v;
end;
$$;
