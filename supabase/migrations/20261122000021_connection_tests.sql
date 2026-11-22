-- Release 3, A7 (decision 310): Connections statuses that never look broken when they are not, and Send a test.
--
-- connection_status now also says whether Discord and email are set up, and the last real failure of each with its
-- reason, so Settings, Connections can show "Ready, no messages yet" (set up, nothing sent), "Working" (the last
-- message went out) or "Problem" (the last attempt failed after the last success). A message the beta guard stops is
-- Cancelled, not Failed, so it never counts as a problem.
--
-- send_connection_test (admins only) queues one test message through the usual path: Discord posts to the admin
-- alert channel, email goes to the admin's own address. One test a minute per channel; each is in Activity history.

create or replace function public.connection_status()
returns jsonb language sql stable security definer set search_path = ''
as $$
  with last_fail as (
    select distinct on (m.channel) m.channel, m.updated_at, m.last_error
      from public.message m where m.status = 'Failed' and m.direction = 'Outbound'
     order by m.channel, m.updated_at desc)
  select jsonb_build_object(
    'discord_last_sent', (select max(sent_at) from public.message where channel = 'Discord' and status = 'Sent'),
    'email_last_sent', (select max(sent_at) from public.message where channel = 'Email' and status = 'Sent'),
    'discord_failed_24h', (select count(*) from public.message where channel = 'Discord' and status = 'Failed' and updated_at > now() - interval '24 hours'),
    'email_failed_24h', (select count(*) from public.message where channel = 'Email' and status = 'Failed' and updated_at > now() - interval '24 hours'),
    'discord_last_failed', (select f.updated_at from last_fail f where f.channel = 'Discord'),
    'discord_last_error', (select f.last_error from last_fail f where f.channel = 'Discord'),
    'email_last_failed', (select f.updated_at from last_fail f where f.channel = 'Email'),
    'email_last_error', (select f.last_error from last_fail f where f.channel = 'Email'),
    'discord_ready', exists (select 1 from public.discord_server s where s.access = 'Approved' and s.archived_at is null)
                     and (select c.admin_discord_channel_id is not null from public.app_config c where c.id = 1),
    'discord_has_server', exists (select 1 from public.discord_server s where s.access = 'Approved' and s.archived_at is null),
    'email_ready', (select coalesce(nullif(trim(c.scheduling_email), ''), null) is not null from public.app_config c where c.id = 1),
    'pending', (select count(*) from public.message where status in ('Pending', 'Sending')),
    'oldest_pending', (select min(created_at) from public.message where status = 'Pending'),
    'last_action_processed', (select max(processed_at) from public.action_queue),
    'queued_actions', (select count(*) from public.action_queue where status = 'Queued'))
  where private.is_team_user() or private.is_service();
$$;
grant execute on function public.connection_status() to authenticated, service_role;

create or replace function public.send_connection_test(p_channel text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_me public.team_member;
  v_key text := 'conntest:' || lower(coalesce(p_channel, '')) || ':' || to_char(now() at time zone 'UTC', 'YYYYMMDDHH24MI');
  v_n int;
  v_text text;
begin
  perform private.require_team();
  perform private.require_admin();
  if p_channel not in ('Discord', 'Email') then
    raise exception 'Choose Discord or Email.' using errcode = '22023';
  end if;
  select * into v_me from public.team_member where id = private.current_team_member_id();
  if v_me.id is null then raise exception 'Only a team member can send a test.' using errcode = '42501'; end if;
  if exists (select 1 from public.message m where m.unique_key like v_key || ':%') then
    raise exception 'A test was sent less than a minute ago. Wait a minute, then try again.' using errcode = '22023';
  end if;
  v_text := 'This is a test from Settings, Connections, sent by ' || v_me.name || '. If you can read it, '
    || case when p_channel = 'Discord' then 'Discord' else 'email' end || ' works. Nothing else needs doing.';
  if p_channel = 'Discord' then
    if not exists (select 1 from public.discord_server s where s.access = 'Approved' and s.archived_at is null) then
      raise exception 'No Discord server is approved yet. Add the bot with the invite link, then approve the server under Discord servers.' using errcode = '22023';
    end if;
    if (select c.admin_discord_channel_id from public.app_config c where c.id = 1) is null then
      raise exception 'Choose the admin alert channel first, under Discord servers on this page.' using errcode = '22023';
    end if;
    v_n := private.queue_team_message('T21', null, 'admin', null, '{}', 'Connection test', v_text, v_key, now());
  else
    if (select coalesce(trim(c.scheduling_email), '') from public.app_config c where c.id = 1) = '' then
      raise exception 'Fill in the sender email first, under Advanced: links on this page.' using errcode = '22023';
    end if;
    if coalesce(trim(v_me.email), '') = '' then
      raise exception 'Your team profile has no email address.' using errcode = '22023';
    end if;
    v_n := private.queue_team_message('T21', null, 'email', null, array[v_me.id], 'Connection test', v_text, v_key, now());
  end if;
  if coalesce(v_n, 0) = 0 then
    raise exception 'The test could not be queued. Try again in a minute.' using errcode = '22023';
  end if;
  perform private.log_event('Messages', 'Connection test sent: ' || p_channel, 'team_member', v_me.id, null,
    jsonb_build_object('channel', p_channel,
      'to', case when p_channel = 'Discord' then 'Admin alert channel' else v_me.email end));
  return jsonb_build_object('ok', true, 'channel', p_channel);
end;
$$;
revoke execute on function public.send_connection_test(text) from public, anon;
grant execute on function public.send_connection_test(text) to authenticated, service_role;
