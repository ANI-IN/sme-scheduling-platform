-- Release 3, C15: live updates (migration 20261123000034_live_updates.sql). Every table people look at is in the
-- supabase_realtime publication, so open pages refresh by themselves. A database without that publication (plain
-- Postgres) skips the publication checks.
begin;
\ir ../helpers/helpers.psql
select plan(25);

select case
         when not exists (select 1 from pg_publication where pubname = 'supabase_realtime')
           then skip('there is no supabase_realtime publication in this database', 1)
         else ok(exists (select 1 from pg_publication_tables
                          where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t),
                 format('%s. %s is live', n, t))
       end
  from unnest(array[
    'module_week', 'class_session', 'request', 'booking', 'attention_item', 'help_request', 'message',
    'instructor', 'team_member', 'module', 'cohort', 'domain', 'discord_server', 'discord_channel',
    'action_queue', 'time_proposal', 'cohort_break', 'cohort_holiday', 'history_event', 'system_state',
    'app_config', 'standard_schedule'
  ]) with ordinality as x(t, n)
 order by n;

-- Realtime sends a change only to someone who may read the row, so every live table keeps row level security on.
select is((select array_agg(c.relname::text order by c.relname) from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'public' and not c.relrowsecurity
              and c.relname in ('module_week', 'class_session', 'request', 'booking', 'attention_item', 'help_request',
                'message', 'instructor', 'team_member', 'module', 'cohort', 'domain', 'discord_server',
                'discord_channel', 'action_queue', 'time_proposal', 'cohort_break', 'cohort_holiday',
                'history_event', 'system_state', 'app_config', 'standard_schedule')),
  null, '23. every live table keeps row level security on');

-- The list of tables the migration added (for its rollback) is not readable from the app.
select ok(not has_table_privilege('authenticated', 'private.live_update_table', 'select'),
  '24. the app cannot read the list of tables the migration added');
select ok(not has_table_privilege('anon', 'private.live_update_table', 'select'),
  '25. nor can anyone signed out');

select * from finish();
rollback;
