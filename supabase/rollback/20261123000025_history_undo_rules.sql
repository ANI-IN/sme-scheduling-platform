-- Rollback of 20261123000025_history_undo_rules.sql (Release 3, item 11). Puts back private.can_undo as it was in
-- 20261113000002_core_archive_delete.sql, so undo is again offered for setup edits whoever made them.

create or replace function private.can_undo(e public.history_event)
returns boolean language sql stable security definer set search_path = ''
as $$
  select e.category = 'Setup changes'
     and e.undo_of is null
     and e.entity_table is not null
     and e.entity_table in ('team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
           'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'setting',
           'holiday', 'cohort', 'module_operations', 'class_type')
     and (e.action = 'Ranking saved' or e.action in (e.entity_table || ' added', e.entity_table || ' changed'))
     and not (e.entity_table in ('domain', 'cohort', 'module') and (e.before is null or e.after is null))
     and not exists (select 1 from public.history_event u where u.undo_of = e.id);
$$;
