-- =====================================================================================
-- Milestone 3/6 support: system configuration edits from the app, n8n error logging,
-- connection status for Settings → System.
-- =====================================================================================

-- Settings → System: edit the system configuration (logged with before/after by trigger).
create or replace function public.set_app_config(p_config jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare c public.app_config;
begin
  perform private.require_team();
  select * into c from public.app_config where id = 1;
  if (p_config ->> 'version')::int is distinct from c.version then
    raise exception 'This changed — reload. Someone else saved the system settings after you opened them.' using errcode = '40001';
  end if;
  if p_config ? 'company_email_domain' and lower(trim(p_config ->> 'company_email_domain')) <> c.company_email_domain then
    raise exception 'The company email domain can only be changed by an admin in the database (see docs/SETUP.md).';
  end if;
  update public.app_config set
    discord_guild_id = nullif(trim(coalesce(p_config ->> 'discord_guild_id', discord_guild_id)), ''),
    response_base_url = nullif(trim(coalesce(p_config ->> 'response_base_url', response_base_url)), ''),
    app_base_url = nullif(trim(coalesce(p_config ->> 'app_base_url', app_base_url)), ''),
    admin_discord_channel_id = nullif(trim(coalesce(p_config ->> 'admin_discord_channel_id', admin_discord_channel_id)), ''),
    scheduling_email = nullif(trim(coalesce(p_config ->> 'scheduling_email', scheduling_email)), ''),
    scheduling_sender_name = coalesce(nullif(trim(p_config ->> 'scheduling_sender_name'), ''), scheduling_sender_name)
  where id = 1;
end;
$$;

-- Test-mode targets for a domain (required before switching to Test).
create or replace function public.set_test_targets(p_domain_id uuid, p_test_discord_channel_id text, p_test_email text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_test_discord_channel_id is not null and p_test_discord_channel_id !~ '^\d{17,20}$' then
    raise exception 'The test Discord channel ID must be 17–20 digits.';
  end if;
  if p_test_email is not null and p_test_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid test email address.';
  end if;
  update public.domain set test_discord_channel_id = nullif(p_test_discord_channel_id, ''), test_email = nullif(p_test_email, '')
   where id = p_domain_id;
end;
$$;

-- WF5: record an n8n failure in History and alert the admin channel (T14).
create or replace function public.log_system_error(p_workflow text, p_message text, p_url text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  perform private.set_actor('System', null, 'n8n');
  perform private.log_event('System', 'Automation error: ' || coalesce(p_workflow, '?'), null, null, null,
    jsonb_build_object('url', p_url), p_message);
  perform private.queue_team_message('T14', null, 'admin', null, '{}', 'Automation error: ' || coalesce(p_workflow, '?'),
    '❗ n8n workflow "' || coalesce(p_workflow, '?') || '" failed: ' || coalesce(p_message, '?') || coalesce(E'\n' || p_url, ''),
    'T14:wf:' || md5(coalesce(p_workflow, '') || coalesce(p_message, '') || to_char(now(), 'YYYYMMDDHH24')), now());
end;
$$;

-- Settings → System: last send per channel and recent failures, as a simple connection status.
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

grant execute on function public.set_app_config(jsonb) to authenticated, service_role;
grant execute on function public.set_test_targets(uuid, text, text) to authenticated, service_role;
grant execute on function public.log_system_error(text, text, text) to service_role;
grant execute on function public.connection_status() to authenticated, service_role;
