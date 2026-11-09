-- Test helpers (schema "tests"). This file runs first and is NOT rolled back, so the helpers are
-- available to every other test file. Every test file itself runs inside begin … rollback.
create extension if not exists pgtap with schema extensions;
create schema if not exists tests;

-- Sign in as an API user with the given email (role authenticated). Use tests.as_postgres() to undo.
create or replace function tests.login_as(p_email text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'email', p_email)::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  execute 'set local role authenticated';
end $$;

create or replace function tests.login_anon()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  execute 'set local role anon';
end $$;

create or replace function tests.as_postgres()
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

create or replace function tests.rand_discord()
returns text language sql as $$
  select (100000000000000000 + floor(random() * 800000000000000000))::bigint::text;
$$;

create or replace function tests.company()
returns void language sql as $$
  update public.app_config set company_email_domain = 'example.com' where id = 1;
$$;

create or replace function tests.make_team_member(p_name text, p_label text default 'Ops')
returns uuid language sql as $$
  insert into public.team_member (name, email, discord_user_id, label)
  values (p_name, lower(replace(p_name, ' ', '.')) || '@example.com', tests.rand_discord(), p_label)
  returning id;
$$;

create or replace function tests.make_domain(p_name text, p_status text default 'Live')
returns uuid language plpgsql as $$
declare v uuid; v_ops uuid; v_lead uuid;
begin
  insert into public.domain (name, status, alert_discord_channel_id, test_discord_channel_id, test_email)
  values (p_name, p_status, tests.rand_discord(), tests.rand_discord(), 'test-inbox@example.com')
  returning id into v;
  v_ops := tests.make_team_member(p_name || ' Ops', 'Ops');
  v_lead := tests.make_team_member(p_name || ' Lead', 'Lead');
  insert into public.domain_team (domain_id, team_member_id, role) values (v, v_ops, 'Ops'), (v, v_lead, 'Lead');
  return v;
end $$;

create or replace function tests.make_instructor(p_name text, p_verified boolean default true, p_is_test boolean default false)
returns uuid language sql as $$
  insert into public.instructor (full_name, primary_email, discord_user_id, discord_channel_id, verified_at, is_test)
  values (p_name, lower(replace(p_name, ' ', '.')) || '@example.org', tests.rand_discord(), tests.rand_discord(),
          case when p_verified then now() end, p_is_test)
  returning id;
$$;

-- Module with the standard 2-class pattern (Sun 9:00–13:00 live, Thu 18:00–20:00 review), an owner
-- and one resource.
create or replace function tests.make_module(p_domain uuid, p_name text, p_order int default 1, p_with_owner boolean default true)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.module (domain_id, name, rotation_order) values (p_domain, p_name, p_order) returning id into v;
  insert into public.class_pattern_item (module_id, class_type, title_template, weekday_offset, start_time_pt, duration_minutes, sort_order)
  values (v, 'Live class', '{module} — Live class', 0, '09:00', 240, 1),
         (v, 'Assignment review', '{module} — Assignment review', 4, '18:00', 120, 2);
  insert into public.module_resource (module_id, title, url) values (v, p_name || ' module page', 'https://example.com/' || v);
  if p_with_owner then
    insert into public.module_owner (module_id, team_member_id) values (v, tests.make_team_member(p_name || ' Owner', 'PM'));
  end if;
  return v;
end $$;

create or replace function tests.rank(p_module uuid, variadic p_instructors uuid[])
returns void language plpgsql as $$
declare i int;
begin
  delete from public.module_ranking where module_id = p_module;
  for i in 1 .. array_length(p_instructors, 1) loop
    insert into public.module_ranking (module_id, instructor_id, rank) values (p_module, p_instructors[i], i);
  end loop;
end $$;

-- Module week + classes from the module's pattern (week_start_date is the Sunday).
create or replace function tests.make_week(p_module uuid, p_week_start date, p_cohort text default '')
returns uuid language plpgsql as $$
declare v uuid; p record; v_mod text;
begin
  select name into v_mod from public.module where id = p_module;
  insert into public.module_week (module_id, week_start_date, cohort) values (p_module, p_week_start, p_cohort)
  returning id into v;
  for p in select * from public.class_pattern_item where module_id = p_module order by sort_order loop
    insert into public.class_session (module_week_id, pattern_item_id, class_type, title, starts_at, ends_at)
    values (v, p.id, p.class_type, replace(replace(p.title_template, '{module}', v_mod), '{class_type}', p.class_type),
            public.pt_to_utc(p_week_start + p.weekday_offset, p.start_time_pt),
            public.pt_to_utc(p_week_start + p.weekday_offset, p.start_time_pt) + make_interval(mins => p.duration_minutes));
  end loop;
  return v;
end $$;

-- Raw booking with slots for every planned class (bypasses the engine; for rule tests).
create or replace function tests.raw_book(p_mw uuid, p_instructor uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.booking (module_week_id, instructor_id, confirmed_via) values (p_mw, p_instructor, 'Manual') returning id into v;
  insert into public.booking_slot (booking_id, class_id, instructor_id, time_range)
  select v, c.id, p_instructor, tstzrange(c.starts_at, c.ends_at, '[)')
    from public.class_session c where c.module_week_id = p_mw and c.status = 'Planned';
  return v;
end $$;

grant usage on schema tests to authenticated, anon;
grant execute on all functions in schema tests to authenticated, anon;

begin;
select plan(1);
select ok(true, 'test helpers installed');
select * from finish();
rollback;
