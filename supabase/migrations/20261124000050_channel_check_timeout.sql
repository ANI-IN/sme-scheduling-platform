-- Owner's night batch of 24 November 2026 (decision 335): the instructor channel check of decision 330 never stays
-- "Checking". When its Discord work never comes back, the clock's sweep (decision 331) ends it with a clear result.
create or replace function private.expire_stuck_checks(p_now timestamptz default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_msg text := 'The Discord check did not finish within a few minutes. Press Check again; if it happens again, see Settings, Connections.';
begin
  -- Work handed to the automation that never came back.
  update public.action_queue set status = 'Failed', error = 'Did not finish within 2 minutes.', processed_at = v_now
   where action like 'discord\_%' and status in ('Queued', 'Processing') and created_at < v_now - interval '2 minutes';
  -- What people see as "Checking", with no check left that could finish it.
  update public.instructor i set discord_status = 'Problem', discord_problem = v_msg, discord_checked_at = v_now, version = i.version
   where i.discord_status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.action = 'discord_member' and a.status in ('Queued', 'Processing')
                      and a.payload ->> 'id' = i.id::text);
  update public.team_member t set discord_status = 'Problem', discord_problem = v_msg, discord_checked_at = v_now, version = t.version
   where t.discord_status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.action = 'discord_member' and a.status in ('Queued', 'Processing')
                      and a.payload ->> 'id' = t.id::text);
  update public.discord_server s set status = 'Problem', problem = v_msg, checked_at = v_now
   where s.status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.action = 'discord_server' and a.status in ('Queued', 'Processing')
                      and a.payload ->> 'server_id' = s.id);
  update public.domain d set discord_status = 'Problem', discord_problem = v_msg, discord_checked_at = v_now, version = d.version
   where d.discord_status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.action = 'discord_server' and a.status in ('Queued', 'Processing')
                      and (a.payload ->> 'server_id' = d.discord_server_id or a.payload ->> 'domain_id' = d.id::text));
  -- Decision 335: a channel check whose Discord work never came back ends with a clear result too.
  update public.channel_check c set status = 'Problem', checked_at = v_now,
         problems = array['The Discord check did not finish within a few minutes. Choose the channel again; if it happens again, see Settings, Connections.']
   where c.status = 'Checking'
     and not exists (select 1 from public.action_queue a where a.id = c.action_id and a.status in ('Queued', 'Processing'));
end;
$$;
