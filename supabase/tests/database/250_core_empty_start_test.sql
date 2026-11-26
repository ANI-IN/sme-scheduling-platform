-- Core readiness step 2: the app starts empty and Home shows a Get started list (decisions 251, 253).
begin;
\ir ../helpers/helpers.psql
select plan(27);

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
-- Owner, 26 November 2026 (decision 351): the domain steps follow the chosen domain, and archived or deleted
-- domains never tick a step.
create or replace function tests.done(p_domain uuid default null) returns text language sql as $$
  select coalesce(string_agg(x ->> 'key', ' ' order by n), 'none')
    from jsonb_array_elements(public.get_started(p_domain)) with ordinality t(x, n) where (x ->> 'done')::boolean;
$$;
select is(tests.done(:'dom'), 'domain discord team instructors modules cohort classes', 'chosen 1. the set up domain has every step');
insert into public.domain (name, status) values ('GS New', 'Draft') returning id as dom2 \gset
select is(tests.done(:'dom2'), 'domain team instructors', 'chosen 2. a new domain starts with its own steps unticked');
select is(tests.done(), 'domain discord team instructors modules cohort classes', 'chosen 3. with no domain named, any domain in use counts');
select public.set_archived('domain', :'dom', true);
select is(tests.done(:'dom2'), 'domain team instructors', 'archived 1. nothing of an archived domain counts for another');
select is(tests.done(), 'domain team instructors', 'archived 2. nor when no domain is named');
select is(tests.done(:'dom'), 'domain team instructors', 'archived 3. an archived domain named itself ticks none of its steps');
select public.set_archived('domain', :'dom2', true);
select is(tests.done(), 'team instructors', 'archived 4. every domain archived: only what is really done');
-- Only people in use count. The old domain's team rows do not count either.
update public.team_member set access_removed_at = now() where lower(email) = 'gs.colleague@example.com';
insert into public.domain_team (domain_id, team_member_id, role)
select :'dom', id, 'Operations' from public.team_member where lower(email) = 'gs.me@example.com';
select is(tests.done(), 'instructors', 'people 1. a person without access and an archived domain team do not count');
update public.instructor set status = 'Archived' where full_name = 'GS Instructor';
select is(tests.done(), 'none', 'people 2. an archived instructor does not count');
update public.instructor set status = 'Active' where full_name = 'GS Instructor';
update public.team_member set access_removed_at = null where lower(email) = 'gs.colleague@example.com';
select public.set_archived('domain', :'dom', false);
select public.set_archived('domain', :'dom2', false);
-- Deleted domains: the same as an empty app, except the people.
select lives_ok(format('select public.delete_item(''domain'', %L, %L)', :'dom', 'GS Domain'), 'deleted 1. an admin deletes the set up domain');
select lives_ok(format('select public.delete_item(''domain'', %L, %L)', :'dom2', 'GS New'), 'deleted 2. and the new one');
select is(tests.done(), 'team instructors', 'deleted 3. every domain deleted: only what is really done');

-- Only the team sees the list.
select tests.login_anon();
select throws_ok('select public.get_started()', '42501', null, 'empty 13. someone who is not signed in cannot read the list');
select tests.as_postgres();
-- The seed sets only the sender name: no sample people, instructors or holidays are part of a fresh database.
select ok(not exists (select 1 from public.team_member where is_placeholder) and not exists (select 1 from public.holiday),
  'empty 14. no placeholder people or built in holidays are left');

select * from finish();
rollback;
