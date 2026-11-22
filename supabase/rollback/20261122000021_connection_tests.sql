-- Rollback of 20261122000021_connection_tests.sql (decision 310). Removes Send a test and puts back connection_status as
-- it was in 20261110000006_app_support.sql.

drop function if exists public.send_connection_test(text);

create or replace function public.connection_status()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'discord_last_sent', (select max(sent_at) from public.message where channel = 'Discord' and status = 'Sent'),
    'email_last_sent', (select max(sent_at) from public.message where channel = 'Email' and status = 'Sent'),
    'discord_failed_24h', (select count(*) from public.message where channel = 'Discord' and status = 'Failed' and updated_at > now() - interval '24 hours'),
    'email_failed_24h', (select count(*) from public.message where channel = 'Email' and status = 'Failed' and updated_at > now() - interval '24 hours'),
    'pending', (select count(*) from public.message where status in ('Pending', 'Sending')),
    'oldest_pending', (select min(created_at) from public.message where status = 'Pending'),
    'last_action_processed', (select max(processed_at) from public.action_queue),
    'queued_actions', (select count(*) from public.action_queue where status = 'Queued'))
  where private.is_team_user() or private.is_service();
$$;
grant execute on function public.connection_status() to authenticated, service_role;
