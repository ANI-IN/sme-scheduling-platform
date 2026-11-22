-- Release 3, M8 (decision 301): cohort breaks, program breaks and cohort holidays.
--
-- A cohort break is a record (cohort, first day, whole weeks, reason). Adding one moves every class week of the cohort
-- that starts on or after its first day back by the break, keeping each class's local clock time, and moves the
-- cohort's later breaks with them. A program break is the same break for several or all cohorts of a domain at once,
-- kept as one record so the board can show it as one row. Removing a break moves the classes back.
--
-- Rules (Block): not in the past, not inside a class week that has started, no class week that starts before the break
-- and has classes inside it, no overlap with another break of the cohort, no time that does not exist after the move,
-- no two classes of a week that would overlap, no landing on a week the same module already has. The preview shows
-- every class that moves and every instructor affected, and every problem the move creates, with its level and fixes,
-- through the same checks as everything else (private.week_problems): the preview really moves the classes inside a
-- block that is always rolled back, then reads the problems. A clash or unavailable date of the confirmed instructor
-- blocks unless the person saving chooses "release and ask the next instructor" for that class week; a Warning needs
-- a reason, kept in Activity history.
--
-- Messages: each confirmed instructor gets one message for all their moved class weeks (M17), with Still works and
-- Doesn't work for each class week (one time change request per class week, so the answers work as before). While
-- messages are paused the hourly run sends the usual time change message per class week later. The person being
-- asked gets the updated request as today.
--
-- A cohort holiday is a single day for one cohort, apart from domain and region holidays. A class on it is a Warning
-- (fixes: move, cancel, or keep with a reason). Planning a class on a cohort holiday or inside a break warns too.

