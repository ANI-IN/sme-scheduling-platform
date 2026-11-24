-- Rollback of 20261124000056_first_in_line.sql.
drop function if exists public.next_in_line_many(uuid[]);

create or replace function private.planned_instructor(p_mw uuid, p_now timestamptz)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  w public.module_week;
  s public.module_week;
  v_confirmed text;
  v_asking text;
  v_iid uuid;
  v_name text;
  v_source text;
  v_rank int;
begin
  select * into w from public.module_week where id = p_mw;
  if w.id is null then
    return null;
  end if;
  -- A shared class week takes its instructor and its requests from its host.
  select * into s from public.module_week where id = coalesce(w.shared_with, w.id);
  select i.full_name into v_confirmed from public.booking b join public.instructor i on i.id = b.instructor_id
   where b.module_week_id = s.id and b.status in ('Active', 'Completed') order by b.status limit 1;
  select i.full_name into v_asking from public.request q join public.instructor i on i.id = q.instructor_id
   where q.module_week_id = s.id and q.kind = 'Outreach' and q.status in ('Queued', 'Sent', 'Reminded') limit 1;
  if v_confirmed is null and s.status not in ('Cancelled', 'Completed') then
    -- Who is asked next: the first person of the line who can be asked now.
    select l.instructor_id, l.full_name, l.source into v_iid, v_name, v_source
      from private.build_line(s.id) l where l.reason is null order by l.pos limit 1;
    if v_source = 'Ranking' then
      select x.n into v_rank from (
        select k.instructor_id, row_number() over (order by k.rank)::int as n from public.module_ranking k
         where k.module_id = s.module_id and k.cohort_id is not distinct from private.order_cohort(s.module_id, s.cohort_id)) x
       where x.instructor_id = v_iid;
    end if;
  end if;
  return jsonb_build_object(
    'module_week_id', w.id,
    'confirmed', v_confirmed,
    'asking', v_asking,
    -- rank 1 is the Primary instructor, rank 2 is Backup 1 and so on; a chosen list has no rank.
    'planned', case when v_iid is not null then
      jsonb_build_object('instructor_id', v_iid, 'name', v_name, 'source', v_source, 'rank', v_rank) end,
    'asking_starts_at', case when s.first_class_at is not null then
      s.first_class_at - make_interval(days => private.setting_int(s.id, 'outreach_days')) end,
    'first_class_at', s.first_class_at,
    'paused', s.paused,
    'at_risk', s.at_risk,
    'setup_incomplete', s.status = 'NotReady',
    'finished', s.status in ('Cancelled', 'Completed') or coalesce(s.first_class_at <= p_now, false));
end;
$$;

drop function if exists private.first_in_line(uuid);
