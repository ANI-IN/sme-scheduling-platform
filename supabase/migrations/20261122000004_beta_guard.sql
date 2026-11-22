-- Release 3, M3: the beta message guard (docs/PLAN_RELEASE_3.md, decisions 277 and 287).
--
-- Two settings, changed only by an admin (public.set_recipient_rules), each change logged:
--   * "Who may receive email" (app_config.recipient_email_domains): when the list is not empty, email goes only to
--     addresses at these domains (yourcompany.com for the beta).
--   * "Who may receive messages" (app_config.message_recipients): 'Test instructors and signed in colleagues' (the beta)
--     or 'Anyone'. In the beta setting only test instructors are contacted, a Discord direct message goes only to the
--     Discord account of a team member who has signed in, and a message may only tag such accounts.
-- The guard is checked when a message is queued and again when n8n claims it (the existing trigger
-- message_environment_guard), so a change in between cannot let a message out; a blocked message is cancelled with
-- its reason and logged in Activity history ("Message blocked"). While the beta setting is on, Production's rule
-- that never asks test instructors is lifted (eligibility and the guard); 'Anyone' and an empty email list restore
-- today's Production rules exactly. The Sandbox rules stay as they are until the switch (M5).
-- A daily email cap (app_config.daily_email_cap, 1,000): emails wait when it is reached, with one task a day.
-- Rollback: supabase/rollback/20261122000004_beta_guard.sql.

alter table public.app_config add column recipient_email_domains text[] not null default '{}';
alter table public.app_config add column message_recipients text not null default 'Anyone'
  check (message_recipients in ('Anyone', 'Test instructors and signed in colleagues'));
alter table public.app_config add column daily_email_cap int not null default 1000 check (daily_email_cap between 1 and 2000);

-- A Discord account that belongs to a colleague who has signed in and still has access.
create or replace function private.is_signed_in_colleague_discord(p_discord_user_id text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.team_member t
                  where t.discord_user_id = p_discord_user_id and t.auth_user_id is not null and t.access_removed_at is null);
$$;

-- Emails the app may still send in the rolling last 24 hours.
create or replace function private.email_cap_left()
returns int language sql stable security definer set search_path = ''
as $$
  select (select c.daily_email_cap from public.app_config c where c.id = 1)
       - (select count(*)::int from public.message m
           where m.direction = 'Outbound' and m.channel = 'Email' and m.status in ('Sent', 'Sending')
             and coalesce(m.sent_at, m.claimed_at) > now() - interval '24 hours');
$$;

-- The two settings and the cap, for admins.
create or replace function public.set_recipient_rules(p_email_domains text[], p_message_recipients text,
  p_daily_email_cap int default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_domains text[] := array(select distinct lower(trim(x)) from unnest(coalesce(p_email_domains, '{}')) x where trim(x) <> '' order by 1);
  c public.app_config;
begin
  perform private.require_admin();
  if p_message_recipients not in ('Anyone', 'Test instructors and signed in colleagues') then
    raise exception 'Choose "Anyone" or "Test instructors and signed in colleagues".' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_domains) x where x !~ '^[a-z0-9.-]+\.[a-z]{2,}$') then
    raise exception 'Each email domain should look like yourcompany.com.' using errcode = '22023';
  end if;
  if p_daily_email_cap is not null and p_daily_email_cap not between 1 and 2000 then
    raise exception 'The daily email limit must be between 1 and 2,000 (Google''s own limit is about 2,000).' using errcode = '22023';
  end if;
  select * into c from public.app_config where id = 1 for update;
  update public.app_config
     set recipient_email_domains = v_domains, message_recipients = p_message_recipients,
         daily_email_cap = coalesce(p_daily_email_cap, daily_email_cap)
   where id = 1;
  perform private.log_event('Setup changes', 'Who may receive messages changed', 'app_config', null,
    jsonb_build_object('email_domains', to_jsonb(c.recipient_email_domains), 'message_recipients', c.message_recipients,
      'daily_email_cap', c.daily_email_cap),
    jsonb_build_object('email_domains', to_jsonb(v_domains), 'message_recipients', p_message_recipients,
      'daily_email_cap', coalesce(p_daily_email_cap, c.daily_email_cap)));
