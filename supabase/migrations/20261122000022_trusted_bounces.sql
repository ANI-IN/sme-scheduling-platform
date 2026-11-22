-- Release 3, B2 (decision 311): SEC 9, the bounce check.
--
-- record_bounce trusted any email that looked like a bounce, so anyone could mail the scheduling inbox with
-- "Undeliverable" and an instructor's address and mark that address as broken. Now a bounce counts only when it is
-- in the Gmail thread of an email the app sent to that address; WF4 passes the thread id and whether the mail is a
-- real delivery report. Everything else is logged as "Bounce ignored" and changes nothing.

drop function if exists public.record_bounce(text, text, text);

create or replace function public.record_bounce(p_email text, p_external_id text default null, p_detail text default null,
  p_thread_id text default null, p_report boolean default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  q record;
  v_urgent boolean := false;
  v_dom uuid;
  v_sent public.message;
begin
  perform private.require_service();
  perform private.set_actor('System', null, 'System');
  select ins.* into i from public.instructor_email e join public.instructor ins on ins.id = e.instructor_id
   where lower(e.email) = lower(trim(p_email));
  if i.id is null then
    return jsonb_build_object('ok', true, 'matched', false);
  end if;
  -- SEC 9: a bounce counts only when it is in the Gmail thread of an email the app really sent to that address
  -- (Gmail puts the delivery report in the thread of the message it is about; a new message's thread id is its own
  -- id, which the app keeps as external_id). Anything else is logged and ignored, so nobody can mark an
  -- instructor's address as broken by sending a fake "Undeliverable" email.
  select m.* into v_sent from public.message m
   where m.channel = 'Email' and m.direction = 'Outbound' and m.status = 'Sent'
     and lower(m.to_address) = lower(trim(p_email)) and p_thread_id is not null and m.external_id = p_thread_id
   order by m.sent_at desc limit 1;
  if v_sent.id is null then
    perform private.log_event('Messages', 'Bounce ignored: ' || i.full_name, 'instructor', i.id, null,
      jsonb_build_object('email', p_email, 'delivery_report', p_report),
      'An email that looked like a bounce for ' || p_email || ' was ignored: it is not about an email the app sent to '
        || 'that address. Nothing was changed.', null, null, null, null, i.id);
    return jsonb_build_object('ok', true, 'matched', false, 'trusted', false);
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
    v_dom, null, v_sent.module_week_id, null, i.id);
  return jsonb_build_object('ok', true, 'matched', true, 'trusted', true);
end;
$$;


grant execute on function public.record_bounce(text, text, text, text, boolean) to service_role;
