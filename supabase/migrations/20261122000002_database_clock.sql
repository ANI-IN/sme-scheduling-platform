-- Release 3, M1: the database keeps the clock (docs/PLAN_RELEASE_3.md, decision 281).
--
-- Today n8n runs on its own schedule (WF4 every 6 minutes, WF1 every hour) whether or not there is anything to do:
-- about 8,000 to 9,100 executions a month while idle, of the plan's 10,000. With this migration:
--   * the hourly automatic check can run inside the database (pg_cron job "sme-engine-hourly", minute 30, as WF1 did);
--   * every 2 minutes the database asks "is there work for n8n?" (job "sme-clock") and calls WF4 through pg_net only
--     when there is: messages to send, app actions or Discord checks waiting, or an open conversation whose replies
--     have not been read for 10 minutes (20 minutes above 8,000 runs this month; none above 9,300, when replies are
--     still read whenever WF4 runs for other work);
--   * every n8n run is counted per month and workflow (public.n8n_usage), from the first database call each workflow
--     makes, and only when n8n (the service role) makes it.
-- Nothing changes until an admin switches the clock on (public.configure_clock), because the call to WF4 needs the
-- poke key in Supabase Vault (secret "n8n_poke_key"). While it is off both jobs return at once.
-- pg_cron can only be installed in the main "postgres" database, so the throwaway test databases skip the jobs; the
-- tests call the clock's functions directly with a practice clock.
-- Rollback: supabase/rollback/20261122000002_database_clock.sql.

-- Runs per month and workflow, written only for calls made by n8n.
create table public.n8n_usage (
  month date not null,
  workflow text not null check (workflow in ('WF1', 'WF2', 'WF3', 'WF4', 'WF5')),
  runs int not null default 0,
  last_at timestamptz,
  primary key (month, workflow)
);
alter table public.n8n_usage enable row level security;
create policy n8n_usage_team_read on public.n8n_usage for select to authenticated using (private.is_team_user());
grant select on public.n8n_usage to authenticated;
grant select, insert, update on public.n8n_usage to service_role;

-- The clock's own state (one row), kept apart from app_config so its writes do not touch Activity history.
create table public.clock_state (
  id int primary key default 1 check (id = 1),
  last_poke_at timestamptz,
  last_reason text,
  last_result text,
  last_reply_read_at timestamptz,
  budget_alert_month date,
  updated_at timestamptz not null default now()
);
insert into public.clock_state (id) values (1);
alter table public.clock_state enable row level security;
create policy clock_state_team_read on public.clock_state for select to authenticated using (private.is_team_user());
grant select on public.clock_state to authenticated;

alter table public.app_config add column clock_enabled boolean not null default false;
alter table public.app_config add column n8n_poke_url text;

