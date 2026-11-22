-- Core readiness step 2: the app starts empty and Home shows a Get started list (decisions 251, 253).
begin;
\ir ../helpers/helpers.psql
select plan(15);

select tests.company();
create or replace function tests.step(p_key text) returns boolean language sql as $$
  select (x ->> 'done')::boolean from jsonb_array_elements(public.get_started()) x where x ->> 'key' = p_key;
$$;
-- Start from an empty Sandbox, as a real one is after a reset.
update public.app_config set environment = 'Sandbox' where id = 1;
-- Release 3 M2: removing access, Pause all messages and Reset are for admins (decision 286).
insert into public.team_member (name, email, is_admin) values ('GS Me', 'gs.me@example.com', true);
select tests.login_google('gs.me@example.com');
select public.reset_sandbox_data('RESET');
-- Keep the team member's sign in, but add the setup rows as the database owner (like the app would, step by step).
reset role;

select is((select count(*)::int from public.domain) + (select count(*)::int from public.instructor)
          + (select count(*)::int from public.module) + (select count(*)::int from public.module_week), 0,
  'empty 1. after a reset there are no domains, instructors, modules or classes');
select is((select string_agg(x ->> 'label', ' > ' order by n) from jsonb_array_elements(public.get_started()) with ordinality t(x, n)),
  'Add a domain > Choose its Discord server > Add team members > Add instructors > Add modules > Create a cohort > Plan classes',
  'empty 2. Get started lists the seven first steps in order');
select ok((select bool_and(not (x ->> 'done')::boolean) from jsonb_array_elements(public.get_started()) x),
  'empty 3. on an empty app no step is done yet');
select ok((select bool_and(x ->> 'link' like '/%') from jsonb_array_elements(public.get_started()) x),
  'empty 4. each step links to the page where it is done');

-- Step by step, as a person would.
insert into public.domain (name, status) values ('GS Domain', 'Draft') returning id as dom \gset
select ok(tests.step('domain'), 'empty 5. adding a domain ticks "Add a domain"');
insert into public.discord_server (id, name) values ('666000000000000001', 'GS server');
update public.domain set discord_server_id = '666000000000000001' where id = :'dom';
select ok(tests.step('discord'), 'empty 6. choosing its server ticks "Choose its Discord server"');
insert into public.team_member (name, email) values ('GS Colleague', 'gs.colleague@example.com');
select ok(tests.step('team'), 'empty 7. a second person ticks "Add team members"');
insert into public.instructor (full_name, primary_email) values ('GS Instructor', 'gs.instructor@example.org');
select ok(tests.step('instructors'), 'empty 8. an instructor ticks "Add instructors"');
insert into public.module (domain_id, name, rotation_order) values (:'dom', 'GS Module', 1) returning id as mod \gset
select ok(tests.step('modules'), 'empty 9. a module in use ticks "Add modules"');
select ok(not tests.step('cohort'), 'empty 10. a module alone does not tick "Create a cohort"');
insert into public.cohort (domain_id, name, region) values (:'dom', 'GS Cohort', 'India');
select ok(tests.step('cohort'), 'empty 10b. adding a cohort ticks it');
select public.create_module_weeks(:'dom', jsonb_build_array(jsonb_build_object('module_id', :'mod', 'cohort', 'GS Cohort',
  'classes', jsonb_build_array(jsonb_build_object('date', '2027-03-06', 'start_time', '09:00', 'end_time', '11:00', 'title', 'GS class')))), true);
select ok(tests.step('classes'), 'empty 11. planning a class ticks "Plan classes": the list is done and Home stops showing it');
-- Archived items do not count.
select public.set_archived('domain', :'dom', true);
select ok(not tests.step('domain'), 'empty 12. an archived domain does not count as set up');
select public.set_archived('domain', :'dom', false);
-- Only the team sees the list.
select tests.login_anon();
select throws_ok('select public.get_started()', '42501', null, 'empty 13. someone who is not signed in cannot read the list');
select tests.as_postgres();
-- The seed sets only the sender name: no sample people, instructors or holidays are part of a fresh database.
select ok(not exists (select 1 from public.team_member where is_placeholder) and not exists (select 1 from public.holiday),
  'empty 14. no placeholder people or built in holidays are left');

select * from finish();
rollback;
