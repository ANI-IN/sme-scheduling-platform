-- Rollback of 20261123000034_live_updates.sql: takes out of the supabase_realtime publication exactly the tables
-- that migration added (it remembered them in private.live_update_table), then forgets the list.

do $$
declare
  t text;
begin
  if to_regclass('private.live_update_table') is null then
    return;
  end if;
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    for t in select table_name from private.live_update_table loop
      if exists (
        select 1 from pg_publication_tables
         where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime drop table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;

drop table if exists private.live_update_table;
