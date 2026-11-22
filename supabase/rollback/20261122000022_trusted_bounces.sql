-- Rollback of 20261122000022_trusted_bounces.sql (decision 311). Puts back record_bounce as it was in
-- 20261122000006_security_data_findings.sql.

drop function if exists public.record_bounce(text, text, text, text, boolean);

create or replace function public.record_bounce(p_email text, p_external_id text default null, p_detail text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  q record;
  v_urgent boolean := false;
  v_dom uuid;
begin
  perform private.require_service();
  perform private.set_actor('System', null, 'System');
  select ins.* into i from public.instructor_email e join public.instructor ins on ins.id = e.instructor_id
   where lower(e.email) = lower(trim(p_email));
  if i.id is null then
    return jsonb_build_object('ok', true, 'matched', false);
  end if;
  update public.instructor set email_bounced_at = now() where id = i.id;
  select r.*, w.domain_id as dom into q from public.request r join public.module_week w on w.id = r.module_week_id
   where r.instructor_id = i.id and r.status in ('Sent', 'Reminded') order by r.created_at desc limit 1;
  v_dom := q.dom;
  if q.id is not null then
    v_urgent := private.days_until(q.module_week_id, private.domain_now(v_dom)) < private.setting_int(q.module_week_id, 'short_notice_days');
  end if;
  perform private.raise_attention(v_dom, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
    'Email bounced: ' || i.full_name || ' (' || p_email || ')',
    coalesce(p_detail, 'The email address may be wrong.') || ' Discord is still used. Fix the email in Instructors.',
    'bounce:' || i.id, coalesce(nullif(private.domain_role_ids(v_dom, 'Ops'), '{}'),
      private.all_operations_ids()),
    coalesce(private.domain_now(v_dom), now()), jsonb_build_object('instructor_id', i.id), true, 'T14');
  perform private.log_event('Messages', 'Email bounced: ' || i.full_name, 'instructor', i.id, null, null, p_detail,
    v_dom, null, null, null, i.id);
  return jsonb_build_object('ok', true, 'matched', true);
end;
$$;
grant execute on function public.record_bounce(text, text, text) to service_role;
