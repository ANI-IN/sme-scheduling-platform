-- Release 3, M11 (decision 304): cohorts merge into one combined cohort from a date.
--
-- From the merge date (the start of a class week of the cohort whose module sequence the combined cohort follows),
-- two or more cohorts of a domain continue as one new combined cohort. The original cohorts stay as they were up to
-- that date, readable, with "Merged into X from <date>". Ops chooses the combined cohort's name, its time zone (each
-- class keeps its own clock time, as for any region change), whose module sequence it follows and whose instructor
-- order it uses.
--
-- Every class week of the cohorts from the merge date on moves into the combined cohort, except duplicates: when the
-- other cohort has a class week of a module that is also in the chosen sequence, one of the two is kept and the other
-- cancelled. The week with a confirmed instructor is kept; when both have different confirmed instructors (a Warning
-- with a reason), the chosen sequence's week is kept unless Ops chooses the other, and the instructor of the cancelled
-- week gets the release note; when the same instructor is confirmed for both, the extra week ends without a message.
-- A "Merge check" Warning lists the other cohort's class weeks whose module is not in the chosen sequence (they stay in
-- the combined cohort unless Ops cancels them) and the modules that sit at another place in the sequence.
--
-- Block: fewer than two cohorts, another domain, an archived or already merged cohort, a merge date in the past, not
-- at the start of a class week, or before every cohort has started; a class week from the merge date on that has
-- started; a class week shared between the cohorts, or one to cancel that other cohorts share; a name in use.
-- Undo is possible until the merge date: class weeks go back to their cohorts and cancelled ones are planned again
-- (an instructor released by the merge is not brought back; their class week asks its instructor order as usual).

alter table public.cohort add column merged_into uuid references public.cohort (id) on delete set null,
  add column merged_from date;
create index cohort_merged_into_idx on public.cohort (merged_into);

