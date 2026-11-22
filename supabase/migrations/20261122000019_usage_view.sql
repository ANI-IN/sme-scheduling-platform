-- Release 3, M13 (decision 307): the Usage view, for admins.
--
-- One call for Settings, Connections, Usage: the database size against the free plan's 500 MB, messages sent today and
-- this month by channel, the email cap and what is left of it in the last 24 hours, and the n8n runs this month as the
-- app counts them (each workflow's first database call of a run), by workflow, against the 10,000 a month the plan
-- allows. docs/FREE_TIER_LIMITS.md explains each limit and what happens near it.

create or replace function public.usage_summary()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_month date := date_trunc('month', now() at time zone 'UTC')::date;
  v_today date := (now() at time zone 'UTC')::date;
begin
  perform private.require_team();
  if not private.is_admin() then
    raise exception 'Only an admin can see usage.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'database_bytes', pg_database_size(current_database()),
    'database_limit_bytes', 500 * 1024 * 1024,
    'messages', (select jsonb_build_object(
        'today', count(*) filter (where (m.sent_at at time zone 'UTC')::date = v_today),
        'month', count(*) filter (where (m.sent_at at time zone 'UTC')::date >= v_month),
        'email_today', count(*) filter (where m.channel = 'Email' and (m.sent_at at time zone 'UTC')::date = v_today),
        'email_month', count(*) filter (where m.channel = 'Email' and (m.sent_at at time zone 'UTC')::date >= v_month),
        'discord_today', count(*) filter (where m.channel = 'Discord' and (m.sent_at at time zone 'UTC')::date = v_today),
        'discord_month', count(*) filter (where m.channel = 'Discord' and (m.sent_at at time zone 'UTC')::date >= v_month))
      from public.message m
     where m.direction = 'Outbound' and m.status = 'Sent' and m.sent_at >= v_month),
    'email_cap', (select c.daily_email_cap from public.app_config c where c.id = 1),
    'email_cap_left', private.email_cap_left(),
    'n8n_runs_month', public.n8n_runs_this_month(),
    'n8n_limit_month', 10000,
    'n8n_by_workflow', coalesce((select jsonb_agg(jsonb_build_object('workflow', u.workflow, 'runs', u.runs, 'last_at', u.last_at)
                                          order by u.workflow)
                                   from public.n8n_usage u where u.month = v_month), '[]'),
    'n8n_counted_since', (select min(u.month) from public.n8n_usage u),
    'checked_at', now());
end;
$$;

revoke execute on function public.usage_summary() from public, anon;
grant execute on function public.usage_summary() to authenticated, service_role;
