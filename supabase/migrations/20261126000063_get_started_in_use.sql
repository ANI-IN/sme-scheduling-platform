-- Decision 351 (owner, 26 November 2026): Get started counts only what is in use.
--  * Modules, cohorts and planned classes of archived domains never tick a step.
--  * With a domain chosen in the menu, the domain steps (server, modules, cohort, classes) are about that domain.
--  * A team member counts while they are active and have access; an instructor while they are in use.
-- The app before this change calls get_started with no domain, which then counts every domain in use.
-- Rollback: supabase/rollback/20261126000063_get_started_in_use.sql.

drop function if exists public.get_started();

create or replace function public.get_started(p_domain_id uuid default null)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with in_use as (
    select d.id, d.discord_server_id from public.domain d where d.archived_at is null
  ), chosen as (
    select * from in_use where p_domain_id is null or in_use.id = p_domain_id
  ), people as (
    select t.id from public.team_member t where t.active and t.access_removed_at is null
  )
  select case when private.is_team_user() then jsonb_build_array(
    jsonb_build_object('key', 'domain', 'label', 'Add a domain', 'link', '/setup/domains',
      'done', exists (select 1 from in_use)),
    jsonb_build_object('key', 'discord', 'label', 'Choose its Discord server', 'link', '/setup/domains',
      'done', exists (select 1 from chosen where chosen.discord_server_id is not null)),
    jsonb_build_object('key', 'team', 'label', 'Add team members', 'link', '/setup/team',
      'done', exists (select 1 from public.domain_team x join in_use on in_use.id = x.domain_id
                        join people on people.id = x.team_member_id)
              or (select count(*) from people) > 1),
    jsonb_build_object('key', 'instructors', 'label', 'Add instructors', 'link', '/setup/instructors',
      'done', exists (select 1 from public.instructor where status = 'Active')),
    jsonb_build_object('key', 'modules', 'label', 'Add modules', 'link', '/setup/modules',
      'done', exists (select 1 from public.module m join chosen on chosen.id = m.domain_id where m.status = 'Active')),
    jsonb_build_object('key', 'cohort', 'label', 'Create a cohort', 'link', '/setup/domains',
      'done', exists (select 1 from public.cohort c join chosen on chosen.id = c.domain_id where c.archived_at is null)),
    jsonb_build_object('key', 'classes', 'label', 'Plan classes', 'link', '/classes',
      'done', exists (select 1 from public.module_week w join chosen on chosen.id = w.domain_id))
  ) else '[]'::jsonb end;
$$;
revoke execute on function public.get_started(uuid) from public, anon;
grant execute on function public.get_started(uuid) to authenticated;