create table public.cohort_merge (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete cascade,
  target_cohort_id uuid not null references public.cohort (id) on delete cascade,
  source_cohort_ids uuid[] not null,
  effective_date date not null,
  sequence_from uuid not null,
  order_from uuid not null,
  region text not null check (region in ('US', 'India')),
  status text not null default 'Done' check (status in ('Done', 'Undone')),
  -- What the merge did, so it can be undone: {moved: [{id, cohort_id, cohort}], cancelled: [id], released: [booking id]}.
  plan jsonb not null default '{}',
  undone_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create index cohort_merge_domain_idx on public.cohort_merge (domain_id);
create index cohort_merge_target_idx on public.cohort_merge (target_cohort_id);
create trigger cohort_merge_touch before update on public.cohort_merge for each row execute function private.touch_row();
alter table public.cohort_merge enable row level security;
revoke all on public.cohort_merge from anon;
grant all on public.cohort_merge to service_role;
grant select on public.cohort_merge to authenticated;
create policy cohort_merge_team_read on public.cohort_merge for select to authenticated using (private.is_team_user());

-- What a merge would do, and every check, without saving. p_keep: class weeks of the other cohorts to keep instead of
-- their duplicate in the chosen sequence; p_cancel: class weeks without a match to cancel instead of keeping.
create or replace function private.merge_plan(p_cohort_ids uuid[], p_date date, p_sequence_from uuid, p_order_from uuid,
  p_name text, p_region text, p_keep uuid[], p_cancel uuid[])
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_domain uuid;
  c record;
  w record;
  d record;
  v_now timestamptz;
  v_blocks text[] := '{}';
  v_warn jsonb := '[]';
  v_info text[] := '{}';
  v_weeks jsonb := '[]';
  v_seq_mods uuid[];
  v_pos int;
  v_spos int;
  v_keep_other boolean;
  v_a record;
  v_b record;
begin
  select domain_id into v_domain from public.cohort where id = p_sequence_from;
  if cardinality(array(select distinct x from unnest(coalesce(p_cohort_ids, '{}')) x)) < 2 then
    raise exception 'Choose at least two cohorts to merge.' using errcode = '22023';
  end if;
  if not p_sequence_from = any (p_cohort_ids) or not p_order_from = any (p_cohort_ids) then
    raise exception 'Choose the module sequence and the instructor order of one of these cohorts.' using errcode = '22023';
  end if;
  if p_region not in ('US', 'India') then raise exception 'Choose US or India.' using errcode = '22023'; end if;
  v_now := private.domain_now(v_domain);
  if nullif(trim(coalesce(p_name, '')), '') is null then
    v_blocks := v_blocks || 'Give the combined cohort a name.'::text;
  elsif exists (select 1 from public.cohort x where x.domain_id = v_domain and lower(x.name) = lower(trim(p_name))) then
    v_blocks := v_blocks || ('A cohort named ' || trim(p_name) || ' already exists in this domain.');
  end if;
  if p_date is null or p_date < (v_now at time zone 'America/Los_Angeles')::date then
    v_blocks := v_blocks || 'The merge date can''t be in the past.'::text;
  end if;
  if not exists (select 1 from public.module_week x where x.cohort_id = p_sequence_from and x.week_start_date = p_date
                   and x.status not in ('Cancelled', 'Completed')) then
    v_blocks := v_blocks || ('A merge starts at the start of a class week: ' || (select name from public.cohort where id = p_sequence_from)
                             || ' has no class week starting ' || coalesce(to_char(p_date, 'Dy, Mon FMDD'), 'then') || '.');
  end if;
  for c in select x.* from public.cohort x where x.id = any (p_cohort_ids) order by x.name loop
    if c.domain_id <> v_domain then v_blocks := v_blocks || (c.name || ' is in another domain.'); end if;
    if c.archived_at is not null then v_blocks := v_blocks || (c.name || ' is archived.'); end if;
    if c.merged_into is not null then v_blocks := v_blocks || (c.name || ' is already merged.'); end if;
    if p_date <= coalesce((select min(x.week_start_date) from public.module_week x where x.cohort_id = c.id and x.status <> 'Cancelled'), p_date) then
      v_blocks := v_blocks || (c.name || ' has not started before the merge date. Merge from a later class week.');
    end if;
    for w in select x.id from public.module_week x
              where x.cohort_id = c.id and x.week_start_date >= p_date and x.status not in ('Cancelled', 'Completed')
                and x.first_class_at <= v_now loop
      v_blocks := v_blocks || (private.mw_label(w.id) || ' has started. Merge from the next class week.');
    end loop;
  end loop;
  if exists (select 1 from public.module_week g join public.module_week h on h.id = g.shared_with
              where g.cohort_id = any (p_cohort_ids) and h.cohort_id = any (p_cohort_ids) and g.week_start_date >= p_date) then
    v_blocks := v_blocks || 'Some class weeks of these cohorts share a class with each other. Stop sharing them first.'::text;
  end if;

  -- The chosen module sequence from the merge date.
  v_seq_mods := array(select x.module_id from public.module_week x where x.cohort_id = p_sequence_from and x.week_start_date >= p_date
                        and x.status not in ('Cancelled', 'Completed') order by x.week_start_date, x.id);
  for w in select x.*, co.name as cohort_name from public.module_week x join public.cohort co on co.id = x.cohort_id
            where x.cohort_id = any (p_cohort_ids) and x.week_start_date >= p_date and x.status not in ('Cancelled', 'Completed')
            order by x.week_start_date, co.name loop
    if w.cohort_id = p_sequence_from then
      -- Kept, unless the other cohort's duplicate is kept instead.
      if exists (select 1 from public.module_week o where o.id = any (coalesce(p_keep, '{}')) and o.module_id = w.module_id
                   and o.cohort_id = any (p_cohort_ids) and o.cohort_id <> p_sequence_from and o.week_start_date >= p_date) then
        v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id, 'cohort', w.cohort_name, 'label', private.mw_label(w.id),
          'action', 'cancel', 'reason', 'The other cohort''s class week of this module is kept instead.');
      else
        v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id, 'cohort', w.cohort_name, 'label', private.mw_label(w.id),
          'action', 'move', 'reason', null);
      end if;
      continue;
    end if;
    select x.id, x.week_start_date into d from public.module_week x
     where x.cohort_id = p_sequence_from and x.module_id = w.module_id and x.week_start_date >= p_date
       and x.status not in ('Cancelled', 'Completed') order by x.week_start_date limit 1;
    if d.id is null then
      -- A module the chosen sequence does not have from the merge date.
      v_warn := v_warn || jsonb_build_object('code', 'merge_check', 'level', 'Warning', 'module_week_id', w.id,
        'text', 'Merge check: ' || private.mw_label(w.id) || ' (' || w.cohort_name || ') has no match in the chosen module sequence.'
                || case when w.id = any (coalesce(p_cancel, '{}')) then ' It is cancelled.' else ' It stays in the combined cohort.' end);
      v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id, 'cohort', w.cohort_name, 'label', private.mw_label(w.id),
        'action', case when w.id = any (coalesce(p_cancel, '{}')) then 'cancel' else 'move' end,
        'reason', 'No match in the chosen module sequence.');
      continue;
    end if;
    v_pos := array_position(v_seq_mods, w.module_id);
    v_spos := (select count(*) from public.module_week x where x.cohort_id = w.cohort_id and x.week_start_date >= p_date
                 and x.week_start_date < w.week_start_date and x.status not in ('Cancelled', 'Completed')) + 1;
    if v_pos is distinct from v_spos then
      v_warn := v_warn || jsonb_build_object('code', 'merge_check', 'level', 'Warning', 'module_week_id', w.id,
        'text', 'Merge check: ' || (select name from public.module where id = w.module_id) || ' is module ' || v_spos || ' of ' || w.cohort_name
                || ' from the merge date but module ' || v_pos || ' of the chosen sequence.');
    end if;
    -- A duplicate: keep the week with a confirmed instructor; Ops decides when both have one.
    select b.instructor_id as id, i.full_name as name into v_a from public.booking b join public.instructor i on i.id = b.instructor_id
     where b.module_week_id = d.id and b.status = 'Active';
    select b.instructor_id as id, i.full_name as name into v_b from public.booking b join public.instructor i on i.id = b.instructor_id
     where b.module_week_id = w.id and b.status = 'Active';
    v_keep_other := w.id = any (coalesce(p_keep, '{}')) or (v_a.id is null and v_b.id is not null);
    if v_a.id is not null and v_b.id is not null and v_a.id <> v_b.id then
      v_warn := v_warn || jsonb_build_object('code', 'merge_conflict', 'level', 'Warning', 'module_week_id', w.id,
        'text', v_a.name || ' and ' || v_b.name || ' are both confirmed for ' || (select name from public.module where id = w.module_id)
                || '. ' || case when v_keep_other then v_b.name || ' stays and ' || v_a.name else v_a.name || ' stays and ' || v_b.name end
                || ' gets the release note.',
        'fixes', '["keep_other_instructor"]'::jsonb);
    end if;
    if v_keep_other then
      v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id, 'cohort', w.cohort_name, 'label', private.mw_label(w.id),
        'action', 'move', 'reason', 'Kept instead of the chosen sequence''s class week of this module.', 'duplicate_of', d.id);
    else
      v_weeks := v_weeks || jsonb_build_object('module_week_id', w.id, 'cohort', w.cohort_name, 'label', private.mw_label(w.id),
        'action', 'cancel', 'reason', 'The chosen sequence has this module.', 'duplicate_of', d.id);
    end if;
  end loop;
  -- A week that would be cancelled but other cohorts share.
  for w in select (x ->> 'module_week_id')::uuid as id from jsonb_array_elements(v_weeks) x where x ->> 'action' = 'cancel' loop
    if exists (select 1 from public.module_week g where g.shared_with = w.id) then
      v_blocks := v_blocks || (private.mw_label(w.id) || ' would be cancelled, but other cohorts share its class. Stop sharing it first.');
    end if;
    select b.instructor_id as id, i.full_name as name into v_b from public.booking b join public.instructor i on i.id = b.instructor_id
     where b.module_week_id = w.id and b.status = 'Active';
    if v_b.id is not null then
      v_info := v_info || (v_b.name || ' is no longer needed for ' || private.mw_label(w.id) || case when exists (
        select 1 from jsonb_array_elements(v_weeks) y join public.booking bb on bb.module_week_id = (y ->> 'module_week_id')::uuid
         where y ->> 'action' = 'move' and bb.status = 'Active' and bb.instructor_id = v_b.id
           and (select module_id from public.module_week where id = (y ->> 'module_week_id')::uuid) = (select module_id from public.module_week where id = w.id))
        then ', and teaches the combined class week instead.' else ' and gets the release note.' end);
    end if;
  end loop;
  if exists (select 1 from public.cohort x where x.id = any (p_cohort_ids) and coalesce(x.region, 'US') <> p_region) then
    v_info := v_info || 'Classes keep their own clock time; the combined cohort plans new classes in its own time zone.'::text;
  end if;
  v_info := v_info || 'Breaks, cohort holidays, cohort settings and operations teams of the cohorts stay with them. Set them for the combined cohort if it needs them.'::text;
  return jsonb_build_object('name', trim(coalesce(p_name, '')), 'region', p_region, 'date', p_date, 'weeks', v_weeks,
    'blocks', to_jsonb(v_blocks), 'warnings', v_warn, 'effects', to_jsonb(v_info));
