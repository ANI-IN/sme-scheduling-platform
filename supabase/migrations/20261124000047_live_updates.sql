-- Release 3, C15: live updates everywhere. Every table people look at is in the supabase_realtime publication, so
-- an open page refreshes by itself when the automation or a teammate changes something. Row level security stays
-- as it is: Realtime only sends a change to someone who may read that row.
--
-- Idempotent: a table is added only when it is not in the publication yet, and the tables this migration added are
-- remembered in private.live_update_table, so the rollback removes exactly those and nothing a person added by hand.
-- Where there is no supabase_realtime publication (a plain Postgres database), nothing is published.

create table if not exists private.live_update_table (
  table_name text primary key,
  added_at timestamptz not null default now()
);
alter table private.live_update_table enable row level security;
revoke all on private.live_update_table from public, anon, authenticated;

do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  foreach t in array array[
    'module_week', 'class_session', 'request', 'booking', 'attention_item', 'help_request', 'message',
    'instructor', 'team_member', 'module', 'cohort', 'domain', 'discord_server', 'discord_channel',
    'action_queue', 'time_proposal', 'cohort_break', 'cohort_holiday', 'history_event', 'system_state',
    'app_config', 'standard_schedule'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
      insert into private.live_update_table (table_name) values (t) on conflict do nothing;
    end if;
  end loop;
end;
$$;
