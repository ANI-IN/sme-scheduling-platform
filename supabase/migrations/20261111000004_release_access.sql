-- Release Milestone 3: sign in and access.
-- Google sign in only (the development email link works only when the environment is Development),
-- the company email domain and Google's hosted domain claim are checked in the database (sign in
-- hook and row level security), team members are created on first sign in, and access can be removed.

alter table public.app_config add column environment text not null default 'Development'
  check (environment in ('Development', 'Sandbox', 'Production'));

alter table public.team_member add column auth_user_id uuid;
alter table public.team_member add column last_sign_in_at timestamptz;
alter table public.team_member add column access_removed_at timestamptz;
alter table public.team_member add column access_removed_by uuid references public.team_member (id) on delete set null;
alter table public.team_member add column discord_prompt_dismissed_at timestamptz;

-- -------------------------------------------------------------------------------------
-- One rule for who may sign in, used by the sign in hook, row level security and the app
-- -------------------------------------------------------------------------------------
create or replace function private.jwt_provider()
returns text language sql stable set search_path = ''
as $$ select (select auth.jwt()) -> 'app_metadata' ->> 'provider'; $$;

-- Google's hosted domain ("hd") claim: present only for Google Workspace accounts.
create or replace function private.jwt_hd()
returns text language sql stable set search_path = ''
as $$
  select coalesce(j -> 'user_metadata' -> 'custom_claims' ->> 'hd', j -> 'user_metadata' ->> 'hd')
    from (select (select auth.jwt()) as j) x;
$$;

-- Null when the account may sign in, otherwise the reason in plain words.
create or replace function private.sign_in_problem(p_email text, p_provider text, p_hd text)
returns text language sql stable security definer set search_path = ''
as $$
  select case
    when coalesce(c.company_email_domain, '') = '' then
      'Sign in is not set up yet. Ask the admin to set the company email domain.'
    when lower(split_part(coalesce(p_email, ''), '@', 2)) <> lower(c.company_email_domain) then
      'Only company Google accounts can use SME Scheduling.'
    when c.environment <> 'Development' and coalesce(p_provider, '') <> 'google' then
      'Please sign in with your company Google account.'
    when c.environment <> 'Development' and lower(coalesce(p_hd, '')) <> lower(c.company_email_domain) then
      'Only company Google accounts can use SME Scheduling.'
    when exists (select 1 from public.team_member t where lower(t.email) = lower(p_email) and t.access_removed_at is not null) then
      'Your access to SME Scheduling was removed. Ask your team lead if you think this is a mistake.'
  end
  from public.app_config c where c.id = 1;
$$;

-- Every row level security policy and every app function uses this check.
create or replace function private.is_team_user()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select auth.role()) = 'authenticated'
    and private.sign_in_problem(private.current_email(), private.jwt_provider(), private.jwt_hd()) is null,
    false);
$$;

-- Supabase calls this before creating a new user (Authentication, Hooks, "Before user created").
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_email text := lower(event -> 'user' ->> 'email');
  v_provider text := coalesce(event -> 'user' -> 'app_metadata' ->> 'provider', 'email');
  v_hd text := coalesce(event -> 'user' -> 'user_metadata' -> 'custom_claims' ->> 'hd', event -> 'user' -> 'user_metadata' ->> 'hd');
  v_problem text := private.sign_in_problem(v_email, v_provider, v_hd);
begin
  if v_problem is not null then
    insert into public.history_event (actor_kind, actor_label, category, action, note)
    values ('System', 'Sign in', 'System', 'Sign in refused', v_problem || ' Account: ' || coalesce(v_email, 'no email') || '.');
    return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', v_problem));
  end if;
  return '{}'::jsonb;
end;
$$;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, anon, public;

-- -------------------------------------------------------------------------------------
-- The signed in person: created on first sign in, Discord ID asked for once
-- -------------------------------------------------------------------------------------
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
    insert into public.team_member (name, email, auth_user_id, last_sign_in_at)
    values (v_name, v_email, (select auth.uid()), now())
    returning * into t;
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