end;
$$;

create or replace function public.merge_cohorts(p_cohort_ids uuid[], p_date date, p_sequence_from uuid, p_order_from uuid,
  p_name text, p_region text, p_keep uuid[] default '{}', p_cancel uuid[] default '{}', p_save boolean default false,
  p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_plan jsonb;
  v_domain uuid;
  v_target uuid;
  v_now timestamptz;
  x jsonb;
  w public.module_week;
  bk public.booking;
  v_moved jsonb := '[]';
  v_cancelled uuid[] := '{}';
  v_released uuid[] := '{}';
  v_same boolean;
  v_merge uuid;
  v_name text;
begin
  perform private.require_team();
  select domain_id into v_domain from public.cohort where id = p_sequence_from;
  if v_domain is null then raise exception 'Choose the cohorts to merge.' using errcode = '22023'; end if;
  if p_save then perform pg_advisory_xact_lock(hashtext('plan:' || v_domain::text)); end if;
  v_plan := private.merge_plan(p_cohort_ids, p_date, p_sequence_from, p_order_from, p_name, p_region, p_keep, p_cancel);
  if not p_save then return v_plan || jsonb_build_object('ok', true, 'preview', true); end if;
  if jsonb_array_length(v_plan -> 'blocks') > 0 then return v_plan || jsonb_build_object('ok', false); end if;
  if exists (select 1 from jsonb_array_elements(v_plan -> 'warnings') e where e ->> 'level' = 'Warning') and not p_accept_warnings then
    return v_plan || jsonb_build_object('ok', false, 'needs_confirmation', true);
  end if;
  perform private.log_accepted_warnings(v_plan -> 'warnings', p_reason, v_domain);
  v_now := private.domain_now(v_domain);

  insert into public.cohort (domain_id, name, region, start_date, status)
  values (v_domain, trim(p_name), p_region, p_date, 'Running') returning id into v_target;
  -- The instructor order and the class times of the chosen cohorts, for the combined cohort.
  insert into public.module_ranking (module_id, instructor_id, rank, cohort_id)
  select module_id, instructor_id, rank, v_target from public.module_ranking where cohort_id = p_order_from;
  insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order, cohort_id)
  select module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order, v_target
    from public.class_pattern_item where cohort_id = p_sequence_from;

  -- Cancelled first, so the kept week of a module can take its place.
  for x in select * from jsonb_array_elements(v_plan -> 'weeks') where value ->> 'action' = 'cancel' loop
    select * into w from public.module_week where id = (x ->> 'module_week_id')::uuid;
    for bk in select * from public.booking where module_week_id = w.id and status = 'Active' loop
      select full_name into v_name from public.instructor where id = bk.instructor_id;
      v_same := exists (select 1 from jsonb_array_elements(v_plan -> 'weeks') y join public.module_week k on k.id = (y ->> 'module_week_id')::uuid
                          join public.booking bb on bb.module_week_id = k.id and bb.status = 'Active'
                         where y ->> 'action' = 'move' and k.module_id = w.module_id and bb.instructor_id = bk.instructor_id);
      update public.booking set status = 'Released', released_at = v_now, release_reason = 'OpsReleased' where id = bk.id;
      update public.request set status = 'Superseded', close_reason = 'Booking released'
       where booking_id = bk.id and status in ('Queued', 'Sent', 'Reminded');
      if not v_same then
        perform private.queue_instructor_message('M16', bk.instructor_id, w.id, null, v_now, '[]', '{}', false, 'release:' || bk.id);
      end if;
      perform private.log_event('Bookings', 'Booking released: ' || v_name, 'booking', bk.id, jsonb_build_object('status', 'Active'),
        jsonb_build_object('status', 'Released', 'reason', 'Cohorts merged'), null, w.domain_id, w.module_id, w.id, null, bk.instructor_id);
      v_released := v_released || bk.id;
    end loop;
    perform public.cancel_module_week(w.id, 'Cohorts merged into ' || trim(p_name));
    v_cancelled := v_cancelled || w.id;
  end loop;
  for x in select * from jsonb_array_elements(v_plan -> 'weeks') where value ->> 'action' = 'move' loop
    select * into w from public.module_week where id = (x ->> 'module_week_id')::uuid;
    v_moved := v_moved || jsonb_build_object('id', w.id, 'cohort_id', w.cohort_id, 'cohort', w.cohort);
    update public.module_week set cohort_id = v_target, cohort = trim(p_name) where id = w.id;
  end loop;
  update public.cohort set merged_into = v_target, merged_from = p_date where id = any (p_cohort_ids);
  insert into public.cohort_merge (domain_id, target_cohort_id, source_cohort_ids, effective_date, sequence_from, order_from, region, plan)
  values (v_domain, v_target, p_cohort_ids, p_date, p_sequence_from, p_order_from, p_region,
          jsonb_build_object('moved', v_moved, 'cancelled', to_jsonb(v_cancelled), 'released', to_jsonb(v_released)))
  returning id into v_merge;
  perform private.log_event('Team actions', 'Cohorts merged into ' || trim(p_name), 'cohort', v_target, null,
    jsonb_build_object('cohorts', (select jsonb_agg(name order by name) from public.cohort where id = any (p_cohort_ids)),
      'from', p_date, 'moved', jsonb_array_length(v_moved), 'cancelled', cardinality(v_cancelled)), null, v_domain);
  perform private.queue_deliver('merge');
  return v_plan || jsonb_build_object('ok', true, 'merge_id', v_merge, 'cohort_id', v_target,
    'moved', jsonb_array_length(v_moved), 'cancelled', cardinality(v_cancelled));