create table public.program_break (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete cascade,
  starts_on date not null,
  weeks int not null check (weeks between 1 and 26),
  reason text not null check (length(trim(reason)) between 1 and 200),
  status text not null default 'Active' check (status in ('Active', 'Removed')),
  label text,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create index program_break_domain_idx on public.program_break (domain_id, starts_on);

create table public.cohort_break (
  id uuid primary key default gen_random_uuid(),
  cohort_id uuid not null references public.cohort (id) on delete cascade,
  domain_id uuid not null references public.domain (id) on delete cascade,
  program_break_id uuid references public.program_break (id) on delete set null,
  starts_on date not null,
  weeks int not null check (weeks between 1 and 26),
  reason text not null check (length(trim(reason)) between 1 and 200),
  status text not null default 'Active' check (status in ('Active', 'Removed')),
  moved jsonb not null default '[]',
  label text,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  -- Checked at the end of the change, because later breaks move together with the classes.
  constraint cohort_break_no_overlap exclude using gist (cohort_id with =, daterange(starts_on, starts_on + 7 * weeks) with &&)
    where (status = 'Active') deferrable initially deferred
);
create index cohort_break_domain_idx on public.cohort_break (domain_id);
create index cohort_break_program_idx on public.cohort_break (program_break_id);

create table public.cohort_holiday (
  id uuid primary key default gen_random_uuid(),
  cohort_id uuid not null references public.cohort (id) on delete cascade,
  domain_id uuid not null references public.domain (id) on delete cascade,
  date date not null,
  name text not null check (length(trim(name)) between 1 and 80),
  label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (cohort_id, date)
);
create index cohort_holiday_domain_idx on public.cohort_holiday (domain_id, date);

-- A class kept on a cohort holiday: the day it was kept for, and why.
alter table public.class_session add column holiday_kept_on date, add column holiday_kept_reason text;

/** "Sun, Mar 7 to Sat, Mar 20 (2 weeks)". */
create or replace function private.fmt_break(p_starts date, p_weeks int)
returns text language sql immutable set search_path = ''
as $$
  select to_char(p_starts, 'Dy, Mon FMDD') || ' to ' || to_char(p_starts + 7 * p_weeks - 1, 'Dy, Mon FMDD') || ' ('
      || p_weeks || case when p_weeks = 1 then ' week)' else ' weeks)' end;
$$;

-- A break or holiday belongs to its cohort's domain. The label is what Activity history shows.
create or replace function private.break_part_fill()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare c public.cohort;
begin
  if tg_table_name = 'program_break' then
    new.label := 'Program break: ' || new.reason || ', ' || private.fmt_break(new.starts_on, new.weeks);
    return new;
  end if;
  select * into c from public.cohort where id = new.cohort_id;
  new.domain_id := c.domain_id;
  -- One branch per table: each reads only its own columns.
  if tg_table_name = 'cohort_break' then
    new.label := c.name || ': break, ' || new.reason || ', ' || private.fmt_break(new.starts_on, new.weeks);
  else
    new.label := c.name || ': holiday on ' || to_char(new.date, 'Dy, Mon FMDD, YYYY') || ' (' || new.name || ')';
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['program_break', 'cohort_break', 'cohort_holiday'] loop
    execute format('create trigger %I before insert or update on public.%I for each row execute function private.break_part_fill()', t || '_fill', t);
    execute format('create trigger %I before update on public.%I for each row execute function private.touch_row()', t || '_touch', t);
    execute format('create trigger %I before insert on public.%I for each row execute function private.set_created_by()', t || '_created_by', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function private.log_setup_change()', t || '_history', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('create policy %I on public.%I for select to authenticated using (private.is_team_user())', t || '_team_read', t);
    -- Breaks and holidays change only through the functions below, which check them and move the classes.
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end;
$$;

-- class_warnings: also a class on a cohort holiday, or inside a break of its cohort (was 20261122000010_schedule_checks.sql).
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
    select jsonb_build_object('code', 'cohort_holiday', 'level', 'Warning', 'text',
             t.what || ' is on a holiday of this cohort (' || h.name || ').')
      from t join public.cohort_holiday h on h.cohort_id = p_cohort and h.date = t.s::date
    union all
    select jsonb_build_object('code', 'in_break', 'level', 'Warning', 'text',
             t.what || ' is during this cohort''s break (' || b.reason || ', ' || private.fmt_break(b.starts_on, b.weeks) || ').')
      from t join public.cohort_break b on b.cohort_id = p_cohort and b.status = 'Active'
                                       and t.s::date >= b.starts_on and t.s::date < b.starts_on + 7 * b.weeks
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

-- week_problems: fixes for a cohort holiday and a class inside a break, and a class kept on a cohort holiday is
-- information with its reason (was 20261122000010_schedule_checks.sql).
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

-- ===================================================================================== moving a cohort's class weeks

/** The cohort's local "today" (its region's clock, or the test clock). */
create or replace function private.cohort_today(p_cohort uuid)
returns date language sql stable security definer set search_path = ''
as $$
  select (private.domain_now(c.domain_id) at time zone private.region_tz(coalesce(c.region, 'US')))::date
    from public.cohort c where c.id = p_cohort;
$$;

-- Why a break from p_from cannot move this cohort's classes by p_offset weeks (empty when it can). p_new_start and
-- p_new_weeks describe a break being added (null when one is being removed); p_ignore is the break being removed.
create or replace function private.break_rule_blocks(p_cohort uuid, p_from date, p_offset int, p_new_start date,
  p_new_weeks int, p_ignore uuid)
returns text[] language plpgsql stable security definer set search_path = ''
as $$
declare
  v text[] := '{}';
  v_today date := private.cohort_today(p_cohort);
  b record;
  w record;
begin
  if p_new_start is not null then
    if p_new_start < v_today then v := v || 'A break can''t start in the past.'::text; end if;
    for b in select * from public.cohort_break x
              where x.cohort_id = p_cohort and x.status = 'Active' and x.id is distinct from p_ignore
                and daterange(x.starts_on, x.starts_on + 7 * x.weeks) && daterange(p_new_start, p_new_start + 7 * p_new_weeks) loop
      v := v || ('It overlaps the break ' || b.reason || ' (' || private.fmt_break(b.starts_on, b.weeks) || ').');
    end loop;
  end if;
  -- A class week that starts before the break but has classes inside it.
  for w in select mw.id, mw.week_start_date from public.module_week mw
            where mw.cohort_id = p_cohort and mw.status not in ('Completed', 'Cancelled') and mw.week_start_date < p_from
              and exists (select 1 from public.class_session c where c.module_week_id = mw.id and c.status = 'Planned'
                            and (c.starts_at at time zone private.region_tz(c.region))::date >= p_from)
            order by mw.week_start_date loop
    v := v || (private.mw_label(w.id) || ' starts before the break and has classes inside it. Start the break on '
               || to_char(w.week_start_date, 'Dy, Mon FMDD') || ' or after that class week.');
  end loop;
  -- A class week that has started cannot move.
  for w in select mw.id from public.module_week mw
            where mw.cohort_id = p_cohort and mw.status not in ('Completed', 'Cancelled') and mw.week_start_date >= p_from
              and (mw.first_class_at <= private.domain_now(mw.domain_id)
                   or exists (select 1 from public.class_session c where c.module_week_id = mw.id and c.status = 'Completed'))
            order by mw.week_start_date loop
    v := v || (private.mw_label(w.id) || ' has started, so it can''t move.');
  end loop;
  -- Landing on a week the same module already has (a cancelled or finished one stays where it is).
  for w in select mw.id, t.week_start_date from public.module_week mw
             join public.module_week t on t.module_id = mw.module_id and t.cohort = mw.cohort and t.id <> mw.id
                                      and t.week_start_date = mw.week_start_date + 7 * p_offset
            where mw.cohort_id = p_cohort and mw.status not in ('Completed', 'Cancelled') and mw.week_start_date >= p_from
              and not (t.status not in ('Completed', 'Cancelled') and t.week_start_date >= p_from) loop
    v := v || ((select m.name from public.module m join public.module_week x on x.module_id = m.id where x.id = w.id)
               || ' already has a class week starting ' || to_char(w.week_start_date, 'Dy, Mon FMDD') || '. Move or delete that week first.');
  end loop;
  return v;
end;
$$;

-- Moves every class week of the cohort that starts on or after p_from by p_offset weeks (each class keeps its local
-- clock time), and the cohort's later breaks with them. Returns what moved and what can't move.
create or replace function private.move_cohort_weeks(p_cohort uuid, p_from date, p_offset int)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_days int := 7 * p_offset;
  w record;
  c record;
  v_weeks jsonb := '[]';
  v_classes jsonb;
  v_blocks text[] := '{}';
  v_ls timestamp;
  v_le timestamp;
  v_s timestamptz;
  v_e timestamptz;
  v_clash boolean;
  v_bad boolean;
begin
  update public.cohort_break set starts_on = starts_on + v_days
   where cohort_id = p_cohort and status = 'Active' and starts_on >= p_from;
  for w in select mw.* from public.module_week mw
            where mw.cohort_id = p_cohort and mw.status not in ('Completed', 'Cancelled') and mw.week_start_date >= p_from
            order by case when p_offset > 0 then mw.week_start_date end desc,
                     case when p_offset < 0 then mw.week_start_date end asc, mw.id loop
    update public.module_week set week_start_date = week_start_date + v_days where id = w.id;
    v_classes := '[]';
    v_clash := false;
    for c in select * from public.class_session where module_week_id = w.id and status = 'Planned'
              order by case when p_offset > 0 then starts_at end desc, case when p_offset < 0 then starts_at end asc loop
      v_ls := c.starts_at at time zone private.region_tz(c.region);
      v_le := c.ends_at at time zone private.region_tz(c.region);
      v_bad := cardinality(private.local_candidates(v_ls::date + v_days, v_ls::time, c.region)) = 0
            or cardinality(private.local_candidates(v_le::date + v_days, v_le::time, c.region)) = 0;
      if v_bad then
        v_blocks := v_blocks || (c.title || ' would be at ' || to_char(v_ls::time, 'FMHH12:MI AM') || ' on '
                                 || to_char(v_ls::date + v_days, 'Dy, Mon FMDD')
                                 || ', a time that does not exist because the clocks move forward that night. Change its time first.');
        continue;
      end if;
      v_s := private.local_to_utc(v_ls::date + v_days, v_ls::time, c.region);
      v_e := private.local_to_utc(v_le::date + v_days, v_le::time, c.region);
      v_clash := private.move_class(c.id, v_s, v_e) or v_clash;
      v_classes := v_classes || jsonb_build_object('class_id', c.id, 'title', c.title,
        'from', private.fmt_class_range(c.starts_at, c.ends_at, c.region), 'to', private.fmt_class_range(v_s, v_e, c.region));
    end loop;
    -- Classes keep their own region's clock time, so a week with US and India classes can overlap itself after a
    -- clock change.
    if exists (select 1 from public.class_session a join public.class_session b on a.module_week_id = b.module_week_id and a.id < b.id
                where a.module_week_id = w.id and a.status = 'Planned' and b.status = 'Planned'
                  and tstzrange(a.starts_at, a.ends_at, '[)') && tstzrange(b.starts_at, b.ends_at, '[)')) then
      v_blocks := v_blocks || (private.mw_label(w.id) || ': after the move two of its classes would overlap, because they keep the clock time of different regions. Change one class time first.');
    end if;
    v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id, 'label', private.mw_label(w.id),
      'from', w.week_start_date, 'to', w.week_start_date + v_days, 'classes', v_classes, 'slot_clash', v_clash);
  end loop;
  return jsonb_build_object('weeks', v_weeks, 'blocks', to_jsonb(v_blocks));
end;
$$;

-- What a break does to one cohort, without saving anything: the classes are moved inside a block that is always
-- rolled back, so every check reads them at their new times. Each problem says whether the move creates it.
create or replace function private.break_preview(p_cohort uuid, p_from date, p_offset int, p_new_start date,
  p_new_weeks int, p_new_reason text, p_ignore uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_before jsonb := '{}';
  v_out jsonb;
  v_moved jsonb;
  v_weeks jsonb := '[]';
  x jsonb;
  w record;
  v_person record;
  v_keys text[];
  v_prob jsonb;
  v_rules text[] := private.break_rule_blocks(p_cohort, p_from, p_offset, p_new_start, p_new_weeks, p_ignore);
begin
  for w in select mw.id from public.module_week mw
            where mw.cohort_id = p_cohort and mw.status not in ('Completed', 'Cancelled') and mw.week_start_date >= p_from loop
    v_before := v_before || jsonb_build_object(w.id::text, private.week_problems(w.id));
  end loop;
  begin
    if p_ignore is not null then
      update public.cohort_break set status = 'Removed' where id = p_ignore;
    end if;
    v_moved := private.move_cohort_weeks(p_cohort, p_from, p_offset);
    if p_new_start is not null then
      begin
        insert into public.cohort_break (cohort_id, domain_id, starts_on, weeks, reason)
        values (p_cohort, (select domain_id from public.cohort where id = p_cohort), p_new_start, p_new_weeks, p_new_reason);
      exception when exclusion_violation then
        null; -- it overlaps another break: already a Block above
      end;
    end if;
    for x in select * from jsonb_array_elements(v_moved -> 'weeks') loop
      select b.instructor_id as id, i.full_name as name, 'Confirmed' as status into v_person
        from public.booking b join public.instructor i on i.id = b.instructor_id
       where b.module_week_id = (x ->> 'module_week_id')::uuid and b.status = 'Active';
      if v_person.id is null then
        select r.instructor_id as id, i.full_name as name, 'Asked' as status into v_person
          from public.request r join public.instructor i on i.id = r.instructor_id
         where r.module_week_id = (x ->> 'module_week_id')::uuid and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded');
      end if;
      v_keys := array(select (p ->> 'code') || ':' || coalesce(p ->> 'class_id', '') || ':' || coalesce(p ->> 'instructor_id', '')
                        from jsonb_array_elements(coalesce(v_before -> (x ->> 'module_week_id'), '[]')) p);
      select coalesce(jsonb_agg(p || jsonb_build_object('module_week_id', x ->> 'module_week_id',
               'new', not ((p ->> 'code') || ':' || coalesce(p ->> 'class_id', '') || ':' || coalesce(p ->> 'instructor_id', '') = any (v_keys)))), '[]')
        into v_prob from jsonb_array_elements(private.week_problems((x ->> 'module_week_id')::uuid)) p;
      v_weeks := v_weeks || (x - 'slot_clash' || jsonb_build_object(
        'instructor', case when v_person.id is not null then jsonb_build_object('id', v_person.id, 'name', v_person.name, 'status', v_person.status) end,
        'problems', v_prob));
    end loop;
    v_out := jsonb_build_object('cohort_id', p_cohort, 'cohort', (select name from public.cohort where id = p_cohort),
      'weeks', v_weeks,
      'blocks', to_jsonb(v_rules) || (v_moved -> 'blocks'));
    raise exception 'break preview' using errcode = 'P0B01';
  exception when sqlstate 'P0B01' then
    null;
  end;
  return v_out;
end;
$$;

-- The problems that stop a break from being saved, and the warnings it needs a reason for. A class week in
-- p_release has its instructor released (or the person being asked let go), so their own problems no longer count.
create or replace function private.break_checks(p_previews jsonb, p_release uuid[])
returns jsonb language sql stable set search_path = ''
as $$
  with p as (
    select c ->> 'cohort' as cohort, w ->> 'module_week_id' as mw, w -> 'instructor' as person, x as problem
      from jsonb_array_elements(p_previews) c, jsonb_array_elements(c -> 'weeks') w, jsonb_array_elements(w -> 'problems') x
     where (x ->> 'new')::boolean
       and not ((w ->> 'module_week_id')::uuid = any (coalesce(p_release, '{}'))
                and x ? 'instructor_id' and x ->> 'instructor_id' = w -> 'instructor' ->> 'id'))
  select jsonb_build_object(
    'blocks', coalesce((select jsonb_agg(b) from (
        select to_jsonb(r) as b from jsonb_array_elements(p_previews) c, jsonb_array_elements_text(c -> 'blocks') r
        union all
        select jsonb_build_object('text', problem ->> 'text', 'module_week_id', mw, 'code', problem ->> 'code',
                 'fixes', problem -> 'fixes') from p where problem ->> 'level' = 'Block') s), '[]'),
    'warnings', coalesce((select jsonb_agg(problem) from p where problem ->> 'level' in ('Warning', 'Information')), '[]'));
$$;

-- Saves the move of one cohort for a break: the classes move, then each class week tells its people. Returns the
-- class weeks whose confirmed instructor gets the combined message.
create or replace function private.apply_cohort_move(p_cohort uuid, p_from date, p_offset int, p_release uuid[], p_now timestamptz)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_moved jsonb := private.move_cohort_weeks(p_cohort, p_from, p_offset);
  x jsonb;
  w public.module_week;
  v_booking uuid;
  v_sent boolean;
  v_confirmed uuid[] := '{}';
begin
  if jsonb_array_length(v_moved -> 'blocks') > 0 then
    raise exception '%', v_moved -> 'blocks' ->> 0 using errcode = '22023';
  end if;
  for x in select * from jsonb_array_elements(v_moved -> 'weeks') loop
    select * into w from public.module_week where id = (x ->> 'module_week_id')::uuid;
    select b.id into v_booking from public.booking b where b.module_week_id = w.id and b.status = 'Active';
    if w.id = any (coalesce(p_release, '{}')) then
      update public.module_week set time_version = time_version + 1 where id = w.id;
      if v_booking is not null then
        perform private.release_booking_flow(v_booking, 'OpsReleased', p_now, true,
          'The class week moved for a break and they can''t teach the new dates.');
      else
        v_sent := exists (select 1 from public.message m join public.request r on r.id = m.request_id
                           where r.module_week_id = w.id and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')
                             and m.status in ('Sending', 'Sent'));
        if private.withdraw_open_request(w.id, 'Moved for a break', p_now, v_sent) is not null then
          perform private.ask_next(w.id, p_now);
        end if;
      end if;
    elsif (x ->> 'slot_clash')::boolean then
      raise exception '% clashes with another class of the confirmed instructor after the move.', private.mw_label(w.id)
        using errcode = '23P01';
    elsif v_booking is not null then
      update public.module_week set time_version = time_version + 1 where id = w.id;
      v_confirmed := v_confirmed || w.id;
    else
      -- The person being asked gets the request with the new times, as for any time change.
      perform private.week_times_changed(w.id, p_now, false);
    end if;
  end loop;
  return jsonb_build_object('moved', v_moved -> 'weeks', 'confirmed', to_jsonb(v_confirmed));
end;
$$;

-- One message per confirmed instructor for all their moved class weeks (at most 12 class weeks a message, so the
-- buttons fit), with Still works and Doesn't work for each class week. Each class week has its own time change
-- request, so each answer works as before. While messages are paused nothing is sent now: the hourly run sends the
-- usual time change message per class week when they are turned back on.
create or replace function private.break_messages(p_weeks uuid[], p_text text, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  g record;
  v_mw uuid;
  v_req uuid;
  v_first_req uuid;
  v_win record;
  v_urgent boolean;
  v_any_urgent boolean;
  v_send timestamptz;
  v_deadline timestamptz;
  v_min_deadline timestamptz;
  v_buttons jsonb;
  v_lines text;
  v_n int := 0;
  v_part int;
  b record;
begin
  for g in select bk.instructor_id, array_agg(w.id order by w.first_class_at, w.id) as weeks
             from public.booking bk join public.module_week w on w.id = bk.module_week_id
            where w.id = any (coalesce(p_weeks, '{}')) and bk.status = 'Active' and not w.paused
              and w.first_class_at > p_now and private.instructor_messages_allowed(w.domain_id)
            group by bk.instructor_id loop
    for v_part in 0 .. (cardinality(g.weeks) - 1) / 12 loop
      v_buttons := '[]'; v_lines := ''; v_first_req := null; v_min_deadline := null; v_any_urgent := false;
      foreach v_mw in array g.weeks[v_part * 12 + 1 : v_part * 12 + 12] loop
        select bk.*, w.time_version as mw_tv, w.first_class_at, w.domain_id, m.name as module_name,
               private.week_region(w.id) as region into b
          from public.booking bk join public.module_week w on w.id = bk.module_week_id join public.module m on m.id = w.module_id
         where bk.module_week_id = v_mw and bk.status = 'Active';
        update public.request set status = 'Superseded', close_reason = 'Time changed again'
         where module_week_id = v_mw and kind = 'TimeChange' and status in ('Queued', 'Sent', 'Reminded');
        v_win := private.window_hours(v_mw, p_now);
        v_urgent := v_win.band = 'Short';
        v_any_urgent := v_any_urgent or v_urgent;
        v_send := private.instructor_send_time(v_mw, p_now, v_urgent, b.region);
        v_deadline := least(private.instructor_send_time(v_mw, v_send + make_interval(hours => v_win.move_h), v_urgent, b.region), b.first_class_at);
        insert into public.request (module_week_id, instructor_id, booking_id, kind, status, time_version, sent_at, reminder_at,
          deadline_at, is_test)
        values (v_mw, b.instructor_id, b.id, 'TimeChange', 'Sent', b.mw_tv, v_send,
          case when v_win.reminder_h is null then null else least(private.instructor_send_time(v_mw, v_send + make_interval(hours => v_win.reminder_h), v_urgent, b.region), v_deadline) end,
          v_deadline, b.is_test)
        returning id into v_req;
        perform private.log_event('Messages', 'Time-change request sent', 'request', v_req, null,
          jsonb_build_object('time_version', b.mw_tv, 'combined', true), null, b.domain_id, null, v_mw, null, b.instructor_id, null, b.is_test);
        v_first_req := coalesce(v_first_req, v_req);
        v_min_deadline := least(coalesce(v_min_deadline, v_deadline), v_deadline);
        v_buttons := v_buttons || (select coalesce(jsonb_agg(x || jsonb_build_object('label', (x ->> 'label') || ': ' || b.module_name
                        || ', ' || to_char(b.first_class_at at time zone private.region_tz(b.region), 'Mon FMDD')) order by o), '[]')
                      from jsonb_array_elements(private.buttons(v_req, array['StillWorks', 'DoesntWork'])) with ordinality t(x, o));
        v_lines := v_lines || case when v_lines = '' then '' else E'\n\n' end || b.module_name || E'\n' || private.class_lines(v_mw);
      end loop;
      perform private.queue_instructor_message('M17', g.instructor_id, g.weeks[v_part * 12 + 1], v_first_req, p_now, v_buttons,
        jsonb_build_object('classes', v_lines, 'text', p_text,
          'deadline', private.fmt_local(v_min_deadline, private.week_region(g.weeks[v_part * 12 + 1]))), v_any_urgent);
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end;
$$;

-- ===================================================================================== adding and removing breaks

-- A break for some cohorts of a domain (p_cohort_ids), or a program break for all of them (p_program). Without
-- p_save it only previews: every class that moves, every instructor affected, and every problem the move creates.
-- Saving needs no Block left (a confirmed instructor who clashes or is unavailable can be released, and the person
-- being asked let go, through p_release_week_ids) and a reason past any Warning.
create or replace function public.add_break(p_domain_id uuid, p_cohort_ids uuid[], p_starts_on date, p_weeks int, p_reason text,
  p_program boolean default false, p_save boolean default false, p_accept_warnings boolean default false,
  p_accept_reason text default null, p_release_week_ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_cohorts uuid[];
  v_now timestamptz;
  k uuid;
  v_previews jsonb := '[]';
  v_checks jsonb;
  v_program uuid;
  v_applied jsonb;
  v_confirmed uuid[] := '{}';
  v_moved int := 0;
  v_people int;
  v_msgs int;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform private.require_team();
  if p_weeks is null or p_weeks not between 1 and 26 then
    raise exception 'A break is 1 to 26 weeks.' using errcode = '22023';
  end if;
  if v_reason is null then
    raise exception 'Say what the break is for, for example Diwali or a program break.' using errcode = '22023';
  end if;
  if p_starts_on is null then raise exception 'Choose the first day of the break.' using errcode = '22023'; end if;
  if p_program then
    v_cohorts := array(select c.id from public.cohort c where c.domain_id = p_domain_id and c.archived_at is null order by c.name);
  else
    v_cohorts := array(select c.id from public.cohort c where c.id = any (coalesce(p_cohort_ids, '{}'))
                          and c.domain_id = p_domain_id and c.archived_at is null order by c.name);
    if cardinality(v_cohorts) <> cardinality(array(select distinct x from unnest(coalesce(p_cohort_ids, '{}')) x)) then
      raise exception 'Choose cohorts of this domain that are in use.' using errcode = '22023';
    end if;
  end if;
  if cardinality(v_cohorts) = 0 then raise exception 'Choose at least one cohort.' using errcode = '22023'; end if;
  if p_save then perform pg_advisory_xact_lock(hashtext('plan:' || p_domain_id::text)); end if;
  v_now := private.domain_now(p_domain_id);

  foreach k in array v_cohorts loop
    v_previews := v_previews || jsonb_build_array(private.break_preview(k, p_starts_on, p_weeks, p_starts_on, p_weeks, v_reason, null));
  end loop;
  v_checks := private.break_checks(v_previews, p_release_week_ids);
  select (count(distinct w -> 'instructor' ->> 'id') filter (where w -> 'instructor' ->> 'status' = 'Confirmed'))::int into v_people
    from jsonb_array_elements(v_previews) c, jsonb_array_elements(c -> 'weeks') w;
  if not p_save then
    return jsonb_build_object('ok', true, 'preview', true, 'cohorts', v_previews, 'blocks', v_checks -> 'blocks',
      'warnings', v_checks -> 'warnings', 'confirmed_instructors', v_people, 'dates', private.fmt_break(p_starts_on, p_weeks));
  end if;
  if jsonb_array_length(v_checks -> 'blocks') > 0 then
    return jsonb_build_object('ok', false, 'cohorts', v_previews, 'blocks', v_checks -> 'blocks', 'warnings', v_checks -> 'warnings');
  end if;
  if exists (select 1 from jsonb_array_elements(v_checks -> 'warnings') x where x ->> 'level' = 'Warning') and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'cohorts', v_previews, 'blocks', '[]'::jsonb,
      'warnings', v_checks -> 'warnings');
  end if;
  perform private.log_accepted_warnings(v_checks -> 'warnings', p_accept_reason, p_domain_id);

  if p_program then
    insert into public.program_break (domain_id, starts_on, weeks, reason) values (p_domain_id, p_starts_on, p_weeks, v_reason)
    returning id into v_program;
  end if;
  foreach k in array v_cohorts loop
    v_applied := private.apply_cohort_move(k, p_starts_on, p_weeks, p_release_week_ids, v_now);
    insert into public.cohort_break (cohort_id, domain_id, program_break_id, starts_on, weeks, reason, moved)
    values (k, p_domain_id, v_program, p_starts_on, p_weeks, v_reason, v_applied -> 'moved');
    v_confirmed := v_confirmed || array(select x::uuid from jsonb_array_elements_text(v_applied -> 'confirmed') x);
    v_moved := v_moved + jsonb_array_length(v_applied -> 'moved');
  end loop;
  set constraints public.cohort_break_no_overlap immediate;
  set constraints public.cohort_break_no_overlap deferred;
  v_msgs := private.break_messages(v_confirmed,
    'Your classes moved to new dates for a break (' || v_reason || ', ' || private.fmt_break(p_starts_on, p_weeks) || '):', v_now);
  perform private.log_event('Team actions', case when p_program then 'Program break added: ' else 'Break added: ' end || v_reason,
    case when p_program then 'program_break' else 'cohort' end, coalesce(v_program, v_cohorts[1]), null,
    jsonb_build_object('starts_on', p_starts_on, 'weeks', p_weeks, 'cohorts', cardinality(v_cohorts), 'class_weeks_moved', v_moved,
      'released', to_jsonb(coalesce(p_release_week_ids, '{}'))),
    private.fmt_break(p_starts_on, p_weeks), p_domain_id);
  perform private.queue_deliver('break');
  return jsonb_build_object('ok', true, 'saved', v_moved, 'cohorts', cardinality(v_cohorts), 'messages', v_msgs,
    'program_break_id', v_program);
end;
$$;

-- Removes a cohort's break (p_break_id) or a whole program break (p_program_break_id): the classes after it move back
-- by the break, with the same preview and checks. A break that has started can't be removed this way.
create or replace function public.remove_break(p_break_id uuid default null, p_program_break_id uuid default null,
  p_save boolean default false, p_accept_warnings boolean default false, p_accept_reason text default null,
  p_release_week_ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  b record;
  v_domain uuid;
  v_now timestamptz;
  v_previews jsonb := '[]';
  v_prev jsonb;
  v_checks jsonb;
  v_applied jsonb;
  v_confirmed uuid[] := '{}';
  v_moved int := 0;
  v_msgs int;
  v_reason text;
  v_start date;
  v_weeks int;
begin
  perform private.require_team();
  if p_program_break_id is not null then
    select domain_id, reason, starts_on, weeks into v_domain, v_reason, v_start, v_weeks
      from public.program_break where id = p_program_break_id and status = 'Active';
  else
    select domain_id, reason, starts_on, weeks into v_domain, v_reason, v_start, v_weeks
      from public.cohort_break where id = p_break_id and status = 'Active';
  end if;
  if v_domain is null then raise exception 'This break was already removed.' using errcode = '22023'; end if;
  if p_save then perform pg_advisory_xact_lock(hashtext('plan:' || v_domain::text)); end if;
  v_now := private.domain_now(v_domain);
  for b in select x.* from public.cohort_break x
            where x.status = 'Active' and (x.id = p_break_id or (p_program_break_id is not null and x.program_break_id = p_program_break_id))
            order by x.label loop
    v_prev := private.break_preview(b.cohort_id, b.starts_on + 7 * b.weeks, -b.weeks, null, null, null, b.id);
    if b.starts_on < private.cohort_today(b.cohort_id) then
      v_prev := jsonb_set(v_prev, '{blocks}', (v_prev -> 'blocks') || to_jsonb(
        'The break of ' || (v_prev ->> 'cohort') || ' has started, so its classes can''t move back. Change the class weeks one by one instead.'::text));
    end if;
    v_previews := v_previews || jsonb_build_array(v_prev || jsonb_build_object('break_id', b.id));
  end loop;
  v_checks := private.break_checks(v_previews, p_release_week_ids);
  if not p_save then
    return jsonb_build_object('ok', true, 'preview', true, 'cohorts', v_previews, 'blocks', v_checks -> 'blocks',
      'warnings', v_checks -> 'warnings', 'dates', private.fmt_break(v_start, v_weeks));
  end if;
  if jsonb_array_length(v_checks -> 'blocks') > 0 then
    return jsonb_build_object('ok', false, 'cohorts', v_previews, 'blocks', v_checks -> 'blocks', 'warnings', v_checks -> 'warnings');
  end if;
  if exists (select 1 from jsonb_array_elements(v_checks -> 'warnings') x where x ->> 'level' = 'Warning') and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'cohorts', v_previews, 'blocks', '[]'::jsonb,
      'warnings', v_checks -> 'warnings');
  end if;
  perform private.log_accepted_warnings(v_checks -> 'warnings', p_accept_reason, v_domain);
  for b in select x.* from public.cohort_break x
            where x.status = 'Active' and (x.id = p_break_id or (p_program_break_id is not null and x.program_break_id = p_program_break_id))
            order by x.label loop
    update public.cohort_break set status = 'Removed', removed_at = now() where id = b.id;
    v_applied := private.apply_cohort_move(b.cohort_id, b.starts_on + 7 * b.weeks, -b.weeks, p_release_week_ids, v_now);
    v_confirmed := v_confirmed || array(select x::uuid from jsonb_array_elements_text(v_applied -> 'confirmed') x);
    v_moved := v_moved + jsonb_array_length(v_applied -> 'moved');
  end loop;
  if p_program_break_id is not null then
    update public.program_break set status = 'Removed', removed_at = now() where id = p_program_break_id;
  end if;
  set constraints public.cohort_break_no_overlap immediate;
  set constraints public.cohort_break_no_overlap deferred;
  v_msgs := private.break_messages(v_confirmed,
    'A break was removed (' || v_reason || ', ' || private.fmt_break(v_start, v_weeks) || '), so your classes moved back to these dates:', v_now);
  perform private.log_event('Team actions', case when p_program_break_id is not null then 'Program break removed: ' else 'Break removed: ' end || v_reason,
    case when p_program_break_id is not null then 'program_break' else 'cohort_break' end, coalesce(p_program_break_id, p_break_id), null,
    jsonb_build_object('class_weeks_moved', v_moved), private.fmt_break(v_start, v_weeks), v_domain);
  perform private.queue_deliver('break removed');
  return jsonb_build_object('ok', true, 'saved', v_moved, 'messages', v_msgs);
end;
$$;

-- ===================================================================================== cohort holidays

-- A holiday for one cohort. Returns the classes of the cohort on that day, which then show as a problem to fix:
-- move the class, cancel it, or keep it with a reason.
create or replace function public.add_cohort_holiday(p_cohort_id uuid, p_date date, p_name text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_name text := nullif(trim(coalesce(p_name, '')), '');
begin
  perform private.require_team();
  if not exists (select 1 from public.cohort where id = p_cohort_id and archived_at is null) then
    raise exception 'Choose a cohort that is in use.' using errcode = '22023';
  end if;
  if v_name is null then raise exception 'Give the holiday a name.' using errcode = '22023'; end if;
  if p_date is null or p_date < private.cohort_today(p_cohort_id) then
    raise exception 'A cohort holiday can''t be in the past.' using errcode = '22023';
  end if;
  if exists (select 1 from public.cohort_holiday where cohort_id = p_cohort_id and date = p_date) then
    raise exception 'This cohort already has a holiday on %.', to_char(p_date, 'Dy, Mon FMDD') using errcode = '23505';
  end if;
  insert into public.cohort_holiday (cohort_id, domain_id, date, name)
  values (p_cohort_id, (select domain_id from public.cohort where id = p_cohort_id), p_date, v_name)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'classes', coalesce((
    select jsonb_agg(jsonb_build_object('class_id', c.id, 'module_week_id', w.id, 'title', c.title,
             'when', private.fmt_class_range(c.starts_at, c.ends_at, c.region)) order by c.starts_at)
      from public.class_session c join public.module_week w on w.id = c.module_week_id
     where w.cohort_id = p_cohort_id and c.status = 'Planned'
       and (c.starts_at at time zone private.region_tz(c.region))::date = p_date), '[]'));
end;
$$;

create or replace function public.remove_cohort_holiday(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  delete from public.cohort_holiday where id = p_id;
  if not found then raise exception 'This holiday was already removed.' using errcode = '22023'; end if;
end;
$$;

-- Keep a class on its cohort's holiday, with the reason (kept in Activity history). It is then information only.
create or replace function public.keep_class_on_holiday(p_class_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare c public.class_session; w public.module_week; v_day date; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform private.require_team();
  select * into c from public.class_session where id = p_class_id for update;
  select * into w from public.module_week where id = c.module_week_id;
  v_day := (c.starts_at at time zone private.region_tz(c.region))::date;
  if not exists (select 1 from public.cohort_holiday h where h.cohort_id = w.cohort_id and h.date = v_day) then
    raise exception 'This class is not on a holiday of its cohort.' using errcode = '22023';
  end if;
  if v_reason is null then raise exception 'Say why the class stays on the holiday.' using errcode = '22023'; end if;
  update public.class_session set holiday_kept_on = v_day, holiday_kept_reason = v_reason where id = c.id;
  perform private.log_event('Team actions', 'Class kept on a cohort holiday', 'class_session', c.id, null,
    jsonb_build_object('date', v_day), v_reason, w.domain_id, w.module_id, w.id, c.id);
end;
$$;

-- The nightly snapshot includes the breaks and cohort holidays (was 20261122000011_standard_schedules.sql).
create or replace function public.export_snapshot()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare t text; v jsonb := '{}'; r jsonb;
begin
  if not private.is_service() then raise exception 'Not allowed' using errcode = '42501'; end if;
  foreach t in array array['team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
    'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'module_week',
    'class_session', 'request', 'booking', 'checklist_item', 'help_request', 'attention_item', 'setting', 'holiday',
    'standard_schedule', 'standard_schedule_module', 'standard_schedule_break', 'standard_schedule_class',
    'program_break', 'cohort_break', 'cohort_holiday'] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x', t) into r;
    v := v || jsonb_build_object(t, r);
  end loop;
  return v || jsonb_build_object('exported_at', now());
end;
$$;

-- template_defaults: M17, one message for all the class weeks of an instructor that moved for a break
-- (was 20261113000007_no_materials.sql).
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

revoke execute on function private.fmt_break(date, int) from public, anon, authenticated;
revoke execute on function private.break_part_fill() from public, anon, authenticated;
revoke execute on function private.cohort_today(uuid) from public, anon, authenticated;
revoke execute on function private.break_rule_blocks(uuid, date, int, date, int, uuid) from public, anon, authenticated;
revoke execute on function private.move_cohort_weeks(uuid, date, int) from public, anon, authenticated;
revoke execute on function private.break_preview(uuid, date, int, date, int, text, uuid) from public, anon, authenticated;
revoke execute on function private.break_checks(jsonb, uuid[]) from public, anon, authenticated;
revoke execute on function private.apply_cohort_move(uuid, date, int, uuid[], timestamptz) from public, anon, authenticated;
revoke execute on function private.break_messages(uuid[], text, timestamptz) from public, anon, authenticated;
revoke execute on function public.add_break(uuid, uuid[], date, int, text, boolean, boolean, boolean, text, uuid[]) from public, anon;
revoke execute on function public.remove_break(uuid, uuid, boolean, boolean, text, uuid[]) from public, anon;
revoke execute on function public.add_cohort_holiday(uuid, date, text) from public, anon;
revoke execute on function public.remove_cohort_holiday(uuid) from public, anon;
revoke execute on function public.keep_class_on_holiday(uuid, text) from public, anon;
grant execute on function public.add_break(uuid, uuid[], date, int, text, boolean, boolean, boolean, text, uuid[]) to authenticated, service_role;
grant execute on function public.remove_break(uuid, uuid, boolean, boolean, text, uuid[]) to authenticated, service_role;
grant execute on function public.add_cohort_holiday(uuid, date, text) to authenticated, service_role;
grant execute on function public.remove_cohort_holiday(uuid) to authenticated, service_role;
grant execute on function public.keep_class_on_holiday(uuid, text) to authenticated, service_role;
