-- Test data only (Release 3 M6, decision 294). Loaded after the starting data by `npm run e2e:scale` into the separate
-- test stack, never into the app database or a hosted project.
-- A program the size of the team's tracker, with invented names and no import: 6 more domains with 10 cohorts each
-- (60 in all, US and India), 8 modules each with class times and an instructor order of 5, 160 instructors with
-- invented names (not test instructors, so they are never messaged: the test stack sends nothing), and half a year
-- of class weeks per cohort, from 3 months ago to 3 months ahead.
create schema if not exists tests;

create or replace function tests.load_scale_data()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_first text[] := array['Aarav','Priya','Daniel','Mei','Omar','Sofia','Kenji','Lena','Ravi','Grace','Mateo','Anika',
    'Samuel','Yara','Ishaan','Chloe','Tomas','Nadia','Arjun','Elena'];
  v_last text[] := array['Kapoor','Lindqvist','Okafor','Moreau','Tanaka','Silva','Brennan','Iyer'];
  v_names text[] := array['Data Engineering','Machine Learning','DevOps','Product Management','Mobile','Security'];
  v_inst uuid[] := '{}';
  v_owner uuid;
  v_dom uuid; v_mod uuid; v_coh uuid;
  v_i uuid;
  k int; j int; c int;
  v_start date;
  v_rows jsonb;
  n_weeks int := 0;
  v_india boolean;
begin
  perform set_config('app.actor_kind', 'System', true);
  perform set_config('app.actor_label', 'Scale test data', true);
  select id into v_owner from public.team_member where lower(email) like 'sandbox.owner@%' limit 1;

  for k in 1 .. 160 loop
    insert into public.instructor (full_name, primary_email, notes)
    values (v_first[((k - 1) % 20) + 1] || ' ' || v_last[((k - 1) / 20) + 1],
            'scale.instructor' || k || '@example.com', 'Invented for the scale tests.')
    returning id into v_i;
    v_inst := v_inst || v_i;
  end loop;

  for k in 1 .. cardinality(v_names) loop
    insert into public.domain (name, status) values (v_names[k], 'Paused') returning id into v_dom;
    for j in 1 .. 8 loop
      insert into public.module (domain_id, name, rotation_order)
      values (v_dom, v_names[k] || ' module ' || j, j) returning id into v_mod;
      if v_owner is not null then
        insert into public.module_owner (module_id, team_member_id) values (v_mod, v_owner);
      end if;
      insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
      values (v_mod, 'Live class', '{module}: Live class', 0, '09:00', 240, 1),
             (v_mod, 'Assignment review', '{module}: Assignment review', 1, '10:00', 120, 2);
      -- Each domain draws its instructor order from its own 40 instructors (domains share some, as in the tracker).
      insert into public.module_ranking (module_id, instructor_id, rank)
      select v_mod, v_inst[(((k - 1) * 24 + j * 3 + r) % 160) + 1], r + 1 from generate_series(0, 4) r;
    end loop;
    select id into v_mod from public.module where domain_id = v_dom and rotation_order = 1;
    for c in 1 .. 10 loop
      v_india := c % 3 = 0;
      -- A Saturday, staggered so cohorts start in different weeks.
      v_start := (now() at time zone 'America/Los_Angeles')::date
                 + ((6 - extract(dow from now() at time zone 'America/Los_Angeles')::int + 7) % 7) - 7 * (13 - c);
      insert into public.cohort (domain_id, name, start_date, status, region)
      values (v_dom, 'Cohort ' || c, v_start, 'Running', case when v_india then 'India' else 'US' end)
      returning id into v_coh;
      v_rows := public.generate_classes(v_dom, v_mod, array(select v_start + 7 * w from generate_series(0, 25) w), 'Cohort ' || c);
      n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Scale test data') ->> 'created')::int, 0);
    end loop;
  end loop;
  return jsonb_build_object('domains', cardinality(v_names), 'cohorts', 10 * cardinality(v_names),
    'instructors', cardinality(v_inst), 'class_weeks', n_weeks);
end;
$$;
