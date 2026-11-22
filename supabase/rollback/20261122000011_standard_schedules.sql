-- Rollback of 20261122000011_standard_schedules.sql (decision 298). Removes the standard schedules and their marks on
-- cohorts and class weeks (the class weeks and classes themselves stay), and restores Plan classes and the nightly
-- snapshot as they were, copied byte for byte from the migrations that defined them last.

drop trigger if exists class_session_mark_custom on public.class_session;
drop trigger if exists module_week_mark_custom on public.module_week;
drop function if exists public.cohort_schedule_status(uuid);
drop function if exists public.create_standard_cohorts(uuid, jsonb, boolean, text, int);
drop function if exists public.preview_standard_cohorts(uuid, jsonb);
drop function if exists public.archive_standard_schedule(uuid, boolean);
drop function if exists public.save_standard_schedule(uuid, uuid, text, uuid[], jsonb, text, int);
drop function if exists private.mark_week_custom();
drop function if exists private.standard_weeks(uuid, date);
drop function if exists private.standard_patterns(uuid, uuid);

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

create or replace function public.export_snapshot()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare t text; v jsonb := '{}'; r jsonb;
begin
  if not private.is_service() then raise exception 'Not allowed' using errcode = '42501'; end if;
  foreach t in array array['team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
    'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'module_week',
    'class_session', 'request', 'booking', 'checklist_item', 'help_request', 'attention_item', 'setting', 'holiday'] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x', t) into r;
    v := v || jsonb_build_object(t, r);
  end loop;
  return v || jsonb_build_object('exported_at', now());
end;
$$;

drop function if exists private.plan_week_row(uuid, uuid, date, jsonb, text, uuid, text);
alter table public.module_week drop column if exists standard_position, drop column if exists customized_at;
alter table public.cohort drop column if exists standard_schedule_id;
drop table if exists public.standard_schedule_class;
drop table if exists public.standard_schedule_break;
drop table if exists public.standard_schedule_module;
drop table if exists public.standard_schedule;
drop function if exists private.standard_part_fill();
