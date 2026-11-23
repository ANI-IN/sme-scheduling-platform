-- Release 3, item 11: Undo in Activity history only for a team member's own edit in the app.
begin;
\ir ../helpers/helpers.psql
select plan(13);

select tests.scenario('HU', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as mod \gset

create or replace function tests.last_module_change() returns public.history_event language sql as $$
  select h from public.history_event h where entity_table = 'module' and action = 'module changed' order by id desc limit 1;
$$;

-- =============================================================== a team member's edit
select tests.login_member('hu.ops@example.com');
update public.module set rotation_order = 5 where id = :'mod';
select tests.as_postgres();
select is((tests.last_module_change()).actor_kind, 'TeamMember', '1. the edit is recorded as made by a team member');
select ok(private.can_undo(tests.last_module_change()), '2. and it can be undone');

-- =============================================================== changes nobody on the team made
update public.module set rotation_order = 6 where id = :'mod';
select ok(not private.can_undo(tests.last_module_change()), '3. a change made directly in the database cannot be undone');

select set_config('app.actor_kind', 'System', true), set_config('app.actor_label', 'Setup command', true);
update public.module set rotation_order = 7 where id = :'mod';
select ok(not private.can_undo(tests.last_module_change()), '4. nor a change made by a setup command');

select set_config('app.actor_label', 'Test data', true);
update public.module set rotation_order = 8 where id = :'mod';
select ok(not private.can_undo(tests.last_module_change()), '5. nor one made by loading test data');

select set_config('app.actor_label', 'System', true);
update public.module set rotation_order = 9 where id = :'mod';
select ok(not private.can_undo(tests.last_module_change()), '6. nor one made by the system or the automation');

-- A company account that is not on the team list: no team member to name.
select tests.login_member('not.listed@example.com');
update public.module set rotation_order = 10 where id = :'mod';
select tests.as_postgres();
select ok((tests.last_module_change()).actor_team_member_id is null and not private.can_undo(tests.last_module_change()),
  '7. nor one with no team member behind it');

select (tests.last_module_change()).id as unlisted \gset
select tests.login_member('hu.ops@example.com');
select ok(not public.undoable((select h from public.history_event h where id = :unlisted)), '8. the app is not offered Undo for it');
select throws_ok(format('select public.undo_history_event(%s)', :unlisted),
  '22023', 'This change cannot be undone. Change it directly instead.', '9. and the database refuses to undo it');

-- =============================================================== creating or removing a module
insert into public.module (domain_id, name, rotation_order) values (:'dom', 'HU Extra', 4) returning id as extra \gset
select is((select actor_kind from public.history_event where entity_id = :'extra'::uuid and action = 'module added'), 'TeamMember',
  '10. a team member creates a module');
select ok(not public.undoable((select h from public.history_event h where entity_id = :'extra'::uuid and action = 'module added')),
  '11. creating a module is never offered for undo, even to the team member who did it');
delete from public.module where id = :'extra';
select ok(not public.undoable((select h from public.history_event h where entity_id = :'extra'::uuid and action = 'module removed')),
  '12. nor is removing one');
select throws_ok(format('select public.undo_history_event(%s)',
  (select id from public.history_event where entity_id = :'extra'::uuid and action = 'module removed')),
  '22023', 'This change cannot be undone. Change it directly instead.', '13. and the database refuses to bring it back');
select tests.as_postgres();

select * from finish();
rollback;
