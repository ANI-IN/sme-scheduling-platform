-- Release 3, item 11: Undo in Activity history only where it is safe.
--
-- Undo was already only for edits to setup records (never creating or removing a domain, cohort or module, never a
-- permanent delete, never messages, answers or automatic actions). It was still offered for changes that no team
-- member made: the system, the clock, the automation, a setup command, test data or a direct database connection.
-- Those are not a person's edit to take back, so undo is now only for a change a team member made in the app.
-- public.undoable (what the app shows) and private.require_undoable (what undo_history_event checks) both read
-- private.can_undo, so the app and the database keep the same rule.

create or replace function private.can_undo(e public.history_event)
returns boolean language sql stable security definer set search_path = ''
as $$
  select e.category = 'Setup changes'
     and e.undo_of is null
     and e.actor_kind = 'TeamMember'
     and e.actor_team_member_id is not null
     and e.entity_table is not null
     and e.entity_table in ('team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
           'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'setting',
           'holiday', 'cohort', 'module_operations', 'class_type')
     and (e.action = 'Ranking saved' or e.action in (e.entity_table || ' added', e.entity_table || ' changed'))
     and not (e.entity_table in ('domain', 'cohort', 'module') and (e.before is null or e.after is null))
     and not exists (select 1 from public.history_event u where u.undo_of = e.id);
$$;
