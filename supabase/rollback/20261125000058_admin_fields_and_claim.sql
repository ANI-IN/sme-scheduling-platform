-- Rollback of 20261125000058_admin_fields_and_claim.sql: the trigger goes, and the claim is again as in
-- 20261124000055_check_needed.sql. Deletes nothing.
drop trigger if exists team_member_admin_guard on public.team_member;
drop function if exists private.team_member_admin_guard();

create or replace function public.claim_outbound_messages(p_limit int default 25)
returns setof public.message language plpgsql security definer set search_path = ''
as $$
declare v_stuck uuid;
begin
  perform private.require_service();
  -- OUT-2: drop what should no longer go out before handing messages to n8n.
  perform private.cancel_stale_messages();
  -- DIS-13 and decision 341: never send again by itself what may already have arrived (Discord only drops a repeated
  -- nonce for a few minutes, and Gmail never does). A message the automation took 15 minutes ago without saying how
  -- it went becomes "Check needed": the team is told and chooses Send again or It arrived, mark as sent.
  for v_stuck in select id from public.message where status = 'Sending' and claimed_at < now() - interval '15 minutes' loop
    perform private.mark_check_needed(v_stuck);
  end loop;
  -- The daily email cap (decision 287): one task a day when emails are waiting for it.
  if (select private.email_cap_left()) <= 0
     and exists (select 1 from public.message m where m.status = 'Pending' and m.direction = 'Outbound' and m.channel = 'Email')
     and not exists (select 1 from public.attention_item a where a.dedupe_key = 'email-cap:' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD')) then
    insert into public.attention_item (type, severity, title, detail, dedupe_key)
    values ('Other', 'Urgent', 'Daily email limit reached',
      'The app has sent ' || (select c.daily_email_cap from public.app_config c where c.id = 1) || ' emails in the last 24 hours. '
      || 'The rest wait and go out by themselves as the limit frees up. Discord messages are not affected.',
      'email-cap:' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD'));
  end if;
  return query
  with c as (
    select m.id from public.message m left join public.domain d on d.id = m.domain_id
     where m.status = 'Pending' and m.direction = 'Outbound'
       and (m.channel <> 'Email' or (select private.email_cap_left()) > 0)
       and (m.audience <> 'Instructor'
            or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                and coalesce(d.status, 'Live') <> 'Paused' and d.archived_at is null))
     order by m.created_at
     limit greatest(1, least(p_limit, 100))
     for update of m skip locked),
  u as (
    update public.message m set status = 'Sending', claimed_at = now(), attempts = m.attempts + 1
      from c where m.id = c.id
    returning m.*)
  select (jsonb_populate_record(null::public.message, to_jsonb(u) || jsonb_build_object(
           'body_text', private.with_tokens(u.body_text, u.instructor_id, u.team_member_id, u.is_test),
           'body_html', private.with_tokens(u.body_html, u.instructor_id, u.team_member_id, u.is_test),
           'buttons', private.with_tokens(u.buttons::text, u.instructor_id, u.team_member_id, u.is_test)::jsonb))).*
    from u;
end;
$$;
