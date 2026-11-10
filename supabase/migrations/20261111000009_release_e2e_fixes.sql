-- Release Milestone 8: fixes found by the end to end tests.
-- Time ranges and other text built by the database use "to" instead of a dash, so warnings,
-- reasons and error messages read the same as everything else in the app.

create or replace function private.fmt_pt_range(p_start timestamptz, p_end timestamptz)
returns text language sql immutable set search_path = ''
as $$
  select to_char(p_start at time zone 'America/Los_Angeles', 'Dy, Mon FMDD · FMHH12:MI AM') || ' to '
      || to_char(p_end at time zone 'America/Los_Angeles', 'FMHH12:MI AM') || ' ' || private.pt_abbrev(p_start);
$$;

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
  if v_status = 'Live' and i.is_test then return 'Test instructor (not allowed in Live domains)'; end if;
  if v_status = 'Live' and i.verified_at is null then return 'Not verified'; end if;
  if i.discord_channel_id is null and i.email_bounced_at is not null then return 'No working contact details'; end if;

  select 'Unavailable ' || to_char(u.from_date, 'Mon FMDD') || ' to ' || to_char(u.to_date, 'Mon FMDD')
    into v_reason
    from public.instructor_unavailability u
   where u.instructor_id = p_instructor
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and (c.starts_at at time zone 'America/Los_Angeles')::date between u.from_date and u.to_date)
   order by u.from_date limit 1;
  if v_reason is not null then return v_reason; end if;

  select 'Teaching ' || case when w2.domain_id <> v_domain then d2.name else m2.name end || ' at this time'
    into v_reason
    from public.booking_slot s
    join public.booking b on b.id = s.booking_id
    join public.module_week w2 on w2.id = b.module_week_id
    join public.module m2 on m2.id = w2.module_id
    join public.domain d2 on d2.id = w2.domain_id
   where s.instructor_id = p_instructor and s.active and b.module_week_id <> p_mw
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and tstzrange(c.starts_at, c.ends_at, '[)') && s.time_range)
   limit 1;
  return v_reason;
end;
$$;

create or replace function public.set_test_targets(p_domain_id uuid, p_test_discord_channel_id text, p_test_email text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if p_test_discord_channel_id is not null and p_test_discord_channel_id !~ '^\d{17,20}$' then
    raise exception 'The test Discord channel ID must be 17 to 20 digits.';
  end if;
  if p_test_email is not null and p_test_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid test email address.';
  end if;
  update public.domain set test_discord_channel_id = nullif(p_test_discord_channel_id, ''), test_email = nullif(p_test_email, '')
   where id = p_domain_id;
end;
$$;

-- First sign in: two requests at once must not fail with a conflict.
create or replace function public.my_account(p_signed_in boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_email text := private.current_email();
  v_problem text;
  v_meta jsonb := (select auth.jwt()) -> 'user_metadata';
  v_name text;
  t public.team_member;
begin
  if (select auth.role()) is distinct from 'authenticated' or v_email is null then
    raise exception 'Please sign in first.' using errcode = '42501';
  end if;
  v_problem := private.sign_in_problem(v_email, private.jwt_provider(), private.jwt_hd());
  if v_problem is not null then
    if p_signed_in then
      perform set_config('app.actor_kind', 'System', true);
      perform set_config('app.actor_label', 'Sign in', true);
      perform private.log_event('System', 'Sign in refused', 'team_member',
        (select id from public.team_member where lower(email) = v_email), null, null,
        v_problem || ' Account: ' || v_email || '.');
    end if;
    return jsonb_build_object('allowed', false, 'message', v_problem);
  end if;

  select * into t from public.team_member where lower(email) = v_email;
  if t.id is null then
    v_name := coalesce(nullif(trim(v_meta ->> 'full_name'), ''), nullif(trim(v_meta ->> 'name'), ''),
                       initcap(replace(replace(split_part(v_email, '@', 1), '.', ' '), '_', ' ')));
    -- The app can ask twice at the same moment on a first sign in: the second request
    -- finds the row the first one created instead of failing.
    insert into public.team_member (name, email, auth_user_id, last_sign_in_at)
    values (v_name, v_email, (select auth.uid()), now())
    on conflict do nothing;
    select * into t from public.team_member where lower(email) = v_email;
  elsif p_signed_in then
    perform set_config('app.suppress_setup_log', 'on', true);
    update public.team_member
       set last_sign_in_at = now(), auth_user_id = coalesce(auth_user_id, (select auth.uid()))
     where id = t.id
    returning * into t;
    perform set_config('app.suppress_setup_log', 'off', true);
  end if;
  if p_signed_in then
    perform private.log_event('Team actions', 'Signed in', 'team_member', t.id);
  end if;
  return jsonb_build_object(
    'allowed', true,
    'member', jsonb_build_object('id', t.id, 'name', t.name, 'email', t.email, 'discord_user_id', t.discord_user_id,
                                 'job_title', t.job_title, 'is_placeholder', t.is_placeholder),
    'needs_discord', t.discord_user_id is null and t.discord_prompt_dismissed_at is null,
    'environment', (select c.environment from public.app_config c where c.id = 1));
end;
$$;
