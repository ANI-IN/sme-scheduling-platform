-- Rollback of 20261122000020_preview_once.sql (decision 309). Puts back preview_next as it was in
-- 20261110000005_actions.sql.

create or replace function public.preview_next(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  perform private.require_team();
  select q.*, i.full_name into r from public.request q join public.instructor i on i.id = q.instructor_id
   where q.module_week_id = p_module_week_id and q.kind = 'Outreach' and q.status in ('Queued', 'Sent', 'Reminded');
  return jsonb_build_object(
    'asking', case when r.id is not null then jsonb_build_object('request_id', r.id, 'instructor_id', r.instructor_id,
      'name', r.full_name, 'sent_at', r.sent_at, 'reminded', r.status = 'Reminded', 'deadline_at', r.deadline_at) end,
    'next', private.next_name(p_module_week_id),
    'line', (select coalesce(jsonb_agg(jsonb_build_object('instructor_id', l.instructor_id, 'name', l.full_name, 'source', l.source,
               'reason', l.reason, 'warning', l.warning) order by l.pos), '[]') from private.build_line(p_module_week_id) l));
end;
$$;
