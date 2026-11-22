-- Rollback for 20261122000002_database_clock.sql: removes the database clock and the n8n run counter, and puts
-- back the five counted functions exactly as they were. The pg_cron and pg_net extensions are left installed (they
-- are Supabase's own and harmless when no job uses them).

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobname) from cron.job where jobname in ('sme-engine-hourly', 'sme-clock');
  end if;
end;
$$;

-- public.next_actions, as in 20261112000003_r2_discord_lookup.sql.
create or replace function public.next_actions(p_limit int default 20)
returns setof public.action_queue language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  return query
  with c as (select a.id from public.action_queue a where a.status = 'Queued' and left(a.action, 8) <> 'discord_' order by a.created_at limit p_limit for update skip locked)
  update public.action_queue a set status = 'Processing' from c where a.id = c.id returning a.*;
end;
$$;

-- public.engine_tick_all, as in 20261113000002_core_archive_delete.sql.
create or replace function public.engine_tick_all(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  d record;
  v jsonb := '[]';
  v_res jsonb;
  v_err text;
  v_errors int := 0;
begin
  perform private.require_team();
  for d in select * from public.domain where status in ('Test', 'Live', 'Paused') and archived_at is null order by name loop
    begin
      v_res := public.engine_tick(d.id, p_now);
      v := v || v_res;
    exception when others then
      get stacked diagnostics v_err = message_text;
      v_errors := v_errors + 1;
      v := v || jsonb_build_object('domain', d.name, 'error', v_err);
      perform private.set_actor('System', null, 'System');
      perform private.log_event('System', 'Hourly check failed: ' || d.name, 'domain', d.id, null, null, v_err, d.id);
      perform private.queue_team_message('T14', d.id, 'admin', null, '{}', 'Hourly check failed: ' || d.name,
        '❗ Hourly check failed for ' || d.name || ': ' || v_err, 'T14:tick:' || d.id || ':' || to_char(now(), 'YYYYMMDDHH24'), now());
    end;
  end loop;
  perform private.set_actor('System', null, 'System');
  perform private.send_digests(coalesce(p_now, now()));
  perform private.step_release(null, coalesce(p_now, now()));
  update public.system_state
     set last_hourly_run_at = now(), last_hourly_status = case when v_errors = 0 then 'ok' else v_errors || ' error(s)' end,
         last_hourly_summary = v
   where id = 1;
  return jsonb_build_object('domains', v, 'errors', v_errors);
end;
$$;

-- public.daily_jobs, as in 20261110000003_engine.sql.
create or replace function public.daily_jobs(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  s public.system_state;
  v_text text;
  v_sent int; v_failed int; v_open int; v_urgent int;
begin
  perform private.require_team();
  perform private.set_actor('System', null, 'System');
  select * into s from public.system_state where id = 1;
  select count(*) filter (where status = 'Sent' and sent_at > v_now - interval '24 hours'),
         count(*) filter (where status = 'Failed' and updated_at > v_now - interval '24 hours')
    into v_sent, v_failed from public.message;
  select count(*), count(*) filter (where severity = 'Urgent') into v_open, v_urgent from public.attention_item where status <> 'Done';
  v_text := '💓 Daily heartbeat — last hourly run: ' || coalesce(private.fmt_ist(s.last_hourly_run_at), 'never')
    || ' (' || coalesce(s.last_hourly_status, 'n/a') || ')'
    || E'\nMessages sent (24h): ' || v_sent || ' · failed: ' || v_failed
    || E'\nOpen items: ' || v_open || ' (' || v_urgent || ' urgent)'
    || coalesce(E'\nIn TEST MODE: ' || (select string_agg(d.name, ', ') from public.domain d where private.is_test_domain(d.id)), '')
    || case when not s.outreach_enabled then E'\n⛔ Kill switch is ON since ' || coalesce(private.fmt_ist(s.kill_switch_changed_at), '?')
            || ' — no instructor messages are going out. Turn it off in Settings → System when ready.' else '' end;
  perform private.queue_team_message('T15', null, 'admin', null, '{}', 'Daily heartbeat', v_text,
    'T15:' || to_char(v_now at time zone 'Asia/Kolkata', 'YYYY-MM-DD'), v_now);
  update public.system_state set last_daily_run_at = now(), last_heartbeat_at = now() where id = 1;
  perform private.log_event('System', 'Daily jobs', null, null, null,
    jsonb_build_object('sent_24h', v_sent, 'failed_24h', v_failed, 'open', v_open), null);
  return jsonb_build_object('sent_24h', v_sent, 'failed_24h', v_failed, 'open_items', v_open, 'urgent_items', v_urgent);
end;
$$;

-- public.response_page, as in 20261112000007_r2_review_fixes_3.sql.
create or replace function public.response_page(p_token text)
returns public."text/html" language sql security definer set search_path = ''
as $$
  select private.with_tokens(public.response_page_text(p_token),
           (select q.instructor_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.team_member_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.is_test from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token)
         )::public."text/html";
$$;

-- public.submit_response_page, as in 20261112000007_r2_review_fixes_3.sql.
create or replace function public.submit_response_page(p_token text, p_form jsonb default '{}')
returns public."text/html" language sql security definer set search_path = ''
as $$
  select private.with_tokens(public.submit_response_page_text(p_token, p_form),
           (select q.instructor_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.team_member_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.is_test from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token)
         )::public."text/html";
$$;

drop function if exists public.configure_clock(boolean, text);
drop function if exists private.clock_engine(timestamptz);
drop function if exists private.clock_tick(timestamptz);
drop function if exists private.poke_n8n(text);
drop function if exists private.clock_work(timestamptz);
drop function if exists private.clock_reply_interval(int);
drop function if exists public.n8n_runs_this_month(timestamptz);
drop function if exists private.count_n8n_run(text);
alter table public.app_config drop column if exists n8n_poke_url;
alter table public.app_config drop column if exists clock_enabled;
drop table if exists public.clock_state;
drop table if exists public.n8n_usage;
