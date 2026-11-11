-- Core readiness, step 2: the app starts empty (decisions 250 to 253).
-- No sample domains, people, classes or holidays are ever loaded by the app. "Reset Sandbox data" empties
-- the Sandbox; the automated tests load their own data into their own local stack (scripts/src/test-stack.ts
-- and supabase/tests/fixtures/starting_data.sql).

drop function if exists public.reset_sandbox_data(text, text, text, text);
drop function if exists private.load_sandbox_seed(text, text, text);

create or replace function public.reset_sandbox_data(p_confirm text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_env text := (select environment from public.app_config where id = 1);
begin
  perform private.require_team();
  if v_env = 'Production' then
    raise exception 'Sandbox data can never be reset in Production.' using errcode = '42501';
  end if;
  -- SEC-6: only a database that was set up as Sandbox (or local development) on purpose.
  if (select environment_set_at from public.app_config where id = 1) is null then
    raise exception 'This database was never set up with npm run configure, so its data cannot be reset.' using errcode = '42501';
  end if;
  perform set_config('app.reset_sandbox', 'on', true);
  if p_confirm is distinct from 'RESET' then
    raise exception 'Type RESET to confirm.' using errcode = '22023';
  end if;
  perform private.log_event('System', 'Sandbox data reset started');
  -- Run any checks still waiting in this transaction (instructor order) before clearing tables.
  set constraints all immediate;
  truncate table public.message, public.request, public.response_link, public.booking_slot, public.booking,
    public.checklist_item, public.help_request, public.reminder, public.attention_item, public.manual_queue_item,
    public.class_session, public.module_week, public.module_operations, public.module_ranking,
    public.module_owner, public.module_resource, public.class_pattern_item, public.module, public.cohort,
    public.class_type, public.message_template, public.domain_team, public.instructor_unavailability,
    public.instructor_email, public.instructor_channel, public.instructor, public.action_queue, public.app_error,
    public.holiday, public.domain, public.discord_cursor
    restart identity cascade;
  -- Settings for one domain, cohort, module or class week went with them; settings for every domain stay.
  delete from public.setting where scope <> 'Global';
  -- Real people keep their sign in and profile; people nobody signs in as (placeholders) go.
  delete from public.team_member where is_placeholder and auth_user_id is null;
  update public.system_state set outreach_enabled = true where id = 1;
  set constraints all deferred;
  perform private.log_event('System', 'Sandbox data reset', null, null, null,
    jsonb_build_object('emptied', true));
  return jsonb_build_object('emptied', true);
end;
$$;
grant execute on function public.reset_sandbox_data(text) to authenticated;

-- The "Get started" list on Home: what is still missing before classes can be planned and asked for.
create or replace function public.get_started()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select case when private.is_team_user() then jsonb_build_array(
    jsonb_build_object('key', 'domain', 'label', 'Add a domain', 'link', '/setup/domains',
      'done', exists (select 1 from public.domain)),
    jsonb_build_object('key', 'discord', 'label', 'Choose its Discord server', 'link', '/settings/connections',
      'done', exists (select 1 from public.domain where discord_server_id is not null)),
    jsonb_build_object('key', 'team', 'label', 'Add team members', 'link', '/setup/team',
      'done', exists (select 1 from public.domain_team)
              or (select count(*) from public.team_member where active and access_removed_at is null) > 1),
    jsonb_build_object('key', 'instructors', 'label', 'Add instructors', 'link', '/setup/instructors',
      'done', exists (select 1 from public.instructor where status = 'Active')),
    jsonb_build_object('key', 'modules', 'label', 'Add modules', 'link', '/setup/modules',
      'done', exists (select 1 from public.module where status = 'Active')),
    jsonb_build_object('key', 'cohort', 'label', 'Create a cohort', 'link', '/setup/domains',
      'done', exists (select 1 from public.cohort)),
    jsonb_build_object('key', 'classes', 'label', 'Plan classes', 'link', '/classes',
      'done', exists (select 1 from public.module_week))
  ) else '[]'::jsonb end;
$$;
grant execute on function public.get_started() to authenticated;