create or replace function private.count_n8n_run(p_workflow text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce((select auth.role()), '') <> 'service_role' then return; end if;
  insert into public.n8n_usage as u (month, workflow, runs, last_at)
  values (date_trunc('month', now() at time zone 'UTC')::date, p_workflow, 1, now())
  on conflict (month, workflow) do update set runs = u.runs + 1, last_at = excluded.last_at;
  -- Every WF4 run reads typed replies (Gmail and the instructors' Discord channels).
  if p_workflow = 'WF4' then
    update public.clock_state set last_reply_read_at = now(), updated_at = now() where id = 1;
  end if;
end;
$$;

-- n8n runs counted this month (UTC), for the brakes and the usage view.
create or replace function public.n8n_runs_this_month(p_now timestamptz default null)
returns int language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(runs), 0)::int from public.n8n_usage
   where month = date_trunc('month', coalesce(p_now, now()) at time zone 'UTC')::date;
$$;

-- How often replies are read while a conversation is open: 10 minutes, 20 above 8,000 runs, never above 9,300.
create or replace function private.clock_reply_interval(p_runs int)
returns interval language sql immutable set search_path = ''
as $$
  select case when p_runs < 8000 then interval '10 minutes' when p_runs < 9300 then interval '20 minutes' end;
$$;

-- The reason n8n has work now, or null when there is none.
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

-- Calls WF4 with the poke key from Vault. Returns 'sent', or why it did not.
create or replace function private.poke_n8n(p_reason text)
returns text language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_url text := (select c.n8n_poke_url from public.app_config c where c.id = 1);
  v_key text;
begin
  if coalesce(v_url, '') = '' then return 'no poke address'; end if;
  if to_regclass('vault.decrypted_secrets') is null then return 'no Vault'; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1' into v_key using 'n8n_poke_key';
  if coalesce(v_key, '') = '' then return 'no poke key in Vault'; end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return 'no pg_net'; end if;
  execute 'select net.http_post(url := $1, body := $2, params := $3, headers := $4, timeout_milliseconds := $5)'
    using v_url, jsonb_build_object('source', 'database clock', 'reason', p_reason), '{}'::jsonb,
          jsonb_build_object('Content-Type', 'application/json', 'x-poke-key', v_key), 10000;
  return 'sent';
end;
$$;

-- The 2 minute job: call WF4 when there is work, at most once a minute.
create or replace function private.clock_tick(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_reason text;
  v_result text;
  v_runs int;
  st public.clock_state;
begin
  if not coalesce((select c.clock_enabled from public.app_config c where c.id = 1), false) then
    return jsonb_build_object('skipped', 'clock off');
  end if;
  select * into st from public.clock_state where id = 1 for update;
  -- One alert a month when the brakes start.
  v_runs := public.n8n_runs_this_month(v_now);
  if v_runs >= 8000 and st.budget_alert_month is distinct from date_trunc('month', v_now at time zone 'UTC')::date then
    perform private.log_event('System', 'n8n budget: replies read less often', null, null, null,
      jsonb_build_object('runs_this_month', v_runs,
        'reading', case when v_runs < 9300 then 'every 20 minutes' else 'only when n8n runs for other work' end));
    update public.clock_state set budget_alert_month = date_trunc('month', v_now at time zone 'UTC')::date where id = 1;
  end if;
  v_reason := private.clock_work(v_now);
  if v_reason is null then return jsonb_build_object('work', false); end if;
  if st.last_poke_at is not null and st.last_poke_at > v_now - interval '1 minute' then
    return jsonb_build_object('work', true, 'reason', v_reason, 'skipped', 'called less than a minute ago');
  end if;
  v_result := private.poke_n8n(v_reason);
  update public.clock_state
     set last_poke_at = case when v_result = 'sent' then v_now else last_poke_at end,
         last_reason = v_reason, last_result = v_result, updated_at = now()
   where id = 1;
  return jsonb_build_object('work', true, 'reason', v_reason, 'result', v_result);
end;
$$;

-- The hourly job: the automatic check, when the clock is on (WF1's schedule is switched off then).
create or replace function private.clock_engine(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not coalesce((select c.clock_enabled from public.app_config c where c.id = 1), false) then
    return jsonb_build_object('skipped', 'clock off');
  end if;
  return public.engine_tick_all(p_now);
end;
$$;

-- Switch the clock on or off (the setup command, as the service). Logged in Activity history.
create or replace function public.configure_clock(p_enabled boolean, p_poke_url text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_service() then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_enabled and coalesce(nullif(trim(p_poke_url), ''), (select n8n_poke_url from public.app_config where id = 1)) is null then
    raise exception 'The clock needs the WF4 poke address.' using errcode = '22023';
  end if;
  update public.app_config
     set clock_enabled = p_enabled, n8n_poke_url = coalesce(nullif(trim(p_poke_url), ''), n8n_poke_url)
   where id = 1;
  perform private.log_event('System', case when p_enabled then 'Database clock switched on' else 'Database clock switched off' end,
    'app_config', null, null, jsonb_build_object('clock_enabled', p_enabled));
  return jsonb_build_object('clock_enabled', p_enabled, 'poke', private.poke_n8n('setup check'));
end;
$$;

revoke execute on function private.count_n8n_run(text), private.clock_work(timestamptz), private.poke_n8n(text),
  private.clock_tick(timestamptz), private.clock_engine(timestamptz) from public, anon, authenticated;
revoke execute on function public.configure_clock(boolean, text) from public, anon, authenticated;
grant execute on function public.configure_clock(boolean, text) to service_role;
grant execute on function public.n8n_runs_this_month(timestamptz) to authenticated, service_role;

-- The two jobs, only where pg_cron can live (the main "postgres" database: the live project and the local stacks).
do $$
begin
  if current_database() = 'postgres'
     and exists (select 1 from pg_available_extensions where name = 'pg_cron')
     and exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_cron;
    create extension if not exists pg_net;
    perform cron.schedule('sme-engine-hourly', '30 * * * *', 'select private.clock_engine()');
    perform cron.schedule('sme-clock', '*/2 * * * *', 'select private.clock_tick()');
  end if;
end;
$$;

-- public.next_actions: counted as WF4 (was 20261112000003_r2_discord_lookup.sql).
create or replace function public.next_actions(p_limit int default 20)
returns setof public.action_queue language plpgsql security definer set search_path = ''
as $$
begin
  perform private.count_n8n_run('WF4');
  perform private.require_team();
  return query
  with c as (select a.id from public.action_queue a where a.status = 'Queued' and left(a.action, 8) <> 'discord_' order by a.created_at limit p_limit for update skip locked)
  update public.action_queue a set status = 'Processing' from c where a.id = c.id returning a.*;
end;
$$;

-- public.engine_tick_all: counted as WF1 (was 20261113000002_core_archive_delete.sql).
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
  perform private.count_n8n_run('WF1');
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

-- public.daily_jobs: counted as WF3 (was 20261110000003_engine.sql).
create or replace function public.daily_jobs(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  s public.system_state;
  v_text text;
  v_sent int; v_failed int; v_open int; v_urgent int;
begin
  perform private.count_n8n_run('WF3');
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

-- public.response_page: counted as WF2 (was 20261112000007_r2_review_fixes_3.sql).
create or replace function public.response_page(p_token text)
returns public."text/html" language sql security definer set search_path = ''
as $$
  select private.count_n8n_run('WF2');
  select private.with_tokens(public.response_page_text(p_token),
           (select q.instructor_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.team_member_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.is_test from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token)
         )::public."text/html";
$$;

-- public.submit_response_page: counted as WF2 (was 20261112000007_r2_review_fixes_3.sql).
create or replace function public.submit_response_page(p_token text, p_form jsonb default '{}')
returns public."text/html" language sql security definer set search_path = ''
as $$
  select private.count_n8n_run('WF2');
  select private.with_tokens(public.submit_response_page_text(p_token, p_form),
           (select q.instructor_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.team_member_id from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token),
           (select q.is_test from public.response_link l join public.request q on q.id = l.request_id where l.token = p_token)
         )::public."text/html";
$$;
