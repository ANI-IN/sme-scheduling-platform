-- Rollback of 20261123000030_daily_summary.sql: the daily summary as it was, and no usage lines.
-- public.daily_jobs is copied byte for byte from 20261122000006_security_data_findings.sql, which defined it last.

drop function if exists private.daily_summary_usage(int, bigint);

-- public.daily_jobs: SEC 7, only the automation (was 20261122000002_database_clock.sql).
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
  perform private.require_service();
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