end;
$$;

-- Undo a merge until its date: class weeks go back to their cohorts and cancelled ones are planned again.
create or replace function public.undo_cohort_merge(p_merge_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  m public.cohort_merge;
  x jsonb;
  v_now timestamptz;
  v_restored int := 0;
begin
  perform private.require_team();
  select * into m from public.cohort_merge where id = p_merge_id for update;
  if m.id is null or m.status <> 'Done' then raise exception 'This merge was already undone.' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('plan:' || m.domain_id::text));
  v_now := private.domain_now(m.domain_id);
  if (v_now at time zone 'America/Los_Angeles')::date >= m.effective_date then
    raise exception 'The merge date has come, so the merge can''t be undone. Change the class weeks one by one instead.' using errcode = '22023';
  end if;
  for x in select * from jsonb_array_elements(m.plan -> 'moved') loop
    update public.module_week set cohort_id = (x ->> 'cohort_id')::uuid, cohort = x ->> 'cohort'
     where id = (x ->> 'id')::uuid and cohort_id = m.target_cohort_id;
  end loop;
  for x in select * from jsonb_array_elements(m.plan -> 'cancelled') loop
    if exists (select 1 from public.module_week where id = (x #>> '{}')::uuid and status = 'Cancelled') then
      perform public.restore_module_week((x #>> '{}')::uuid);
      v_restored := v_restored + 1;
    end if;
  end loop;
  update public.cohort set merged_into = null, merged_from = null where id = any (m.source_cohort_ids) and merged_into = m.target_cohort_id;
  update public.cohort set archived_at = now() where id = m.target_cohort_id;
  update public.cohort_merge set status = 'Undone', undone_at = now() where id = m.id;
  perform private.log_event('Team actions', 'Cohort merge undone', 'cohort', m.target_cohort_id, null,
    jsonb_build_object('restored', v_restored), null, m.domain_id);
  return jsonb_build_object('ok', true, 'restored', v_restored);
end;
$$;

revoke execute on function private.merge_plan(uuid[], date, uuid, uuid, text, text, uuid[], uuid[]) from public, anon, authenticated;
revoke execute on function public.merge_cohorts(uuid[], date, uuid, uuid, text, text, uuid[], uuid[], boolean, boolean, text) from public, anon;
revoke execute on function public.undo_cohort_merge(uuid) from public, anon;
grant execute on function public.merge_cohorts(uuid[], date, uuid, uuid, text, text, uuid[], uuid[], boolean, boolean, text) to authenticated, service_role;
grant execute on function public.undo_cohort_merge(uuid) to authenticated, service_role;
