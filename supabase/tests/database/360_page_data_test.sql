-- Release 3, M6 (decision 294): the indexes for a program the size of the team's tracker.
begin;
\ir ../helpers/helpers.psql
select plan(3);

select has_index('public', 'module_week', 'module_week_domain_week_idx', array['domain_id', 'week_start_date', 'id'],
  '1. the class week list reads one domain in date order from an index');

-- Every foreign key has an index that starts with its column, except on a few tables that stay small (who removed
-- access, who changed a server, who added a beta address, whose error it was).
select is(
  (select coalesce(array_agg(x order by x), '{}') from (
     select c.conrelid::regclass::text || '.' || a.attname as x
       from pg_constraint c
       join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
      where c.contype = 'f' and c.connamespace = 'public'::regnamespace and cardinality(c.conkey) = 1
        and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1])) s),
  array['app_error.team_member_id', 'beta_access.added_by', 'discord_server.access_changed_by',
        'team_member.access_removed_by'],
  '2. every foreign key on a table that grows has an index');

select is(
  (select count(*)::int from pg_indexes where schemaname = 'public' and indexname in (
     'attention_item_domain_idx', 'message_instructor_idx', 'help_request_module_week_idx', 'reminder_message_idx',
     'module_ranking_instructor_idx', 'setting_module_week_idx')),
  6, '3. tasks, messages, help requests, reminders, instructor orders and settings are found by what they belong to');

select * from finish();
rollback;
