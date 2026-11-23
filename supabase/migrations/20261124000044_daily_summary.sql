-- Release 3: the daily system summary (T15) in plain words, with the free plan limits.
--
-- Once a day WF3 calls public.daily_jobs, which posts the summary to the admin alert channel. It now says, in plain
-- words: messages sent and failed in the last 24 hours, with the top reasons for the failures; the n8n runs this
-- month (counted as for the Usage view, public.n8n_runs_this_month) against the 10,000 a month the n8n plan allows;
-- and the database size against the 500 MB of the Supabase free plan. A warning line is added when either reaches
-- 80 percent. docs/FREE_TIER_LIMITS.md and docs/STORAGE_FORECAST.md explain the limits and what to do near them.

-- The usage lines and their warnings, on their own so the 80 percent rules can be checked with any numbers.
create or replace function private.daily_summary_usage(p_runs int, p_db_bytes bigint)
returns text language sql immutable set search_path = ''
as $$
  select 'n8n runs this month: ' || to_char(p_runs, 'FM999,999,990') || ' of 10,000 ('
      || round(p_runs * 100.0 / 10000) || '%)'
      || E'\nDatabase size: ' || to_char(round(p_db_bytes / 1048576.0, 1), 'FM999,990.0') || ' MB of 500 MB ('
      || round(p_db_bytes * 100.0 / (500 * 1048576.0)) || '%)'
      || case when p_runs >= 8000 then
           E'\nWarning: n8n runs this month have passed 80% of the 10,000 limit. Replies are read every 20 minutes'
           || ' from 8,000 runs, and only when other work runs from 9,300. Check Usage in Settings, Connections.'
         else '' end
      || case when p_db_bytes >= 0.8 * 500 * 1048576 then
           E'\nWarning: the database has passed 80% of the 500 MB free limit. Purge the old run logs and archive old'
           || ' Activity history now (see docs/STORAGE_FORECAST.md).'
         else '' end;
$$;

revoke execute on function private.daily_summary_usage(int, bigint) from public, anon, authenticated;

-- public.daily_jobs: the summary in plain words, with failure reasons and the free plan limits
-- (was 20261122000006_security_data_findings.sql).
create or replace function public.daily_jobs(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  s public.system_state;
  v_text text;
  v_sent int; v_failed int; v_open int; v_urgent int;
  v_reasons text;
  v_runs int;
  v_db_bytes bigint := pg_database_size(current_database());
begin
  perform private.count_n8n_run('WF3');
  perform private.require_service();
  perform private.set_actor('System', null, 'System');
  select * into s from public.system_state where id = 1;
  select count(*) filter (where status = 'Sent' and sent_at > v_now - interval '24 hours'),
         count(*) filter (where status = 'Failed' and updated_at > v_now - interval '24 hours')
    into v_sent, v_failed from public.message;
  -- The three most common reasons, with how many messages failed for each.
  select string_agg(r.reason || ' (' || r.n || ')', '; ' order by r.n desc, r.reason)
    into v_reasons
    from (select left(regexp_replace(private.strip_answer_links(coalesce(nullif(trim(m.last_error), ''), 'No reason recorded')),
                                     '\s+', ' ', 'g'), 120) as reason,
                 count(*) as n
            from public.message m
           where m.status = 'Failed' and m.updated_at > v_now - interval '24 hours'
           group by 1 order by 2 desc, 1 limit 3) r;
  select count(*), count(*) filter (where severity = 'Urgent') into v_open, v_urgent from public.attention_item where status <> 'Done';
  v_runs := public.n8n_runs_this_month(v_now);
  v_text := 'Daily system summary'
    || E'\nLast hourly run: ' || coalesce(private.fmt_ist(s.last_hourly_run_at), 'never')
    || ' (' || coalesce(s.last_hourly_status, 'not run yet') || ')'
    || E'\nMessages sent in the last 24 hours: ' || v_sent
    || E'\nMessages that failed in the last 24 hours: ' || v_failed
    || coalesce(E'\nTop reasons: ' || v_reasons, '')
    || E'\nOpen tasks in Needs attention: ' || v_open || ' (' || v_urgent || ' urgent)'
    || E'\n' || private.daily_summary_usage(v_runs, v_db_bytes)
    || coalesce(E'\nDomains in Testing status: ' || (select string_agg(d.name, ', ' order by d.name) from public.domain d
                                                    where private.is_test_domain(d.id)), '')
    || case when not s.outreach_enabled then E'\nAll messages to instructors are paused since '
            || coalesce(private.fmt_ist(s.kill_switch_changed_at), 'an unknown time')
            || '. No instructor messages are going out. Turn them back on in Settings, Automation when ready.' else '' end;
  perform private.queue_team_message('T15', null, 'admin', null, '{}', 'Daily system summary', v_text,
    'T15:' || to_char(v_now at time zone 'Asia/Kolkata', 'YYYY-MM-DD'), v_now);
  update public.system_state set last_daily_run_at = now(), last_heartbeat_at = now() where id = 1;
  perform private.log_event('System', 'Daily jobs', null, null, null,
    jsonb_build_object('sent_24h', v_sent, 'failed_24h', v_failed, 'open', v_open,
                       'n8n_runs_month', v_runs, 'database_bytes', v_db_bytes), null);
  return jsonb_build_object('sent_24h', v_sent, 'failed_24h', v_failed, 'open_items', v_open, 'urgent_items', v_urgent,
    'failed_reasons', v_reasons, 'n8n_runs_month', v_runs, 'n8n_limit_month', 10000,
    'database_bytes', v_db_bytes, 'database_limit_bytes', 500 * 1048576);
end;
$$;