end;
$$;
revoke execute on function public.set_recipient_rules(text[], text, int) from public, anon;
grant execute on function public.set_recipient_rules(text[], text, int) to authenticated, service_role;
revoke execute on function private.email_cap_left(), private.is_signed_in_colleague_discord(text) from public, anon;
grant execute on function private.email_cap_left(), private.is_signed_in_colleague_discord(text) to authenticated, service_role;

-- private.message_block_reason: Production's rule against test instructors only when the beta setting is off and the beta guard (was 20261112000007_r2_review_fixes_3.sql).
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
      return 'During the beta, email goes only to ' || array_to_string(c.recipient_email_domains, ', ') || ' addresses. '
        || coalesce(nullif(v_domain, ''), 'This address') || ' is not one of them.';
    end if;
  end if;
  if c.message_recipients = 'Test instructors and signed in colleagues' then
    if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false) then
      return 'During the beta, only test instructors are contacted. Mark ' || coalesce(i.full_name, 'this instructor')
        || ' as a test instructor to try this.';
    end if;
    if m.channel = 'Discord' then
      if m.discord_dm_user_id is not null and not private.is_signed_in_colleague_discord(m.discord_dm_user_id) then
        return 'During the beta, direct messages go only to the Discord accounts of signed in colleagues. Test instructors use a colleague''s own account.';
      end if;
      if exists (select 1 from unnest(coalesce(m.mention_user_ids, '{}')) x where not private.is_signed_in_colleague_discord(x)) then
        return 'During the beta, a message may only tag signed in colleagues. It tags a Discord account that is not one.';
      end if;
    end if;
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
      if not (v_server = any (c.sandbox_allowed_discord_servers)) then
        return 'Sandbox only posts to allowed Discord servers. Server ' || v_server || ' is not on the list.';
      end if;
    end if;
  end if;
  return null;
end;
$$;

-- private.eligibility: test instructors allowed while the beta setting is on (was 20261113000004_sandbox_live_test_instructors.sql).
create or replace function private.eligibility(p_instructor uuid, p_mw uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_domain uuid;
  v_status text;
  v_reason text;
begin
  select * into i from public.instructor where id = p_instructor;
  select w.domain_id, d.status into v_domain, v_status
    from public.module_week w join public.domain d on d.id = w.domain_id where w.id = p_mw;
  if i.id is null then return 'Unknown instructor'; end if;
  if i.status = 'Inactive' then return 'Inactive'; end if;
  if i.status = 'Archived' then return 'Archived'; end if;
  if v_status = 'Live' and i.is_test
     and (select c.environment from public.app_config c where c.id = 1) <> 'Sandbox'
     and (select c.message_recipients from public.app_config c where c.id = 1) = 'Anyone' then return 'Test instructor (not allowed in Live domains)'; end if;
  if v_status = 'Live' and i.verified_at is null then return 'Not verified'; end if;
  if i.discord_user_id is null and i.email_bounced_at is not null then return 'No working contact details'; end if;

  select 'Unavailable ' || to_char(u.from_date, 'Mon FMDD') || ' to ' || to_char(u.to_date, 'Mon FMDD')
    into v_reason
    from public.instructor_unavailability u
   where u.instructor_id = p_instructor
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and (c.starts_at at time zone private.region_tz(c.region))::date between u.from_date and u.to_date)
   order by u.from_date limit 1;
  if v_reason is not null then return v_reason; end if;

  -- Clashes are checked on the real time (UTC), across every cohort, domain and region.
  return private.week_clash(p_instructor, p_mw);
end;
$$;

