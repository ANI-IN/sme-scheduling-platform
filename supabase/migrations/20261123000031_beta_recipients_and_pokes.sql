-- Owner's urgent list of 23 November 2026 (decision 329).
-- A1 and A3: during the beta, instructors who are signed in colleagues or (a setting, on by default) whose email is on
--   the beta list receive messages, even before their first sign in; the same for Discord direct messages and tags.
-- A2: a message a beta rule stops is marked blocked (with its reason in plain words and what to do), so the app shows it
--   on the instructor, the class week and the board, and Send again works once the rule allows it.
-- A4: n8n is poked at once (a few seconds at most) whenever a message is queued or the app asks for a Discord check,
--   by the database itself, so a save never waits for n8n and nothing depends on the browser.

alter table public.app_config add column if not exists beta_list_may_receive boolean not null default true;
alter table public.message add column if not exists blocked boolean not null default false;
update public.message set blocked = true
 where status = 'Cancelled' and last_error is not null
   and (last_error like 'During the beta,%' or last_error like 'The bot only%' or last_error like 'The bot sends direct%'
        or last_error like 'Production never%' or last_error like 'Sandbox %');
create index if not exists message_blocked_idx on public.message (instructor_id, created_at desc) where blocked;

-- An instructor counts as a colleague for the beta rules when one of their emails belongs to a team member who has
-- signed in and still has access, or, while the setting is on, is on the beta list.
create or replace function private.is_beta_instructor(p_instructor_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  with e as (
    select lower(i.primary_email) email from public.instructor i where i.id = p_instructor_id
    union select lower(x.email) from public.instructor_email x where x.instructor_id = p_instructor_id)
  select exists (select 1 from public.team_member t join e on e.email = lower(t.email)
                  where t.auth_user_id is not null and t.access_removed_at is null)
      or ((select c.beta_list_may_receive from public.app_config c where c.id = 1)
          and exists (select 1 from public.beta_access b join e on e.email = lower(b.email)));
$$;

-- A Discord account the beta rules allow: a signed in colleague's, the account of an instructor who counts as a
-- colleague (above), or, while the setting is on, a team member's account whose email is on the beta list.
create or replace function private.is_beta_discord(p_discord_user_id text, p_instructor_id uuid default null)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_signed_in_colleague_discord(p_discord_user_id)
      or (p_instructor_id is not null
          and exists (select 1 from public.instructor i where i.id = p_instructor_id and i.discord_user_id = p_discord_user_id)
          and private.is_beta_instructor(p_instructor_id))
      or ((select c.beta_list_may_receive from public.app_config c where c.id = 1)
          and exists (select 1 from public.team_member t join public.beta_access b on lower(b.email) = lower(t.email)
                       where t.discord_user_id = p_discord_user_id and t.access_removed_at is null))
      or ((select c.beta_list_may_receive from public.app_config c where c.id = 1)
          and exists (select 1 from public.instructor i where i.discord_user_id = p_discord_user_id
                       and private.is_beta_instructor(i.id)));
$$;
revoke execute on function private.is_beta_instructor(uuid) from public, anon;
revoke execute on function private.is_beta_discord(text, uuid) from public, anon;

create or replace function private.message_block_reason(m public.message)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  c public.app_config;
  i public.instructor;
  v_server text;
  v_domain text;
begin
  if m.direction <> 'Outbound' then return null; end if;
  select * into c from public.app_config where id = 1;
  if m.instructor_id is not null then
    select * into i from public.instructor where id = m.instructor_id;
  end if;
  if c.environment = 'Production' and c.message_recipients = 'Anyone' and m.audience = 'Instructor' and coalesce(i.is_test, false) then
    return 'Production never messages test instructors.';
  end if;
  if m.channel = 'Discord' and m.discord_channel_id is not null and m.discord_dm_user_id is not null then
    return 'A Discord message goes either to a channel or to one person, not both.';
  end if;
  -- Release 3 beta guard (decision 287): settings checked in every environment, for every recipient and tag.
  if m.channel = 'Email' and coalesce(array_length(c.recipient_email_domains, 1), 0) > 0 then
    v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
    if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.recipient_email_domains) x))) then
      return 'Not sent: during the beta, email goes only to ' || array_to_string(c.recipient_email_domains, ', ') || ' addresses. '
        || coalesce(nullif(v_domain, ''), 'This address') || ' is not one of them. Use an address there, or change Settings, Admin.';
    end if;
  end if;
  if c.message_recipients = 'Test instructors and signed in colleagues' then
    -- Owner, 23 November 2026: also anyone who is a signed in colleague or, while the setting is on, on the beta list.
    if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
       and not private.is_beta_instructor(i.id) then
      return 'Not sent: during the beta, messages go only to test instructors, signed in colleagues and people on the beta list. '
        || 'Add ' || coalesce(i.full_name, 'this instructor') || '''s email to the beta list on Settings, Admin, or mark them as a test instructor, then press Send again.';
    end if;
    if m.channel = 'Discord' then
      if m.discord_dm_user_id is not null and not private.is_beta_discord(m.discord_dm_user_id, i.id) then
        return 'Not sent: during the beta, Discord direct messages go only to colleagues who have signed in or are on the beta list. '
          || 'Ask them to sign in once, or add their email to the beta list on Settings, Admin, then press Send again.';
      end if;
      if exists (select 1 from unnest(coalesce(m.mention_user_ids, '{}')) x where not private.is_beta_discord(x, i.id)) then
        return 'Not sent: during the beta, a message may only tag colleagues who have signed in or are on the beta list. '
          || 'Ask them to sign in once, or add their email to the beta list on Settings, Admin, then press Send again.';
      end if;
    end if;
  end if;
  -- Discord servers approved by an admin (decision 288), in every environment.
  if m.channel = 'Discord' and m.discord_channel_id is not null then
    v_server := (select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id);
    if v_server is null then
      return 'The bot only posts in channels it has listed. Press Refresh on Settings, Connections first.';
    end if;
    if not private.server_allowed(v_server, m.domain_id) then
      return 'The bot only posts in Discord servers an admin has approved for this domain.';
    end if;
  elsif m.channel = 'Discord' and m.discord_dm_user_id is not null and m.domain_id is not null
        and (select d.discord_server_id from public.domain d where d.id = m.domain_id) is not null
        and not private.server_allowed((select d.discord_server_id from public.domain d where d.id = m.domain_id), m.domain_id) then
    return 'The bot sends direct messages for this domain only once an admin has approved its Discord server.';
  end if;
  if c.environment = 'Sandbox' then
    if m.channel = 'Email' then
      if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
         and not private.is_test_domain(m.domain_id) then
        return 'Sandbox never contacts real instructors by email, even at an allowed address. Mark them as a test instructor to try this.';
      end if;
      v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
      if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.sandbox_allowed_email_domains) x))) then
        return 'Sandbox only sends email to allowed domains. ' || coalesce(nullif(v_domain, ''), 'This address') || ' is not on the list.';
      end if;
    elsif m.channel = 'Discord' then
      if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
         and not private.is_test_domain(m.domain_id) then
        return 'Sandbox never contacts real instructors on Discord. Mark them as a test instructor to try this.';
      end if;
      -- A post goes to the server of its channel. A direct message is allowed only to a test instructor
      -- or a team member (Sandbox never contacts real instructors).
      if m.discord_dm_user_id is not null and m.discord_channel_id is null then
        if m.audience = 'Instructor' and not coalesce(i.is_test, false) then
          return 'Sandbox only sends direct messages to test instructors.';
        end if;
        -- SEC-5: only to the Discord account of a team member who still has access (test instructors use
        -- the account of the person testing), never to an account a real instructor uses or one the bot
        -- found in another server.
        if exists (select 1 from public.instructor x where x.discord_user_id = m.discord_dm_user_id and not x.is_test)
           or not exists (select 1 from public.team_member t where t.discord_user_id = m.discord_dm_user_id
                           and t.access_removed_at is null) then
          return 'Sandbox only sends direct messages to the Discord accounts of team members. Test instructors use the Discord account of the person testing.';
        end if;
        return null;
      end if;
      -- The channel must be one the bot listed, in an allowed server (no guessing from the domain).
      v_server := (select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id);
      if v_server is null then
        return 'Sandbox only posts to channels the bot has listed. Press Check on Settings, Connections first.';
      end if;
    end if;
  end if;
  return null;
end;
$$;

create or replace function private.message_environment_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_reason text;
begin
  if new.status not in ('Scheduled', 'Pending', 'Sending') then return new; end if;
  new.blocked := false;
  v_reason := private.message_block_reason(new);
  if v_reason is not null then
    new.status := 'Cancelled';
    new.last_error := v_reason;
    new.blocked := true;
    perform private.log_event('Messages', 'Message blocked', 'message', new.id, null,
      jsonb_build_object('template', new.template_id, 'channel', new.channel, 'to', coalesce(new.recipient_label, new.to_address)),
      v_reason, new.domain_id, null, new.module_week_id, null, new.instructor_id, null, coalesce(new.is_test, false));
  end if;
  return new;
end;
$$;

create or replace function public.resend_message(p_message_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare m public.message; v_id uuid; v_now timestamptz; v_send timestamptz;
begin
  perform private.require_team();
  select * into m from public.message where id = p_message_id;
  if m.id is null or m.direction <> 'Outbound' then raise exception 'Choose a sent message to resend.'; end if;
  -- A message a beta rule stopped can be sent again once the rule allows it (owner, 23 November 2026).
  if m.status not in ('Sent', 'Failed') and not (m.status = 'Cancelled' and coalesce(m.blocked, false)) then
    raise exception 'That message hasn''t gone out yet (it is %), so there is nothing to resend.', lower(m.status);
  end if;
  if m.domain_id is not null and m.audience <> 'Admin' and m.is_test <> private.is_test_domain(m.domain_id) then
    raise exception 'Testing was switched on or off since this message was sent. Send a new message instead, from Instructor requests after the next check.';
  end if;
  v_now := coalesce(private.domain_now(m.domain_id), now());
  v_send := case when m.audience = 'Instructor' then private.instructor_send_time(coalesce(m.module_week_id, m.domain_id), v_now, false, coalesce(private.week_region(m.module_week_id), 'US')) else v_now end;
  if m.request_id is not null and exists (select 1 from public.request r where r.id = m.request_id
       and r.status not in ('Queued', 'Sent', 'Reminded', 'Accepted')) then
    raise exception 'That request has closed, so the message would confuse the instructor. Ask again instead.';
  end if;
  insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id,
    team_member_id, module_week_id, request_id, help_request_id, attention_item_id, recipient_label, to_address,
    discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html, buttons, is_test)
  select domain_id, audience, template_id, channel,
         coalesce(unique_key, id::text) || ':resend:' || extract(epoch from clock_timestamp())::bigint,
         case when v_send > v_now then 'Scheduled' else 'Pending' end, v_send, instructor_id, team_member_id, module_week_id, request_id, help_request_id, attention_item_id,
         recipient_label, to_address, discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html,
         buttons, is_test
    from public.message where id = p_message_id
  returning id into v_id;
  perform private.log_event('Team actions', case when m.status = 'Cancelled' then 'Sent again after it was blocked: ' else 'Resent ' end
      || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
    'message', v_id, null, null, null, m.domain_id, null, m.module_week_id, null, m.instructor_id);
  perform private.queue_deliver('resend');
  return jsonb_build_object('ok', true, 'message_id', v_id);
end;
$$;

-- The setting, for admins on Settings, Admin; every change is in Activity history.
create or replace function public.set_beta_list_recipients(p_on boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_old boolean;
begin
  perform private.require_admin();
  if p_on is null then raise exception 'Choose on or off.' using errcode = '22023'; end if;
  select beta_list_may_receive into v_old from public.app_config where id = 1 for update;
  if v_old is distinct from p_on then
    update public.app_config set beta_list_may_receive = p_on where id = 1;
    perform private.log_event('Setup changes', case when p_on then 'People on the beta list may receive messages'
                                                   else 'People on the beta list receive messages only after signing in' end,
      'app_config', null, jsonb_build_object('beta_list_may_receive', v_old), jsonb_build_object('beta_list_may_receive', p_on));
  end if;
  return jsonb_build_object('ok', true, 'beta_list_may_receive', p_on);
end;
$$;
revoke execute on function public.set_beta_list_recipients(boolean) from public, anon;
grant execute on function public.set_beta_list_recipients(boolean) to authenticated, service_role;

-- Poke n8n at once when work arrives: a message ready to send or an app action (a Discord check, a server refresh).
-- At most one poke every 5 seconds; the 2 minute clock stays as the safety net. pg_net sends it after the commit, so
-- the save that queued the work never waits for n8n. Any problem here is ignored: the clock delivers anyway.
create or replace function private.poke_soon(p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_id int;
begin
  if not coalesce((select c.clock_enabled from public.app_config c where c.id = 1), false) then return; end if;
  select s.id into v_id from public.clock_state s
   where s.id = 1 and (s.last_poke_at is null or s.last_poke_at < now() - interval '5 seconds')
   for update skip locked;
  if v_id is null then return; end if;
  if private.poke_n8n(p_reason) = 'sent' then
    update public.clock_state set last_poke_at = now(), last_reason = p_reason, last_result = 'sent', updated_at = now()
     where id = 1;
  end if;
exception when others then
  null;
end;
$$;
revoke execute on function private.poke_soon(text) from public, anon;

create or replace function private.poke_on_message()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from new_rows n where n.status = 'Pending' and n.direction = 'Outbound') then
    perform private.poke_soon('a message to send');
  end if;
  return null;
end;
$$;
create or replace function private.poke_on_action()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from new_rows n where n.status = 'Queued') then
    perform private.poke_soon(case when exists (select 1 from new_rows n where left(n.action, 8) = 'discord_')
                                   then 'a Discord check' else 'an app action' end);
  end if;
  return null;
end;
$$;
drop trigger if exists poke_on_message_insert on public.message;
drop trigger if exists poke_on_message_update on public.message;
drop trigger if exists poke_on_action_insert on public.action_queue;
create trigger poke_on_message_insert after insert on public.message
  referencing new table as new_rows for each statement execute function private.poke_on_message();
create trigger poke_on_message_update after update on public.message
  referencing new table as new_rows for each statement execute function private.poke_on_message();
create trigger poke_on_action_insert after insert on public.action_queue
  referencing new table as new_rows for each statement execute function private.poke_on_action();
