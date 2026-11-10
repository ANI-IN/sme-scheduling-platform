-- =====================================================================================
-- Seed data — Backend v1 (PRD Appendix A). Runs on `supabase db reset` locally.
-- For a hosted project, run it once in the SQL editor (docs/SETUP.md), then replace every
-- value marked "Needs real details" in the app (Settings → Team, Instructors, Modules).
-- Backend exists only here, as data. Nothing in the code refers to it.
-- =====================================================================================

-- Company email domain: only accounts @this-domain can sign in. Local development uses
-- example.com; on a hosted project set your real domain (docs/SETUP.md step 3).
update public.app_config
   set company_email_domain = 'example.com',
       app_base_url = 'http://localhost:5173',
       response_base_url = 'http://localhost:5678/webhook/respond',
       scheduling_sender_name = 'SME Scheduling'
 where id = 1;

do $$
declare
  v_owner uuid; v_ops uuid; v_lead uuid; v_dom uuid;
  m record; v_mod uuid;
  v_ids jsonb := '{}';
  i text;
  r int;
begin
  -- Team members (placeholders: replace names, emails and Discord IDs in Settings → Team)
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Module owner (needs real details)', 'owner.placeholder@example.com', 'Product manager', true) returning id into v_owner;
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Operations (needs real details)', 'ops.placeholder@example.com', 'Operations', true) returning id into v_ops;
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Lead (needs real details)', 'lead.placeholder@example.com', 'Lead', true) returning id into v_lead;

  -- Domain (status Test: every message goes to the test channel / test inbox)
  insert into public.domain (name, status, alert_discord_channel_id, test_discord_channel_id, test_email)
  values ('Backend', 'Test', '000000000000000001', '000000000000000002', 'test-inbox.placeholder@example.com')
  returning id into v_dom;
  insert into public.domain_team (domain_id, team_member_id, role) values (v_dom, v_lead, 'Escalation'), (v_dom, v_ops, 'Operations');

  -- Instructors from the current priority sheet (PLACEHOLDER contact details; ops verifies who is active)
  foreach i in array array['Karl Peterson', 'Robin Kessler', 'Shelly Carver', 'Aaron Kemp', 'Tomas Dietrich',
                           'Noah Keller', 'Samuel Dunn', 'Jon Whitaker', 'Rhys Jennings', 'Felix Sandoval'] loop
    insert into public.instructor (full_name, primary_email, notes)
    values (i, lower(replace(i, ' ', '.')) || '.placeholder@example.com',
            'Needs real details: replace the email, add the Discord user ID and channel link, then send a test message.')
    returning jsonb_build_object(i, id) || v_ids into v_ids;
  end loop;

  -- Test instructors (point them at team members' own Discord/email when testing)
  foreach i in array array['Test Instructor A', 'Test Instructor B', 'Test Instructor C'] loop
    insert into public.instructor (full_name, primary_email, is_test, verified_at, notes)
    values (i, 'test.' || lower(right(i, 1)) || '.placeholder@example.com', true, now(),
            'Test instructor: use a team member''s own Discord ID, channel link and email.')
    returning jsonb_build_object(i, id) || v_ids into v_ids;
  end loop;

  -- Modules, class pattern (Sun 9:00–1:00 PM PT live class, Thu 6:00–8:00 PM PT review), rankings
  for m in select * from (values
      (1, 'Database Design', array['Karl Peterson', 'Robin Kessler', 'Shelly Carver', 'Aaron Kemp']),
      (2, 'Object Modeling', array['Tomas Dietrich', 'Robin Kessler', 'Noah Keller']),
      (3, 'API Design', array['Robin Kessler', 'Tomas Dietrich', 'Shelly Carver']),
      (4, 'Cloud Native Design', array['Samuel Dunn', 'Jon Whitaker', 'Rhys Jennings']),
      (5, 'Concurrency', array['Felix Sandoval', 'Robin Kessler'])) as t(ord, name, ranking) loop
    insert into public.module (domain_id, name, rotation_order) values (v_dom, m.name, m.ord) returning id into v_mod;
    insert into public.module_owner (module_id, team_member_id) values (v_mod, v_owner);
    insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time_pt, duration_minutes, sort_order)
    values (v_mod, 'Live class', '{module}: Live class', 0, '09:00', 240, 1),
           (v_mod, 'Assignment review', '{module}: Assignment review', 4, '18:00', 120, 2);
    insert into public.module_resource (module_id, title, url)
    values (v_mod, m.name || ' module page (needs real link)', 'https://example.com/replace-with-uplevel-link');
    for r in 1 .. cardinality(m.ranking) loop
      insert into public.module_ranking (module_id, instructor_id, rank) values (v_mod, (v_ids ->> m.ranking[r])::uuid, r);
    end loop;
    -- Test instructors at the end of every ranking so test-mode runs have someone verified to ask.
    insert into public.module_ranking (module_id, instructor_id, rank)
    values (v_mod, (v_ids ->> 'Test Instructor A')::uuid, cardinality(m.ranking) + 1),
           (v_mod, (v_ids ->> 'Test Instructor B')::uuid, cardinality(m.ranking) + 2);
  end loop;

  -- Holidays used by the planner (edit in Settings → Holidays)
  insert into public.holiday (date, name) values
    ('2026-11-26', 'Thanksgiving'), ('2026-12-25', 'Christmas Day'), ('2027-01-01', 'New Year''s Day'),
    ('2027-01-18', 'Martin Luther King Jr. Day'), ('2027-02-15', 'Presidents'' Day'), ('2027-05-31', 'Memorial Day'),
    ('2027-07-04', 'Independence Day'), ('2027-09-06', 'Labor Day'), ('2027-11-25', 'Thanksgiving'),
    ('2027-12-25', 'Christmas Day');
end;
$$;

-- Seeding is setup, not user activity: start History clean so the first entries are real.
alter table public.history_event disable trigger history_no_truncate;
truncate public.history_event;
alter table public.history_event enable trigger history_no_truncate;
insert into public.history_event (actor_kind, actor_label, category, action, note)
values ('System', 'Seed', 'System', 'Seed data loaded', 'Backend domain in testing, 5 modules with their instructor order, and details still to fill in.');
