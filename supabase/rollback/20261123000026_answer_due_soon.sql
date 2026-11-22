-- Rollback of 20261123000026_answer_due_soon.sql: "Answer due soon" under 2 days again, with no setting for it.
-- The function is copied byte for byte from 20261122000018_schedule_board.sql.

delete from public.setting where key = 'answer_due_soon_h';
delete from public.setting_definition where key = 'answer_due_soon_h';

create or replace function public.schedule_board(p_domain_id uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_now timestamptz;
  v_weeks jsonb;
  v_cohorts jsonb;
  v_breaks jsonb;
begin
  perform private.require_team();
  if p_to < p_from or p_to - p_from > 190 then
    raise exception 'Show at most 27 weeks at a time.' using errcode = '22023';
  end if;
  v_now := private.domain_now(p_domain_id);

  select coalesce(jsonb_agg(x order by x ->> 'week_start_date', x ->> 'cohort', x ->> 'module'), '[]') into v_weeks from (
    select jsonb_build_object(
        'id', w.id, 'cohort_id', w.cohort_id, 'cohort', c.name, 'module_id', w.module_id, 'module', m.name,
        'week_start_date', w.week_start_date, 'first_class_at', w.first_class_at, 'past', coalesce(w.last_class_end_at <= v_now, false),
        'standard_position', w.standard_position, 'customized', w.customized_at is not null, 'shared_with', w.shared_with,
        'guests', (select count(*) from public.module_week g where g.shared_with = w.id),
        'classes', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'title', k.title, 'starts_at', k.starts_at,
                      'ends_at', k.ends_at, 'region', k.region, 'status', k.status, 'moved_from', k.previous_starts_at)
                      order by k.starts_at), '[]') from public.class_session k where k.module_week_id = w.id)
      ) || s.st
        || jsonb_build_object('badges', (
          select coalesce(jsonb_agg(distinct b), '[]') from (
            select e ->> 'code' as b from jsonb_array_elements(pb.problems) e
            union all select 'answer_due_soon' where (s.st ->> 'deadline_at')::timestamptz - v_now < interval '2 days'
            union all select 'message_failed' where exists (select 1 from public.message mm where mm.module_week_id = w.id and mm.status = 'Failed')
            union all select 'help_open' where exists (select 1 from public.help_request h where h.module_week_id = w.id
                                                        and h.status in ('Open', 'InProgress', 'WaitingOnInstructor'))
            union all select 'tasks_overdue' where exists (select 1 from public.attention_item a where a.module_week_id = w.id
                                                            and a.type = 'ChecklistOverdue' and a.status <> 'Done')
            union all select 'moved' where exists (select 1 from public.class_session k where k.module_week_id = w.id
                                                    and k.status = 'Planned' and k.previous_starts_at is not null)
            union all select 'extra_class' where c.standard_schedule_id is not null and w.standard_position is null
            union all select 'declined' where exists (select 1 from public.request q where q.module_week_id = w.id
                                                       and q.kind = 'Outreach' and q.status in ('Declined', 'Expired'))
          ) t),
          'problems', pb.problems) as x
      from public.module_week w
      join public.module m on m.id = w.module_id
      left join public.cohort c on c.id = w.cohort_id
      -- offset 0: each is worked out once per class week, not once per use.
      cross join lateral (select private.board_status(w.id, v_now) as st offset 0) s
      cross join lateral (select case when coalesce(w.last_class_end_at <= v_now, false) then '[]'::jsonb
                                      else private.week_problems(w.id) end as problems offset 0) pb
     where w.domain_id = p_domain_id and w.week_start_date between p_from and p_to) q;

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'region', c.region,
           'standard', s.name, 'mode', case when c.standard_schedule_id is null then 'Fully custom'
                                            when n.n = 0 then 'Standard' else 'Custom' end, 'changes', n.n,
           'merged_into', c.merged_into, 'merged_from', c.merged_from,
           'merged_into_name', (select x.name from public.cohort x where x.id = c.merged_into),
           'archived', c.archived_at is not null) order by c.name), '[]')
    into v_cohorts
    from public.cohort c left join public.standard_schedule s on s.id = c.standard_schedule_id
    cross join lateral (select count(*)::int as n from public.module_week w
                         where c.standard_schedule_id is not null and w.cohort_id = c.id
                           and (w.customized_at is not null or (w.standard_position is null and w.status <> 'Cancelled'))) n
   where c.domain_id = p_domain_id and (c.archived_at is null or exists (
           select 1 from public.module_week w where w.cohort_id = c.id and w.week_start_date between p_from and p_to));

  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'cohort_id', b.cohort_id, 'program_break_id', b.program_break_id,
           'starts_on', b.starts_on, 'weeks', b.weeks, 'reason', b.reason) order by b.starts_on), '[]')
    into v_breaks
    from public.cohort_break b
   where b.domain_id = p_domain_id and b.status = 'Active'
     and daterange(b.starts_on, b.starts_on + 7 * b.weeks) && daterange(p_from, p_to + 1);

  return jsonb_build_object('from', p_from, 'to', p_to, 'now', v_now, 'weeks', v_weeks, 'cohorts', v_cohorts, 'breaks', v_breaks,
    -- Needs a decision: every Block and Warning, and the class weeks needing an instructor or a decision on a proposal.
    'decisions', coalesce((select jsonb_object_agg(k, n) from (
        select e ->> 'code' as k, count(distinct x ->> 'id')::int as n
          from jsonb_array_elements(v_weeks) x, jsonb_array_elements(x -> 'problems') e
         where e ->> 'level' in ('Block', 'Warning') group by 1
        union all
        select replace(lower(x ->> 'status'), ' ', '_'), count(*)::int from jsonb_array_elements(v_weeks) x
         where x ->> 'status' in ('Needs instructor', 'Proposed time') and not (x ->> 'past')::boolean group by 1) d), '{}'));
end;
$$;
