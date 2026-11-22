-- Release 3, M7b part 1 (decision 298): standard schedules.
--
-- A domain can have named standard schedules (its tracks, for example "SWEs | DEs"). Each holds a module order, its
-- own class times per module (else the module's own), and regular break weeks. A new cohort can be planned from one,
-- alone or several at once, with a preview of every class week and every check first; it is created through the same
-- planning as Plan classes (create_module_weeks). Each class week remembers its place in the standard; the first time
-- its dates, times, classes or module change it is marked Custom, and a cohort shows "Standard" or "Custom (N
-- changes)". A cohort without a standard is fully custom (every cohort that exists before this migration).
--
-- Built on what exists, nothing rebuilt: Plan classes' row builder is moved into private.plan_week_row so the standard
-- and Plan classes share it (generate_classes returns exactly what it did). The standard's own class times are in a
-- table of their own, so every reader of a module's class times stays as it is. Reset to standard and applying a
-- changed standard to its cohorts are part 2.

create table public.standard_schedule (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  notes text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index standard_schedule_name_uq on public.standard_schedule (domain_id, lower(name));

create table public.standard_schedule_module (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.standard_schedule (id) on delete cascade,
  domain_id uuid not null references public.domain (id) on delete cascade,
  module_id uuid not null references public.module (id) on delete cascade,
  position int not null check (position >= 1),
  label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (schedule_id, position),
  unique (schedule_id, module_id)
);
create index standard_schedule_module_module_idx on public.standard_schedule_module (module_id);
create index standard_schedule_module_domain_idx on public.standard_schedule_module (domain_id);

create table public.standard_schedule_break (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.standard_schedule (id) on delete cascade,
  domain_id uuid not null references public.domain (id) on delete cascade,
  after_position int not null check (after_position >= 1),
  weeks int not null check (weeks between 1 and 8),
  label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (schedule_id, after_position)
);
create index standard_schedule_break_domain_idx on public.standard_schedule_break (domain_id);

-- The standard's own class times for a module; a module without any here uses its own class times.
create table public.standard_schedule_class (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.standard_schedule (id) on delete cascade,
  domain_id uuid not null references public.domain (id) on delete cascade,
  module_id uuid not null references public.module (id) on delete cascade,
  class_type text not null check (length(trim(class_type)) > 0),
  title_template text not null default '{module}: {class_type}',
  day_offset int not null default 0 check (day_offset between 0 and 6),
  start_time time not null,
  duration_minutes int not null check (duration_minutes between 15 and 600),
  sort_order int not null default 1,
  label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create index standard_schedule_class_schedule_idx on public.standard_schedule_class (schedule_id, module_id);
create index standard_schedule_class_module_idx on public.standard_schedule_class (module_id);
create index standard_schedule_class_domain_idx on public.standard_schedule_class (domain_id);

alter table public.cohort add column standard_schedule_id uuid references public.standard_schedule (id) on delete set null;
create index cohort_standard_schedule_idx on public.cohort (standard_schedule_id);
-- Its place in the standard (null: added outside the standard), and when it first differed from it.
alter table public.module_week add column standard_position int, add column customized_at timestamptz;

-- The parts of a standard belong to its domain, and only modules of that domain can be in it. The label is what
-- Activity history shows.
create or replace function private.standard_part_fill()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare s public.standard_schedule; v_mod text;
begin
  select * into s from public.standard_schedule where id = new.schedule_id;
  new.domain_id := s.domain_id;
  if tg_table_name <> 'standard_schedule_break' then
    select name into v_mod from public.module where id = new.module_id and domain_id = s.domain_id;
    if v_mod is null then
      raise exception 'Only modules of this domain can be in its standard schedules.' using errcode = '22023';
    end if;
  end if;
  -- One branch per table: each reads only its own columns.
  if tg_table_name = 'standard_schedule_module' then
    new.label := s.name || ': ' || new.position || '. ' || v_mod;
  elsif tg_table_name = 'standard_schedule_break' then
    new.label := s.name || ': ' || new.weeks || ' week break after module ' || new.after_position;
  else
    new.label := s.name || ': ' || v_mod || ', ' || new.class_type;
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['standard_schedule', 'standard_schedule_module', 'standard_schedule_break', 'standard_schedule_class'] loop
    if t <> 'standard_schedule' then
      execute format('create trigger %I before insert or update on public.%I for each row execute function private.standard_part_fill()', t || '_fill', t);
    end if;
    execute format('create trigger %I before update on public.%I for each row execute function private.touch_row()', t || '_touch', t);
    execute format('create trigger %I before insert on public.%I for each row execute function private.set_created_by()', t || '_created_by', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function private.log_setup_change()', t || '_history', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('create policy %I on public.%I for select to authenticated using (private.is_team_user())', t || '_team_read', t);
    if t = 'standard_schedule_class' then
      -- Class times are edited on the page like a module's own class times.
      execute format('grant select, insert, update, delete on public.%I to authenticated', t);
      execute format('create policy %I on public.%I for insert to authenticated with check (private.is_team_user())', t || '_team_insert', t);
      execute format('create policy %I on public.%I for update to authenticated using (private.is_team_user()) with check (private.is_team_user())', t || '_team_update', t);
      execute format('create policy %I on public.%I for delete to authenticated using (private.is_team_user())', t || '_team_delete', t);
    else
      -- The name, the module order and the breaks change only through save_standard_schedule, which checks them.
      execute format('grant select on public.%I to authenticated', t);
    end if;
  end loop;
end;
$$;

-- Plan classes' row builder, shared by Plan classes and the standard schedules: one class week of one module from
-- the given class times (jsonb objects with the columns of class_pattern_item), with every check.
create or replace function private.plan_week_row(p_domain uuid, p_module uuid, p_week_start date, p_patterns jsonb,
  p_region text, p_cohort_id uuid, p_cohort_name text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  m public.module;
  v_min int;
  v_classes jsonb := '[]';
  v_warn jsonb := '[]';
  v_problem text;
  p jsonb;
  v_day date;
  v_st time;
  v_dur int;
  v_title text;
  v_cand timestamptz[];
  v_s timestamptz;
  v_e timestamptz;
begin
  select * into m from public.module where id = p_module;
  select min((x ->> 'day_offset')::int) into v_min from jsonb_array_elements(coalesce(p_patterns, '[]')) x;
  for p in select * from jsonb_array_elements(coalesce(p_patterns, '[]')) loop
    v_day := p_week_start + ((p ->> 'day_offset')::int - v_min);
    v_st := (p ->> 'start_time')::time;
    v_dur := (p ->> 'duration_minutes')::int;
    v_title := replace(replace(p ->> 'title_template', '{module}', m.name), '{class_type}', p ->> 'class_type');
    v_cand := private.local_candidates(v_day, v_st, p_region);
    if cardinality(v_cand) = 0 then
      v_problem := coalesce(v_problem || ' ', '') || to_char(v_st, 'FMHH12:MI AM') || ' on '
        || to_char(v_day, 'Dy, Mon FMDD') || ' does not exist in US Pacific time (the clocks move forward). Change this class after planning, or plan this week by itself.';
      continue;
    end if;
    v_s := v_cand[1];
    v_e := v_s + make_interval(mins => v_dur);
    v_classes := v_classes || jsonb_build_object(
      'pattern_item_id', p -> 'id', 'class_type', p ->> 'class_type',
      'title', v_title,
      'date', v_day, 'start_time', to_char(v_st, 'HH24:MI'),
      'end_time', to_char(v_st + make_interval(mins => v_dur), 'HH24:MI'),
      'region', p_region, 'ambiguous', cardinality(v_cand) = 2,
      'starts_at', v_s, 'ends_at', v_e, 'shown', private.fmt_class_range(v_s, v_e, p_region),
      'holiday', private.holiday_on(p_domain, v_day, p_region));
    v_warn := v_warn || private.class_warnings(p_domain, p_cohort_id, v_s, v_e, null, v_title, p_region)
      || coalesce(jsonb_path_query_array(jsonb_build_array(private.ambiguous_warning(v_day, v_st, p_region, v_title)), '$[*] ? (@ != null)'), '[]');
  end loop;
  return jsonb_build_object('week_start_date', p_week_start, 'module_id', p_module, 'module_name', m.name,
    'cohort', p_cohort_name, 'same_instructor', m.same_instructor_for_module_week,
    'classes', v_classes, 'warnings', v_warn,
    'region', p_region,
    'problem', case when jsonb_array_length(v_classes) = 0 and v_problem is null
                    then m.name || ' has no class times yet. Add them on the module page before planning.' else v_problem end,
    'duplicate', p_cohort_id is not null and exists (select 1 from public.module_week w where w.module_id = p_module and w.cohort_id = p_cohort_id
                                                       and w.week_start_date = p_week_start and w.status <> 'Cancelled'),
    'holidays', (select coalesce(jsonb_agg(h.name), '[]') from public.holiday h where h.date between p_week_start and p_week_start + 6
                                and (h.domain_id is null or h.domain_id = p_domain) and (h.region is null or h.region = p_region)));
end;
$$;

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
  v_cohort uuid;
  v_region text;
begin
  perform private.require_team();
  select array_agg(id order by rotation_order, name) into v_mods from public.module where domain_id = p_domain_id and status = 'Active';
  if v_mods is null then raise exception 'This domain has no active modules yet.'; end if;
  v_start := coalesce(array_position(v_mods, p_start_module_id), 1);
  select id, region into v_cohort, v_region from public.cohort where domain_id = p_domain_id and lower(name) = lower(coalesce(nullif(trim(p_cohort), ''), 'Main cohort'));
  -- A new cohort uses the region chosen for it; an existing cohort keeps its own.
  v_region := coalesce(case when v_cohort is null then p_region end, v_region, p_region, 'US');
  for i in 1 .. coalesce(cardinality(p_week_starts), 0) loop
    v_mod := v_mods[((v_start - 1 + i - 1) % cardinality(v_mods)) + 1];
    v_out := v_out || private.plan_week_row(p_domain_id, v_mod, p_week_starts[i],
      (select coalesce(jsonb_agg(to_jsonb(p) order by p.day_offset, p.start_time, p.sort_order), '[]') from private.pattern_for(v_mod, v_cohort) p),
      v_region, v_cohort, coalesce(nullif(trim(p_cohort), ''), 'Main cohort'));
  end loop;
  return v_out;
end;
$$;

-- The class times a standard uses for a module: its own, else the module's own.
create or replace function private.standard_patterns(p_schedule uuid, p_module uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select case
    when exists (select 1 from public.standard_schedule_class x where x.schedule_id = p_schedule and x.module_id = p_module) then
      (select jsonb_agg(jsonb_build_object('id', null, 'class_type', x.class_type, 'title_template', x.title_template,
                 'day_offset', x.day_offset, 'start_time', x.start_time, 'duration_minutes', x.duration_minutes, 'sort_order', x.sort_order)
                 order by x.day_offset, x.start_time, x.sort_order)
         from public.standard_schedule_class x where x.schedule_id = p_schedule and x.module_id = p_module)
    else
      (select coalesce(jsonb_agg(to_jsonb(p) order by p.day_offset, p.start_time, p.sort_order), '[]')
         from public.class_pattern_item p where p.module_id = p_module and p.cohort_id is null)
  end;
$$;

-- Each module's week in a standard that starts on p_start: one week per module, plus the standard's breaks.
create or replace function private.standard_weeks(p_schedule uuid, p_start date)
returns table (pos int, module_id uuid, week_start date) language sql stable security definer set search_path = ''
as $$
  select m.position, m.module_id,
         p_start + 7 * (m.position - 1 + coalesce((select sum(b.weeks) from public.standard_schedule_break b
                                                    where b.schedule_id = p_schedule and b.after_position < m.position), 0))::int
    from public.standard_schedule_module m where m.schedule_id = p_schedule
   order by m.position;
$$;

-- Create or change a standard schedule: its name, module order and breaks, all checked. Its class times are edited
-- on the page (standard_schedule_class). Cohorts that follow it are not changed here (part 2 updates them).
create or replace function public.save_standard_schedule(p_id uuid, p_domain_id uuid, p_name text, p_module_ids uuid[],
  p_breaks jsonb default '[]', p_notes text default null, p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  s public.standard_schedule;
  v_name text := trim(coalesce(p_name, ''));
  v_n int := coalesce(cardinality(p_module_ids), 0);
  b jsonb;
  v_after int[] := '{}';
  i int;
begin
  perform private.require_team();
  if p_id is not null then
    select * into s from public.standard_schedule where id = p_id for update;
    if s.id is null then raise exception 'This standard schedule no longer exists.' using errcode = '22023'; end if;
    if p_expected_version is not null and s.version <> p_expected_version then
      raise exception 'Someone else saved this standard schedule after you opened it. Reload the page to see their changes, then try again.' using errcode = '40001';
    end if;
  elsif not exists (select 1 from public.domain where id = p_domain_id) then
    raise exception 'Choose a domain.' using errcode = '22023';
  end if;
  if v_name = '' then raise exception 'Give the standard schedule a name.' using errcode = '22023'; end if;
  if exists (select 1 from public.standard_schedule x where x.domain_id = coalesce(s.domain_id, p_domain_id)
              and lower(x.name) = lower(v_name) and x.id is distinct from p_id) then
    raise exception 'This domain already has a standard schedule named %.', v_name using errcode = '23505';
  end if;
  if v_n = 0 then raise exception 'Add at least one module to the standard schedule.' using errcode = '22023'; end if;
  if (select count(distinct x) from unnest(p_module_ids) x) <> v_n then
    raise exception 'Each module can be in a standard schedule once.' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_module_ids) x left join public.module m on m.id = x
              where m.id is null or m.domain_id <> coalesce(s.domain_id, p_domain_id) or m.status <> 'Active') then
    raise exception 'Only active modules of this domain can be in its standard schedules.' using errcode = '22023';
  end if;
  for b in select * from jsonb_array_elements(coalesce(p_breaks, '[]')) loop
    if coalesce((b ->> 'after_position')::int, 0) not between 1 and v_n - 1 then
      raise exception 'A break goes between two modules of the standard schedule.' using errcode = '22023';
    end if;
    if coalesce((b ->> 'weeks')::int, 0) not between 1 and 8 then
      raise exception 'A break lasts 1 to 8 weeks.' using errcode = '22023';
    end if;
    if (b ->> 'after_position')::int = any (v_after) then
      raise exception 'There is already a break after module %.', b ->> 'after_position' using errcode = '22023';
    end if;
    v_after := v_after || (b ->> 'after_position')::int;
  end loop;

  if s.id is null then
    insert into public.standard_schedule (domain_id, name, notes) values (p_domain_id, v_name, nullif(trim(coalesce(p_notes, '')), ''))
    returning * into s;
  elsif s.name is distinct from v_name or s.notes is distinct from nullif(trim(coalesce(p_notes, '')), '') then
    update public.standard_schedule set name = v_name, notes = nullif(trim(coalesce(p_notes, '')), '') where id = s.id returning * into s;
  end if;
  -- Only what changed is saved, so Activity history shows only real changes.
  if array(select module_id from public.standard_schedule_module where schedule_id = s.id order by position) is distinct from p_module_ids then
    delete from public.standard_schedule_module where schedule_id = s.id;
    for i in 1 .. v_n loop
      insert into public.standard_schedule_module (schedule_id, module_id, position) values (s.id, p_module_ids[i], i);
    end loop;
  end if;
  if (select coalesce(jsonb_agg(jsonb_build_object('after_position', after_position, 'weeks', weeks) order by after_position), '[]')
        from public.standard_schedule_break where schedule_id = s.id)
     is distinct from
     (select coalesce(jsonb_agg(jsonb_build_object('after_position', (x ->> 'after_position')::int, 'weeks', (x ->> 'weeks')::int)
                                order by (x ->> 'after_position')::int), '[]')
        from jsonb_array_elements(coalesce(p_breaks, '[]')) x) then
    delete from public.standard_schedule_break where schedule_id = s.id;
    insert into public.standard_schedule_break (schedule_id, after_position, weeks)
    select s.id, (x ->> 'after_position')::int, (x ->> 'weeks')::int from jsonb_array_elements(coalesce(p_breaks, '[]')) x;
  end if;
  return jsonb_build_object('id', s.id, 'version', (select version from public.standard_schedule where id = s.id));
end;
$$;

create or replace function public.archive_standard_schedule(p_id uuid, p_archived boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  update public.standard_schedule set archived_at = case when p_archived then coalesce(archived_at, now()) end where id = p_id;
  if not found then raise exception 'This standard schedule no longer exists.' using errcode = '22023'; end if;
end;
$$;

-- The preview of new cohorts from a standard: every class week with every check. Blocks stop the plan; warnings need
-- a reason when it is saved; "the Primary already teaches then" is information.
create or replace function public.preview_standard_cohorts(p_schedule_id uuid, p_cohorts jsonb)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  s public.standard_schedule;
  c jsonb;
  v_name text;
  v_start date;
  v_region text;
  v_names text[] := '{}';
  v_out jsonb := '[]';
  v_blocks jsonb := '[]';
  v_warn jsonb := '[]';
  v_weeks jsonb;
  w record;
  v_row jsonb;
  x jsonb;
  v_primary uuid;
  v_pname text;
begin
  perform private.require_team();
  select * into s from public.standard_schedule where id = p_schedule_id;
  if s.id is null then raise exception 'Choose a standard schedule.' using errcode = '22023'; end if;
  if s.archived_at is not null then raise exception 'This standard schedule is archived. Restore it first.' using errcode = '22023'; end if;
  if not exists (select 1 from public.standard_schedule_module where schedule_id = s.id) then
    raise exception 'Add modules to this standard schedule first.' using errcode = '22023';
  end if;
  if coalesce(jsonb_array_length(p_cohorts), 0) = 0 then raise exception 'Add at least one cohort.' using errcode = '22023'; end if;
  if jsonb_array_length(p_cohorts) > 20 then raise exception 'Plan at most 20 cohorts at a time.' using errcode = '22023'; end if;
  for c in select * from jsonb_array_elements(p_cohorts) loop
    v_name := trim(coalesce(c ->> 'name', ''));
    v_start := nullif(c ->> 'start_date', '')::date;
    v_region := coalesce(nullif(c ->> 'region', ''), 'US');
    if v_name = '' then
      v_blocks := v_blocks || to_jsonb('Give each new cohort a name.'::text);
    elsif exists (select 1 from public.cohort x where x.domain_id = s.domain_id and lower(x.name) = lower(v_name)) then
      v_blocks := v_blocks || to_jsonb('A cohort named ' || v_name || ' already exists in this domain.');
    elsif lower(v_name) = any (v_names) then
      v_blocks := v_blocks || to_jsonb('Two new cohorts are both named ' || v_name || '.');
    end if;
    if v_start is null then
      v_blocks := v_blocks || to_jsonb('Choose a start date for ' || coalesce(nullif(v_name, ''), 'each new cohort') || '.');
    end if;
    if v_region not in ('US', 'India') then
      v_blocks := v_blocks || to_jsonb('Choose US or India for ' || coalesce(nullif(v_name, ''), 'each new cohort') || '.');
    end if;
    v_names := v_names || lower(v_name);
    v_weeks := '[]';
    if v_start is not null and v_region in ('US', 'India') then
      for w in select * from private.standard_weeks(s.id, v_start) loop
        v_row := private.plan_week_row(s.domain_id, w.module_id, w.week_start, private.standard_patterns(s.id, w.module_id),
                                       v_region, null, v_name) || jsonb_build_object('standard_position', w.pos);
        if v_row ->> 'problem' is not null then
          v_blocks := v_blocks || to_jsonb(v_name || ', week of ' || to_char(w.week_start, 'Mon FMDD') || ': ' || (v_row ->> 'problem'));
        end if;
        -- The Primary of the module's instructor order, if they already teach at one of these times.
        select k.instructor_id, i.full_name into v_primary, v_pname
          from public.module_ranking k join public.instructor i on i.id = k.instructor_id
         where k.module_id = w.module_id and k.cohort_id is null order by k.rank limit 1;
        if v_primary is not null then
          for x in select * from jsonb_array_elements(v_row -> 'classes') loop
            if private.clash_text(v_primary, (x ->> 'starts_at')::timestamptz, (x ->> 'ends_at')::timestamptz, v_region) is not null then
              v_row := jsonb_set(v_row, '{warnings}', (v_row -> 'warnings') || jsonb_build_array(jsonb_build_object(
                'code', 'primary_busy', 'level', 'Information',
                'text', v_pname || ' (Primary) already teaches at the time of ' || (x ->> 'title') || ' (' || (x ->> 'shown')
                        || '), so the next instructor in the order would be asked.')));
              exit;
            end if;
          end loop;
        end if;
        v_weeks := v_weeks || v_row;
        v_warn := v_warn || (v_row -> 'warnings');
      end loop;
    end if;
    v_out := v_out || jsonb_build_object('name', v_name, 'start_date', v_start, 'region', v_region, 'weeks', v_weeks);
  end loop;
  return jsonb_build_object('schedule', s.name, 'cohorts', v_out, 'blocks', v_blocks, 'warnings', v_warn);
end;
$$;

-- Create the cohorts and their class weeks exactly as previewed, through Plan classes' own saving.
create or replace function public.create_standard_cohorts(p_schedule_id uuid, p_cohorts jsonb,
  p_accept_warnings boolean default false, p_reason text default null, p_fold int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  s public.standard_schedule;
  v jsonb;
  c jsonb;
  w jsonb;
  v_cohort uuid;
  v_rows jsonb := '[]';
  v_res jsonb;
  v_ids uuid[] := '{}';
  v_weeks int;
begin
  v := public.preview_standard_cohorts(p_schedule_id, p_cohorts);
  if jsonb_array_length(v -> 'blocks') > 0 then
    raise exception '%', v -> 'blocks' ->> 0 using errcode = '22023';
  end if;
  if p_fold is null and exists (select 1 from jsonb_array_elements(v -> 'cohorts') c2, jsonb_array_elements(c2 -> 'weeks') w2,
                                         jsonb_array_elements(w2 -> 'classes') k where (k ->> 'ambiguous')::boolean) then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'needs_choice', true,
      'warnings', (select jsonb_agg(x) from jsonb_array_elements(v -> 'warnings') x where x ->> 'code' = 'ambiguous_time'));
  end if;
  if jsonb_array_length(v -> 'warnings') > 0 and not p_accept_warnings then
    return v || jsonb_build_object('ok', false, 'needs_confirmation', true);
  end if;
  select * into s from public.standard_schedule where id = p_schedule_id;
  perform set_config('app.standard_apply', 'on', true);
  for c in select * from jsonb_array_elements(v -> 'cohorts') loop
    insert into public.cohort (domain_id, name, start_date, status, region, standard_schedule_id)
    values (s.domain_id, c ->> 'name', (c ->> 'start_date')::date, 'Planned', c ->> 'region', s.id)
    returning id into v_cohort;
    v_ids := v_ids || v_cohort;
    for w in select * from jsonb_array_elements(c -> 'weeks') loop
      v_rows := v_rows || (w || jsonb_build_object('cohort_id', v_cohort));
    end loop;
  end loop;
  v_res := public.create_module_weeks(s.domain_id, v_rows, true, p_reason, p_fold);
  if coalesce((v_res ->> 'needs_confirmation')::boolean, false) then
    raise exception 'These class weeks need a decision first. Plan them again from the preview.' using errcode = '22023';
  end if;
  update public.module_week mw set standard_position = (r ->> 'standard_position')::int
    from jsonb_array_elements(v_rows) r
   where mw.cohort_id = (r ->> 'cohort_id')::uuid and mw.module_id = (r ->> 'module_id')::uuid
     and mw.week_start_date = (r ->> 'week_start_date')::date and mw.standard_position is null;
  get diagnostics v_weeks = row_count;
  perform set_config('app.standard_apply', 'off', true);
  perform private.log_event('Team actions', 'Cohorts planned from a standard', 'standard_schedule', s.id, null,
    jsonb_build_object('schedule', s.name, 'cohorts', (select jsonb_agg(x ->> 'name') from jsonb_array_elements(v -> 'cohorts') x),
                       'class_weeks', v_weeks),
    nullif(trim(coalesce(p_reason, '')), ''), s.domain_id);
  return jsonb_build_object('ok', true, 'cohort_ids', to_jsonb(v_ids), 'class_weeks', v_weeks);
end;
$$;

-- A class week that followed its standard becomes Custom the first time its dates, times, classes or module change.
-- Reset to standard and updating from the standard (part 2) set app.standard_apply, so they do not count.
create or replace function private.mark_week_custom()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_mw uuid; v_prev text;
begin
  if coalesce(current_setting('app.standard_apply', true), '') = 'on' then return null; end if;
  if tg_table_name = 'class_session' then
    if tg_op = 'UPDATE' and (old.starts_at, old.ends_at, old.region) is not distinct from (new.starts_at, new.ends_at, new.region)
       and (old.status = 'Cancelled') = (new.status = 'Cancelled') then
      return null;
    end if;
    v_mw := case when tg_op = 'DELETE' then old.module_week_id else new.module_week_id end;
  else
    if (old.module_id, old.week_start_date) is not distinct from (new.module_id, new.week_start_date)
       and (old.status = 'Cancelled') = (new.status = 'Cancelled') then
      return null;
    end if;
    v_mw := new.id;
  end if;
  -- The mark itself is not a setup change of its own in Activity history (the change that caused it is).
  v_prev := current_setting('app.suppress_setup_log', true);
  perform set_config('app.suppress_setup_log', 'on', true);
  update public.module_week w set customized_at = now()
   where w.id = v_mw and w.standard_position is not null and w.customized_at is null
     and exists (select 1 from public.cohort c where c.id = w.cohort_id and c.standard_schedule_id is not null);
  perform set_config('app.suppress_setup_log', coalesce(v_prev, ''), true);
  return null;
end;
$$;
create trigger class_session_mark_custom after insert or delete or update of starts_at, ends_at, region, status
  on public.class_session for each row execute function private.mark_week_custom();
create trigger module_week_mark_custom after update of module_id, week_start_date, status
  on public.module_week for each row execute function private.mark_week_custom();

-- "Standard", "Custom (N changes)" or "Fully custom" for each cohort of a domain. A change is a class week that
-- differs from the standard or was added outside it.
create or replace function public.cohort_schedule_status(p_domain_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.require_team();
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'cohort_id', c.id, 'standard_schedule_id', c.standard_schedule_id, 'schedule', s.name, 'changes', n.n,
            'mode', case when c.standard_schedule_id is null then 'Fully custom' when n.n = 0 then 'Standard' else 'Custom' end)
          order by c.name), '[]')
     from public.cohort c left join public.standard_schedule s on s.id = c.standard_schedule_id
     cross join lateral (select count(*)::int as n from public.module_week w
                          where c.standard_schedule_id is not null and w.cohort_id = c.id
                            and (w.customized_at is not null or (w.standard_position is null and w.status <> 'Cancelled'))) n
    where c.domain_id = p_domain_id and c.archived_at is null);
end;
$$;

-- The nightly snapshot includes the standard schedules.
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

revoke execute on function private.standard_part_fill() from public, anon, authenticated;
revoke execute on function private.plan_week_row(uuid, uuid, date, jsonb, text, uuid, text) from public, anon, authenticated;
revoke execute on function private.standard_patterns(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.standard_weeks(uuid, date) from public, anon, authenticated;
revoke execute on function private.mark_week_custom() from public, anon, authenticated;
revoke execute on function public.save_standard_schedule(uuid, uuid, text, uuid[], jsonb, text, int) from public, anon;
revoke execute on function public.archive_standard_schedule(uuid, boolean) from public, anon;
revoke execute on function public.preview_standard_cohorts(uuid, jsonb) from public, anon;
revoke execute on function public.create_standard_cohorts(uuid, jsonb, boolean, text, int) from public, anon;
revoke execute on function public.cohort_schedule_status(uuid) from public, anon;
grant execute on function public.save_standard_schedule(uuid, uuid, text, uuid[], jsonb, text, int) to authenticated, service_role;
grant execute on function public.archive_standard_schedule(uuid, boolean) to authenticated, service_role;
grant execute on function public.preview_standard_cohorts(uuid, jsonb) to authenticated, service_role;
grant execute on function public.create_standard_cohorts(uuid, jsonb, boolean, text, int) to authenticated, service_role;
grant execute on function public.cohort_schedule_status(uuid) to authenticated, service_role;
