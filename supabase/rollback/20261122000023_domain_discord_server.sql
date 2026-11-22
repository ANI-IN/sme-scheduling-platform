-- Rollback of 20261122000023_domain_discord_server.sql (decision 312). Puts back get_started as it was in
-- 20261113000002_core_archive_delete.sql.

create or replace function public.get_started()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select case when private.is_team_user() then jsonb_build_array(
    jsonb_build_object('key', 'domain', 'label', 'Add a domain', 'link', '/setup/domains',
      'done', exists (select 1 from public.domain where archived_at is null)),
    jsonb_build_object('key', 'discord', 'label', 'Choose its Discord server', 'link', '/settings/connections',
      'done', exists (select 1 from public.domain where archived_at is null and discord_server_id is not null)),
    jsonb_build_object('key', 'team', 'label', 'Add team members', 'link', '/setup/team',
      'done', exists (select 1 from public.domain_team)
              or (select count(*) from public.team_member where active and access_removed_at is null) > 1),
    jsonb_build_object('key', 'instructors', 'label', 'Add instructors', 'link', '/setup/instructors',
      'done', exists (select 1 from public.instructor where status = 'Active')),
    jsonb_build_object('key', 'modules', 'label', 'Add modules', 'link', '/setup/modules',
      'done', exists (select 1 from public.module where status = 'Active')),
    jsonb_build_object('key', 'cohort', 'label', 'Create a cohort', 'link', '/setup/domains',
      'done', exists (select 1 from public.cohort where archived_at is null)),
    jsonb_build_object('key', 'classes', 'label', 'Plan classes', 'link', '/classes',
      'done', exists (select 1 from public.module_week))
  ) else '[]'::jsonb end;
$$;