-- Add your own Discord user ID, or say "later" (the prompt is not shown again).
create or replace function public.update_my_profile(p_discord_user_id text default null, p_dismiss_discord_prompt boolean default false)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_id uuid := private.current_team_member_id();
begin
  perform private.require_team();
  if v_id is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  if nullif(trim(coalesce(p_discord_user_id, '')), '') is not null then
    if trim(p_discord_user_id) !~ '^\d{17,20}$' then
      raise exception 'A Discord user ID is 17 to 20 digits.' using errcode = '22023';
    end if;
    if exists (select 1 from public.team_member where discord_user_id = trim(p_discord_user_id) and id <> v_id) then
      raise exception 'Another team member already uses this Discord user ID.' using errcode = '23505';
    end if;
    update public.team_member set discord_user_id = trim(p_discord_user_id), version = version where id = v_id;
  elsif p_dismiss_discord_prompt then
    perform set_config('app.suppress_setup_log', 'on', true);
    update public.team_member set discord_prompt_dismissed_at = now(), version = version where id = v_id;
    perform set_config('app.suppress_setup_log', 'off', true);
  end if;
end;
$$;

-- "Remove access" on the Team page. Removed people cannot sign in, see data or be tagged.
create or replace function public.set_member_access(p_team_member_id uuid, p_has_access boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare t public.team_member; v_me uuid := private.current_team_member_id();
begin
  perform private.require_team();
  select * into t from public.team_member where id = p_team_member_id for update;
  if t.id is null then raise exception 'Team member not found.' using errcode = '22023'; end if;
  if not p_has_access and t.id = v_me then
    raise exception 'You cannot remove your own access.' using errcode = '22023';
  end if;
  if p_has_access = (t.access_removed_at is null) then return; end if;
  perform set_config('app.suppress_setup_log', 'on', true);
  update public.team_member
     set access_removed_at = case when p_has_access then null else now() end,
         access_removed_by = case when p_has_access then null else v_me end,
         active = p_has_access,
         version = version
   where id = t.id;
  perform set_config('app.suppress_setup_log', 'off', true);
  perform private.log_event('Setup changes', case when p_has_access then 'Access given back' else 'Access removed' end,
    'team_member', t.id, jsonb_build_object('name', t.name, 'has_access', not p_has_access),
    jsonb_build_object('name', t.name, 'has_access', p_has_access), nullif(trim(coalesce(p_reason, '')), ''));
end;
$$;

-- Set by the setup script from environment variables (ALLOWED_EMAIL_DOMAIN, APP_ENVIRONMENT).
create or replace function public.configure_environment(p_environment text, p_allowed_email_domain text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_service() then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_environment not in ('Development', 'Sandbox', 'Production') then
    raise exception 'The environment must be Development, Sandbox or Production.' using errcode = '22023';
  end if;
  if coalesce(trim(p_allowed_email_domain), '') !~ '^[a-z0-9.-]+\.[a-z]{2,}$' then
    raise exception 'The allowed email domain should look like yourcompany.com.' using errcode = '22023';
  end if;
  update public.app_config set environment = p_environment, company_email_domain = lower(trim(p_allowed_email_domain)) where id = 1;
  perform private.log_event('System', 'Environment set to ' || p_environment, 'app_config', null, null,
    jsonb_build_object('environment', p_environment, 'allowed_email_domain', lower(trim(p_allowed_email_domain))));
end;
$$;

grant execute on function public.my_account(boolean) to authenticated;
grant execute on function public.update_my_profile(text, boolean) to authenticated;
grant execute on function public.set_member_access(uuid, boolean, text) to authenticated;
revoke execute on function public.my_account(boolean) from anon, public;
revoke execute on function public.update_my_profile(text, boolean) from anon, public;
revoke execute on function public.set_member_access(uuid, boolean, text) from anon, public;
revoke execute on function public.configure_environment(text, text) from anon, authenticated, public;
grant execute on function public.configure_environment(text, text) to service_role;
