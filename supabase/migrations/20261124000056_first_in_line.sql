-- Leftover work of 24 November 2026 (decision 342): faster lists at scale. The Schedule board's planned instructors
-- and Instructor requests' "who we ask next" built each class week's whole asking line (every instructor of the
-- order, four checks each) to use only its first person who can be asked. private.first_in_line walks the same line
-- in the same order with the same checks and stops at that person. Instructor requests now reads only the first
-- person for its list (public.next_in_line_many) and the whole line when a row is opened (public.preview_next).
-- pgTAP 750 checks first_in_line against build_line on every kind of line.

create or replace function private.first_in_line(p_mw uuid)
returns table (pos int, instructor_id uuid, full_name text, source text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  w public.module_week;
  r record;
  n int := 0;
  v_hist text;
begin
  select * into w from public.module_week where id = p_mw;
  if w.id is null then return; end if;
  -- The same order and the same checks as private.build_line; the first person with no reason is the answer.
  if w.outreach_mode = 'Manual' then
    for r in select q.instructor_id as iid, i.full_name as nm
               from public.manual_queue_item q join public.instructor i on i.id = q.instructor_id
              where q.module_week_id = p_mw and q.asked_request_id is null order by q.position loop
      n := n + 1;
      v_hist := private.week_history_reason(r.iid, p_mw);
      if coalesce(private.eligibility(r.iid, p_mw), case when v_hist = 'Being asked now' then v_hist end,
                  private.sooner_class_reason(r.iid, p_mw)) is null then
        pos := n; instructor_id := r.iid; full_name := r.nm; source := 'Manual';
        return next;
        return;
      end if;
    end loop;
    if w.manual_end_behaviour <> 'ContinueWithRanking' then
      return;
    end if;
  end if;
  for r in select k.instructor_id as iid, i.full_name as nm
             from public.module_ranking k join public.instructor i on i.id = k.instructor_id
            where k.module_id = w.module_id and k.cohort_id is not distinct from private.order_cohort(w.module_id, w.cohort_id)
              and (w.outreach_mode <> 'Manual'
                   or k.instructor_id not in (select q.instructor_id from public.manual_queue_item q where q.module_week_id = p_mw))
            order by k.rank loop
    n := n + 1;
    if coalesce(private.eligibility(r.iid, p_mw), private.week_history_reason(r.iid, p_mw),
                private.sooner_class_reason(r.iid, p_mw)) is null then
      pos := n; instructor_id := r.iid; full_name := r.nm; source := 'Ranking';
      return next;
      return;
    end if;
  end loop;
end;
$$;
revoke all on function private.first_in_line(uuid) from public, anon, authenticated;

-- private.planned_instructor: the first person of the line from first_in_line (was 20261124000046_planned_instructor.sql).
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
    select l.instructor_id, l.full_name, l.source into v_iid, v_name, v_source from private.first_in_line(s.id) l;
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

-- Instructor requests' list: who is being asked and who is next, for many class weeks at once, without the whole
-- line (public.preview_next gives the whole line for one class week, when its row is opened).
create or replace function public.next_in_line_many(p_module_week_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if cardinality(coalesce(p_module_week_ids, '{}')) > 500 then
    raise exception 'At most 500 class weeks at once.' using errcode = '22023';
  end if;
  return coalesce((
    select jsonb_object_agg(x, jsonb_build_object(
      'asking', (select jsonb_build_object('request_id', q.id, 'instructor_id', q.instructor_id, 'name', i.full_name,
                                           'sent_at', q.sent_at, 'reminded', q.status = 'Reminded', 'deadline_at', q.deadline_at)
                   from public.request q join public.instructor i on i.id = q.instructor_id
                  where q.module_week_id = x and q.kind = 'Outreach' and q.status in ('Queued', 'Sent', 'Reminded') limit 1),
      'next', (select l.full_name from private.first_in_line(x) l)))
      from unnest(p_module_week_ids) x), '{}'::jsonb);
end;
$$;
revoke all on function public.next_in_line_many(uuid[]) from public, anon;
grant execute on function public.next_in_line_many(uuid[]) to authenticated;
