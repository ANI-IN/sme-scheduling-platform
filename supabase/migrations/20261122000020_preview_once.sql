-- Release 3, M6 follow up (decision 309): the Instructor requests page faster at scale.
--
-- preview_next worked out the instructor order twice for each class week: once for who would be asked next and once
-- for the whole order. It now works it out once and takes the next name from it. The answer is the same.

create or replace function public.preview_next(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  v_line jsonb;
begin
  perform private.require_team();
  select q.*, i.full_name into r from public.request q join public.instructor i on i.id = q.instructor_id
   where q.module_week_id = p_module_week_id and q.kind = 'Outreach' and q.status in ('Queued', 'Sent', 'Reminded');
  select coalesce(jsonb_agg(jsonb_build_object('instructor_id', l.instructor_id, 'name', l.full_name, 'source', l.source,
           'reason', l.reason, 'warning', l.warning) order by l.pos), '[]')
    into v_line from private.build_line(p_module_week_id) l;
  return jsonb_build_object(
    'asking', case when r.id is not null then jsonb_build_object('request_id', r.id, 'instructor_id', r.instructor_id,
      'name', r.full_name, 'sent_at', r.sent_at, 'reminded', r.status = 'Reminded', 'deadline_at', r.deadline_at) end,
    'next', (select x ->> 'name' from jsonb_array_elements(v_line) with ordinality as e(x, n)
              where x -> 'reason' = 'null'::jsonb order by e.n limit 1),
    'line', v_line);
end;
$$;
