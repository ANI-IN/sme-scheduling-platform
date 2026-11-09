-- =====================================================================================
-- PRD 7.3 item-specific action "Reply": answer an instructor's typed reply (or any attention
-- item about an instructor) from the app. Sent on their Discord channel and email (M14).
-- =====================================================================================
create or replace function public.reply_to_instructor(p_item_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  a public.attention_item;
  v_from text := coalesce((select t.name from public.team_member t where t.id = private.current_team_member_id()), 'SME Scheduling');
  v_n int;
begin
  perform private.require_team();
  if coalesce(trim(p_text), '') = '' then raise exception 'Write a reply first.'; end if;
  select * into a from public.attention_item where id = p_item_id;
  if a.instructor_id is null then raise exception 'This item is not about an instructor.'; end if;
  v_n := private.queue_instructor_message('M14', a.instructor_id, a.module_week_id, null,
    coalesce(private.domain_now(a.domain_id), now()), '[]',
    jsonb_build_object('text', p_text, 'from', v_from), false,
    'reply:' || a.id || ':' || extract(epoch from clock_timestamp())::bigint);
  update public.attention_item set status = 'Acknowledged', acknowledged_by = private.current_team_member_id(),
         ack_until = coalesce(private.domain_now(a.domain_id), now()) + interval '24 hours',
         assigned_to = coalesce(assigned_to, private.current_team_member_id())
   where id = a.id and status <> 'Done';
  perform private.log_event('Team actions', 'Replied to ' || (select i.full_name from public.instructor i where i.id = a.instructor_id),
    'attention_item', a.id, null, jsonb_build_object('text', p_text), null, a.domain_id, a.module_id, a.module_week_id,
    null, a.instructor_id);
  perform private.queue_deliver('reply');
  return jsonb_build_object('ok', true, 'messages', v_n);
end;
$$;
grant execute on function public.reply_to_instructor(uuid, text) to authenticated, service_role;