-- public.claim_outbound_messages: emails wait when the daily cap is reached (was 20261113000002_core_archive_delete.sql).
create or replace function public.claim_outbound_messages(p_limit int default 25)
returns setof public.message language plpgsql security definer set search_path = ''
as $$
declare v_stuck uuid;
begin
  perform private.require_team();
  -- OUT-2: drop what should no longer go out before handing messages to n8n.
  perform private.cancel_stale_messages();
  -- DIS-13: never send again what may already have arrived (Discord only drops a repeated nonce for a
  -- few minutes, and Gmail never does). It fails like any other message, with a task to check.
  for v_stuck in select id from public.message where status = 'Sending' and claimed_at < now() - interval '15 minutes' loop
    perform public.report_message_result(v_stuck,
      false, null,
      'The automation took this message but never said whether it was sent, so it may or may not have arrived. Check, and send it again if it did not.',
      true);
  end loop;
  -- The daily email cap (decision 287): one task a day when emails are waiting for it.
  if (select private.email_cap_left()) <= 0
     and exists (select 1 from public.message m where m.status = 'Pending' and m.direction = 'Outbound' and m.channel = 'Email')
     and not exists (select 1 from public.attention_item a where a.dedupe_key = 'email-cap:' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD')) then
    insert into public.attention_item (type, severity, title, detail, dedupe_key)
    values ('Other', 'Urgent', 'Daily email limit reached',
      'The app has sent ' || (select c.daily_email_cap from public.app_config c where c.id = 1) || ' emails in the last 24 hours. '
      || 'The rest wait and go out by themselves as the limit frees up. Discord messages are not affected.',
      'email-cap:' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD'));
  end if;
  return query
  with c as (
    select m.id from public.message m left join public.domain d on d.id = m.domain_id
     where m.status = 'Pending' and m.direction = 'Outbound'
       and (m.channel <> 'Email' or (select private.email_cap_left()) > 0)
       and (m.audience <> 'Instructor'
            or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                and coalesce(d.status, 'Live') <> 'Paused' and d.archived_at is null))
     order by m.created_at
     limit greatest(1, least(p_limit, 100))
     for update of m skip locked),
  u as (
    update public.message m set status = 'Sending', claimed_at = now(), attempts = m.attempts + 1
      from c where m.id = c.id
    returning m.*)
  select (jsonb_populate_record(null::public.message, to_jsonb(u) || jsonb_build_object(
           'body_text', private.with_tokens(u.body_text, u.instructor_id, u.team_member_id, u.is_test),
           'body_html', private.with_tokens(u.body_html, u.instructor_id, u.team_member_id, u.is_test),
           'buttons', private.with_tokens(u.buttons::text, u.instructor_id, u.team_member_id, u.is_test)::jsonb))).*
    from u;
end;
$$;

-- private.clock_work: held emails are not work (was 20261122000002_database_clock.sql).
create or replace function private.clock_work(p_now timestamptz default null)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_interval interval := private.clock_reply_interval(public.n8n_runs_this_month(v_now));
  v_read timestamptz := (select last_reply_read_at from public.clock_state where id = 1);
begin
  if exists (select 1 from public.message m left join public.domain d on d.id = m.domain_id
              where m.status = 'Pending' and m.direction = 'Outbound'
                and (m.channel <> 'Email' or (select private.email_cap_left()) > 0)
                and (m.audience <> 'Instructor'
                     or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                         and coalesce(d.status, 'Live') <> 'Paused' and d.archived_at is null))) then
    return 'messages to send';
  end if;
  if exists (select 1 from public.action_queue a where a.status = 'Queued' and left(a.action, 8) <> 'discord_') then
    return 'app actions';
  end if;
  if exists (select 1 from public.action_queue a where a.status = 'Queued' and left(a.action, 8) = 'discord_') then
    return 'Discord checks';
  end if;
  -- An open conversation: something was sent to an instructor in the last 3 days, so a typed reply may come.
  if v_interval is not null and (v_read is null or v_read <= v_now - v_interval)
     and exists (select 1 from public.message m where m.direction = 'Outbound' and m.audience = 'Instructor'
                    and m.status = 'Sent' and m.sent_at > v_now - interval '3 days') then
    return 'reading replies';
  end if;
  return null;
end;
$$;
