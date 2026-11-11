-- Test data only (decision 250). Loaded by scripts/src/demo-data.ts into the separate test stack, never into
-- the app database or a hosted project: the app itself always starts empty.
-- Two domains (Backend and Fullstack), each with a weekend (US) and a weekday cohort (US for Backend, India
-- for Fullstack), three modules with class times and an instructor order, six test instructors, three made up
-- team members and eight weeks of classes per cohort.
create schema if not exists tests;

create or replace function tests.load_starting_data(p_test_email text default null, p_test_discord_user_id text default null,
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
    insert into public.domain (name, status, alert_discord_channel_id, test_discord_channel_id, test_email, discord_server_id)
    values (d.name, 'Test', v_chan, v_chan, lower(v_local || '+testing@' || v_mail_domain),
            (select c.discord_guild_id from public.app_config c where c.id = 1))
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
