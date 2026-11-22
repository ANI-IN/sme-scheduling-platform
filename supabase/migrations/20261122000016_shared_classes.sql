-- Release 3, M10 (decision 303): one class shared by several cohorts.
--
-- One class week is the host: it keeps the class, its instructor (one booking), its requests and its messages, so the
-- instructor is booked and counted once. Each other cohort's class week that joins is a guest: it points to the host,
-- its classes follow the host's classes (same times; each guest class points to its host class), and it is never asked
-- or messaged while it is shared (it is paused, and resuming it is refused). The cohorts stay separate; each still
-- sees its class week in its own lists.
--
-- Sharing has a preview and these rules. Block: a class week that has started, is cancelled or finished, or is already
-- shared; class weeks of one cohort or of another domain; a different number of classes; different times without a
-- choice of whose times the shared class keeps; a confirmed instructor on a guest class week who is not the host's,
-- unless Ops chooses to release them (to keep that instructor instead, make their class week the host); and a clash or
-- unavailable date of the host's confirmed instructor at the chosen times. Warning (needs a reason): different
-- modules, and every check of the chosen times in each cohort's own time zone (odd hours, holidays, cohort holidays,
-- breaks, the cohort's other classes), and a tight gap or a full day for the instructor. When the shared class takes
-- a guest's times, the host's confirmed instructor is asked about the new time as for any time change.
--
-- Stopping the share gives the cohort its own class week back: its classes keep the shared times, it is no longer
-- paused, and its instructor order is asked (at once inside the asking window, else by the hourly run).

alter table public.module_week add column shared_with uuid references public.module_week (id) on delete set null;
alter table public.class_session add column shared_class_id uuid references public.class_session (id) on delete set null;
create index module_week_shared_with_idx on public.module_week (shared_with);
create index class_session_shared_class_idx on public.class_session (shared_class_id);

-- A guest class follows its host class; a guest class's time is changed only through its host, and a host class is
-- not cancelled while other cohorts share it.
create or replace function private.share_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if current_setting('app.share_sync', true) = 'on' then return new; end if;
  if new.shared_class_id is not null and (new.starts_at, new.ends_at) is distinct from (old.starts_at, old.ends_at) then
    raise exception '% is shared with another cohort''s class. Change the time on that class week, or stop sharing first.', new.title
      using errcode = '22023';
  end if;
  if old.status = 'Planned' and new.status = 'Cancelled'
     and exists (select 1 from public.class_session g where g.shared_class_id = new.id and g.status = 'Planned') then
    raise exception '% is shared with other cohorts. Stop sharing it first.', new.title using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger class_session_share_guard before update of starts_at, ends_at, status on public.class_session
  for each row execute function private.share_guard();

create or replace function private.share_follow()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.class_session g where g.shared_class_id = new.id) then
    perform set_config('app.share_sync', 'on', true);
    update public.class_session set starts_at = new.starts_at, ends_at = new.ends_at
     where shared_class_id = new.id and status = 'Planned';
    perform set_config('app.share_sync', 'off', true);
  end if;
  return null;
end;
$$;
create trigger class_session_share_follow after update of starts_at, ends_at on public.class_session
  for each row when ((new.starts_at, new.ends_at) is distinct from (old.starts_at, old.ends_at))
  execute function private.share_follow();

-- public.pause_outreach: a shared class week is not resumed (was 20261122000006_security_data_findings.sql).
create or replace function public.pause_outreach(p_module_week_id uuid, p_paused boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare w public.module_week;
begin
  if not p_paused and exists (select 1 from public.module_week x where x.id = p_module_week_id and x.shared_with is not null) then
    raise exception 'This class week is taught in another cohort''s class. Stop sharing it to ask its own instructor.' using errcode = '22023';
  end if;
  perform private.require_team();
  perform 1 from public.module_week where id = p_module_week_id for update;
  if p_paused and exists (select 1 from public.booking b where b.module_week_id = p_module_week_id and b.status = 'Active') then
    raise exception 'This class week already has a confirmed instructor, so there is nobody to ask. Its reminders before class and time changes go on as usual.'
      using errcode = '22023';
  end if;
  update public.module_week set paused = p_paused where id = p_module_week_id returning * into w;
  perform private.log_event('Team actions', case when p_paused then 'Asking paused' else 'Asking resumed' end,
    'module_week', p_module_week_id, null, null, null, w.domain_id, w.module_id, p_module_week_id);
end;
$$;

-- private.step_owner_checkins: no owner check-in for a class week taught in another cohort's class (was 20261112000005_r2_review_fixes.sql).
create or replace function private.step_owner_checkins(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  v_days int := private.setting_int(p_domain, 'owner_checkin_days');
  v_due uuid[];
  o uuid;
  w record;
  v_req uuid;
  v_text text;
  v_status text;
  n int := 0;
begin
  select coalesce(array_agg(mw.id), '{}') into v_due from public.module_week mw
   where mw.domain_id = p_domain and mw.status not in ('Cancelled', 'Completed') and mw.owner_checkin_sent_at is null and mw.shared_with is null
     and mw.first_class_at > p_now and mw.first_class_at - make_interval(days => private.setting_int(mw.id, 'owner_checkin_days')) <= p_now
     -- Off when the team is not reminded after an assignment, or the number is 0.
     and private.setting_bool(mw.id, 'remind_team_after_assign') and private.setting_int(mw.id, 'owner_checkin_days') > 0;
  if cardinality(v_due) = 0 then return 0; end if;

  for o in select distinct x from public.module_week mw, unnest(private.owners_or_leads(mw.module_id)) x where mw.id = any (v_due) loop
    -- OUT-4: each week has its own number of days (a cohort can change it), so the text names none.
    v_text := 'Coming up soon. Please check these class weeks:';
    for w in select mw.* from public.module_week mw
              where mw.id = any (v_due) and o = any (private.owners_or_leads(mw.module_id))
              order by mw.first_class_at loop
      insert into public.request (module_week_id, team_member_id, kind, status, sent_at, is_test)
      values (w.id, o, 'OwnerCheckIn', 'Sent', p_now,
              private.is_test_domain(p_domain))
      on conflict (module_week_id, team_member_id) where kind = 'OwnerCheckIn' do nothing
      returning id into v_req;
      if v_req is null then
        select q.id into v_req from public.request q where q.module_week_id = w.id and q.team_member_id = o and q.kind = 'OwnerCheckIn';
      end if;
      v_status := case
        when exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Active')
          then 'Confirmed: ' || (select i.full_name from public.booking b join public.instructor i on i.id = b.instructor_id
                                  where b.module_week_id = w.id and b.status = 'Active')
        when w.status = 'Asking' then 'Asking ' || coalesce((select i.full_name from public.request q join public.instructor i on i.id = q.instructor_id
                                  where q.module_week_id = w.id and q.kind = 'Outreach' and q.status in ('Sent', 'Reminded')), 'an instructor')
        when w.status = 'NeedsInstructor' then 'Needs instructor'
        else w.status end || case when w.at_risk then ' (at risk: ' || coalesce(w.at_risk_reason, '') || ')' else '' end;
      v_text := v_text || E'\n\n• ' || private.mw_label(w.id) || ' — ' || v_status
        || E'\n  👍 All good: ' || private.link_for(v_req, 'OwnerAllGood')
        || E'\n  🙋 Need help: ' || private.link_for(v_req, 'OwnerNeedHelp');
    end loop;
    perform private.queue_team_message('T11', p_domain, 'person', o, '{}',
      'Owner check in: your coming class weeks', v_text,
      'T11:' || o || ':' || md5(array_to_string(array(select x::text from unnest(v_due) x order by 1), ',')), p_now, true);
    n := n + 1;
  end loop;
  update public.module_week set owner_checkin_sent_at = p_now where id = any (v_due);
  return n;
end;
$$;

/** The Planned classes of a class week in order, numbered, for pairing a guest's classes with the host's. */
create or replace function private.week_classes(p_mw uuid)
returns table (n int, id uuid, title text, starts_at timestamptz, ends_at timestamptz, region text)
language sql stable security definer set search_path = ''
as $$
  select (row_number() over (order by c.starts_at, c.id))::int, c.id, c.title, c.starts_at, c.ends_at, c.region
    from public.class_session c where c.module_week_id = p_mw and c.status = 'Planned';
$$;

-- Everything sharing would do and every check, without saving.
create or replace function private.share_plan(p_host uuid, p_guests uuid[], p_times_from uuid, p_release boolean)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  h public.module_week;
  g public.module_week;
  v_gid uuid;
  v_now timestamptz;
  v_blocks text[] := '{}';
  v_warn jsonb := '[]';
  v_info text[] := '{}';
  v_guests jsonb := '[]';
  v_host_person record;
  v_person record;
  v_n int;
  v_differ boolean := false;
  v_times jsonb := '[]';
  k record;
  c record;
  v_clash text;
  v_cohort record;
begin
  select * into h from public.module_week where id = p_host;
  if h.id is null then raise exception 'Choose the class week that keeps the class.' using errcode = '22023'; end if;
  v_now := private.domain_now(h.domain_id);
  if cardinality(coalesce(p_guests, '{}')) = 0 then
    raise exception 'Choose at least one other class week to share it with.' using errcode = '22023';
  end if;
  select b.instructor_id as id, i.full_name as name into v_host_person
    from public.booking b join public.instructor i on i.id = b.instructor_id where b.module_week_id = h.id and b.status = 'Active';
  select count(*)::int into v_n from private.week_classes(h.id);

  if h.status in ('Cancelled', 'Completed') or h.first_class_at <= v_now then
    v_blocks := v_blocks || (private.mw_label(h.id) || ' has started or is no longer scheduled.');
  end if;
  if h.shared_with is not null then
    v_blocks := v_blocks || (private.mw_label(h.id) || ' is itself taught in another cohort''s class.');
  end if;
  if p_times_from is not null and p_times_from <> h.id and not p_times_from = any (p_guests) then
    raise exception 'Choose the times of one of these class weeks.' using errcode = '22023';
  end if;

  foreach v_gid in array p_guests loop
    select * into g from public.module_week where id = v_gid;
    if g.id is null then raise exception 'One of the class weeks no longer exists.' using errcode = '22023'; end if;
    if g.id = h.id or g.cohort_id is not distinct from h.cohort_id then
      v_blocks := v_blocks || (private.mw_label(g.id) || ' is in the same cohort. Only other cohorts can share a class.');
    end if;
    if g.domain_id <> h.domain_id then
      v_blocks := v_blocks || (private.mw_label(g.id) || ' is in another domain.');
    end if;
    if g.status in ('Cancelled', 'Completed') or g.first_class_at <= v_now then
      v_blocks := v_blocks || (private.mw_label(g.id) || ' has started or is no longer scheduled.');
    end if;
    if g.shared_with is not null or exists (select 1 from public.module_week x where x.shared_with = g.id) then
      v_blocks := v_blocks || (private.mw_label(g.id) || ' is already shared.');
    end if;
    if (select count(*) from private.week_classes(g.id)) <> v_n then
      v_blocks := v_blocks || (private.mw_label(g.id) || ' has a different number of classes, so they can''t be one class.');
    elsif exists (select 1 from private.week_classes(g.id) a join private.week_classes(h.id) b using (n)
                   where (a.starts_at, a.ends_at) is distinct from (b.starts_at, b.ends_at)) then
      v_differ := true;
    end if;
    if g.module_id <> h.module_id then
      v_warn := v_warn || jsonb_build_object('code', 'different_modules', 'level', 'Warning', 'module_week_id', g.id,
        'text', private.mw_label(g.id) || ' is another module than ' || private.mw_label(h.id)
                || ', so its cohort learns that module in this class.');
    end if;
    select b.instructor_id as id, i.full_name as name into v_person
      from public.booking b join public.instructor i on i.id = b.instructor_id where b.module_week_id = g.id and b.status = 'Active';
    if v_person.id is not null and v_person.id is distinct from v_host_person.id then
      if p_release then
        v_info := v_info || (v_person.name || ' is released from ' || private.mw_label(g.id) || ' and gets the release note.');
      else
        v_blocks := v_blocks || (v_person.name || ' is confirmed for ' || private.mw_label(g.id)
          || '. Choose whose instructor stays: to keep ' || v_person.name || ', make that class week the one that keeps the class; else release them.');
      end if;
    end if;
    select i.full_name as name into v_person from public.request r join public.instructor i on i.id = r.instructor_id
     where r.module_week_id = g.id and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded');
    if v_person.name is not null then
      v_info := v_info || (v_person.name || ' is no longer asked for ' || private.mw_label(g.id) || '.');
    end if;
    v_guests := v_guests || jsonb_build_object('module_week_id', g.id, 'label', private.mw_label(g.id),
      'cohort', (select name from public.cohort where id = g.cohort_id));
  end loop;
  if v_differ and p_times_from is null then
    v_blocks := v_blocks || 'The class weeks have different times. Choose whose times the shared class keeps.'::text;
  end if;
  v_info := v_info || 'The other class weeks are not asked while they share this class.'::text;

  -- The times the shared class keeps, checked for every cohort in its own time zone.
  for k in select a.n, a.id as host_class, a.title, a.region,
                  coalesce(b.starts_at, a.starts_at) as s, coalesce(b.ends_at, a.ends_at) as e,
                  (b.id is not null and (b.starts_at, b.ends_at) is distinct from (a.starts_at, a.ends_at)) as moves
             from private.week_classes(h.id) a
             left join private.week_classes(case when p_times_from is distinct from h.id then p_times_from end) b using (n)
            order by a.n loop
    v_times := v_times || jsonb_build_object('title', k.title, 'shown', private.fmt_class_range(k.s, k.e, k.region), 'moves', k.moves);
    for v_cohort in select w.id as mw, w.cohort_id, coalesce(co.region, k.region) as region
                      from public.module_week w left join public.cohort co on co.id = w.cohort_id
                     where w.id = h.id or w.id = any (p_guests) loop
      v_warn := v_warn || coalesce((select jsonb_agg(x || jsonb_build_object('module_week_id', v_cohort.mw))
        from jsonb_array_elements(private.class_warnings(h.domain_id, v_cohort.cohort_id, k.s, k.e, v_cohort.mw, k.title, v_cohort.region)) x
       where x ->> 'code' <> 'short_notice'
         and not (x ->> 'code' = 'cohort_overlap' and v_cohort.mw <> h.id and not k.moves)), '[]');
    end loop;
    if k.moves and v_host_person.id is not null then
      v_clash := private.clash_text(v_host_person.id, k.s, k.e, k.region, h.id);
      if v_clash is not null then
        v_blocks := v_blocks || (v_host_person.name || ' is in two classes at once at the chosen time. ' || v_clash || '.');
      end if;
      v_blocks := v_blocks || array(select x ->> 'text' from jsonb_array_elements(private.instructor_warnings(h.domain_id,
        v_host_person.id, k.s, k.e, k.region, k.host_class, k.title)) x where x ->> 'level' = 'Block');
      v_warn := v_warn || coalesce((select jsonb_agg(x) from jsonb_array_elements(private.instructor_warnings(h.domain_id,
        v_host_person.id, k.s, k.e, k.region, k.host_class, k.title)) x where x ->> 'level' = 'Warning'), '[]');
    end if;
  end loop;
  if v_host_person.id is not null and exists (select 1 from jsonb_array_elements(v_times) x where (x ->> 'moves')::boolean) then
    v_info := v_info || (v_host_person.name || ' is asked to confirm the new time.');
  end if;

  return jsonb_build_object('host', jsonb_build_object('module_week_id', h.id, 'label', private.mw_label(h.id),
      'cohort', (select name from public.cohort where id = h.cohort_id), 'instructor', v_host_person.name),
    'guests', v_guests, 'times', v_times, 'different_times', v_differ, 'blocks', to_jsonb(v_blocks),
    'warnings', coalesce((select jsonb_agg(e) from (select distinct on (e ->> 'text') e from jsonb_array_elements(v_warn) e) s), '[]'),
    'effects', to_jsonb(v_info));
end;
$$;

-- Share a class: the preview without p_save; with it, the class is shared (no Block left, a reason past a Warning).
create or replace function public.share_class_weeks(p_host_id uuid, p_guest_ids uuid[], p_times_from uuid default null,
  p_release_instructors boolean default false, p_save boolean default false, p_accept_warnings boolean default false,
  p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_plan jsonb;
  h public.module_week;
  v_guest uuid;
  v_now timestamptz;
  k record;
  v_moved boolean := false;
  v_clash boolean := false;
  bk public.booking;
  v_sent boolean;
  v_name text;
begin
  perform private.require_team();
  select * into h from public.module_week where id = p_host_id;
  if p_save and h.id is not null then perform pg_advisory_xact_lock(hashtext('plan:' || h.domain_id::text)); end if;
  v_plan := private.share_plan(p_host_id, p_guest_ids, p_times_from, p_release_instructors);
  if not p_save then return v_plan || jsonb_build_object('ok', true, 'preview', true); end if;
  if jsonb_array_length(v_plan -> 'blocks') > 0 then return v_plan || jsonb_build_object('ok', false); end if;
  if exists (select 1 from jsonb_array_elements(v_plan -> 'warnings') x where x ->> 'level' = 'Warning') and not p_accept_warnings then
    return v_plan || jsonb_build_object('ok', false, 'needs_confirmation', true);
  end if;
  v_now := private.domain_now(h.domain_id);
  perform private.log_accepted_warnings(v_plan -> 'warnings', p_reason, h.domain_id, h.module_id, h.id);

  -- The shared class keeps a guest's times: the host's classes move, and its instructor is asked as usual.
  if p_times_from is not null and p_times_from <> h.id then
    for k in select a.id, b.starts_at, b.ends_at from private.week_classes(h.id) a join private.week_classes(p_times_from) b using (n)
              where (a.starts_at, a.ends_at) is distinct from (b.starts_at, b.ends_at) order by b.starts_at desc loop
      v_clash := private.move_class(k.id, k.starts_at, k.ends_at) or v_clash;
      v_moved := true;
    end loop;
    if v_clash then raise exception 'The host''s instructor clashes at the chosen time.' using errcode = '23P01'; end if;
  end if;

  foreach v_guest in array p_guest_ids loop
    v_sent := exists (select 1 from public.message m join public.request r on r.id = m.request_id
                       where r.module_week_id = v_guest and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')
                         and m.status in ('Sending', 'Sent'));
    perform private.withdraw_open_request(v_guest, 'Shared with another class', v_now, v_sent);
    for bk in select * from public.booking where module_week_id = v_guest and status = 'Active' loop
      select full_name into v_name from public.instructor where id = bk.instructor_id;
      update public.booking set status = 'Released', released_at = v_now, release_reason = 'OpsReleased' where id = bk.id;
      update public.request set status = 'Superseded', close_reason = 'Booking released'
       where booking_id = bk.id and status in ('Queued', 'Sent', 'Reminded');
      -- The host's own instructor teaches the shared class, so only someone else hears they are no longer needed.
      if bk.instructor_id is distinct from (select x.instructor_id from public.booking x where x.module_week_id = h.id and x.status = 'Active') then
        perform private.queue_instructor_message('M16', bk.instructor_id, v_guest, null, v_now, '[]', '{}', false, 'release:' || bk.id);
      end if;
      perform private.log_event('Bookings', 'Booking released: ' || v_name, 'booking', bk.id, jsonb_build_object('status', 'Active'),
        jsonb_build_object('status', 'Released', 'reason', 'Shared with another class'), null,
        h.domain_id, (select module_id from public.module_week where id = v_guest), v_guest, null, bk.instructor_id);
    end loop;
    perform set_config('app.share_sync', 'on', true);
    update public.class_session g set starts_at = a.starts_at, ends_at = a.ends_at, shared_class_id = a.id
      from private.week_classes(h.id) a join private.week_classes(v_guest) x using (n)
     where g.id = x.id;
    perform set_config('app.share_sync', 'off', true);
    update public.module_week set shared_with = h.id, paused = true, status = 'Planned', at_risk = false, at_risk_reason = null
     where id = v_guest;
    perform private.log_event('Team actions', 'Class shared', 'module_week', v_guest, null,
      jsonb_build_object('host', h.id, 'host_label', private.mw_label(h.id)), null,
      h.domain_id, (select module_id from public.module_week where id = v_guest), v_guest);
  end loop;
  if v_moved then perform private.week_times_changed(h.id, v_now, false); end if;
  perform private.log_event('Team actions', 'Class shared with ' || cardinality(p_guest_ids) || ' other class week(s)', 'module_week',
    h.id, null, jsonb_build_object('guests', to_jsonb(p_guest_ids)), null, h.domain_id, h.module_id, h.id);
  perform private.queue_deliver('share');
  return v_plan || jsonb_build_object('ok', true, 'saved', cardinality(p_guest_ids));
end;
$$;

-- Stop sharing: the cohort gets its own class week back and its instructor order is asked.
create or replace function public.stop_sharing(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare w public.module_week; v_now timestamptz; v_host uuid; v_asked boolean := false;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.shared_with is null then raise exception 'This class week is not shared.' using errcode = '22023'; end if;
  v_host := w.shared_with;
  v_now := private.domain_now(w.domain_id);
  update public.class_session set shared_class_id = null where module_week_id = w.id;
  update public.module_week set shared_with = null, paused = false where id = w.id;
  if w.first_class_at > v_now
     and w.first_class_at - v_now <= make_interval(days => private.setting_int(w.id, 'outreach_days')) then
    perform private.ask_next(w.id, v_now);
    v_asked := true;
  end if;
  perform private.log_event('Team actions', 'Class no longer shared', 'module_week', w.id, null,
    jsonb_build_object('host', v_host, 'host_label', private.mw_label(v_host)), null, w.domain_id, w.module_id, w.id);
  perform private.queue_deliver('stop sharing');
  return jsonb_build_object('ok', true, 'asked', v_asked);
end;
$$;

-- private.week_problems: a shared class (was 20261122000015_time_proposals.sql).
create or replace function private.week_problems(p_mw uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  w public.module_week;
  v jsonb := '[]';
  v_person uuid;
  v_booked boolean;
  v_name text;
  v_status text;
  v_limit int;
  v_month_classes int;
  c record;
  v_clash text;
  v_gone record;
  v_now_name text;
begin
  select * into w from public.module_week where id = p_mw;
  if w.id is null or w.status in ('Cancelled', 'Completed') then return '[]'; end if;
  select b.instructor_id into v_person from public.booking b where b.module_week_id = p_mw and b.status = 'Active';
  v_booked := v_person is not null;
  if not v_booked then
    select r.instructor_id into v_person from public.request r
     where r.module_week_id = p_mw and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded');
  end if;
  select i.full_name, i.status, i.monthly_class_limit into v_name, v_status, v_limit
    from public.instructor i where i.id = v_person;

  for c in select * from public.class_session where module_week_id = p_mw and status = 'Planned' order by starts_at loop
    v := v || coalesce((
      select jsonb_agg(case
               when x ->> 'code' = 'cohort_holiday' and c.holiday_kept_on = (c.starts_at at time zone private.region_tz(c.region))::date
                 then x || jsonb_build_object('class_id', c.id, 'level', 'Information',
                        'text', (x ->> 'text') || ' Kept: ' || rtrim(c.holiday_kept_reason, '.') || '.', 'fixes', '[]'::jsonb)
               else x || jsonb_build_object('class_id', c.id, 'fixes',
                        case x ->> 'code' when 'holiday' then '["move_class", "cancel_class", "keep"]'::jsonb
                                          when 'cohort_holiday' then '["move_class", "cancel_class", "keep_with_reason"]'::jsonb
                                          when 'in_break' then '["move_class", "cancel_class"]'::jsonb
                                          else '["move_class", "keep"]'::jsonb end) end)
        from jsonb_array_elements(private.class_warnings(w.domain_id, w.cohort_id, c.starts_at, c.ends_at, p_mw, c.title, c.region)) x
       where x ->> 'code' <> 'short_notice'), '[]');
    if v_person is not null then
      v_clash := private.clash_text(v_person, c.starts_at, c.ends_at, c.region, p_mw);
      if v_clash is not null then
        v := v || jsonb_build_array(jsonb_build_object('code', 'clash', 'level', 'Block', 'class_id', c.id,
               'instructor_id', v_person, 'text', v_name || ' is in two classes at once. ' || v_clash || '.',
               'fixes', '["ask_next", "move_class", "share_class"]'::jsonb));
      end if;
      v := v || coalesce((
        select jsonb_agg(x || jsonb_build_object('class_id', c.id, 'fixes',
                 case x ->> 'code' when 'unavailable' then
                        case when v_booked then '["release_and_ask_next"]'::jsonb else '["ask_next"]'::jsonb end
                      else '["move_class", "ask_next"]'::jsonb end))
          from jsonb_array_elements(private.instructor_warnings(w.domain_id, v_person, c.starts_at, c.ends_at, c.region,
                                                                case when v_booked then c.id end, c.title)) x), '[]');
    end if;
  end loop;

  if v_person is not null and v_limit is not null then
    if v_booked then
      select count(*)::int into v_month_classes
        from public.booking_slot s join public.class_session c2 on c2.id = s.class_id
       where s.instructor_id = v_person and s.active and c2.status <> 'Cancelled'
         and date_trunc('month', c2.starts_at at time zone private.region_tz(c2.region))
           = date_trunc('month', w.first_class_at at time zone private.region_tz(private.week_region(w.id)));
    end if;
    if (v_booked and v_month_classes > v_limit) or (not v_booked and private.instructor_soft_warning(v_person, p_mw) is not null) then
      v := v || jsonb_build_array(jsonb_build_object('code', 'monthly_limit', 'level', 'Warning', 'instructor_id', v_person,
             'text', v_name || ' is over their limit of ' || v_limit || ' classes a month.',
             'fixes', '["ask_next", "keep"]'::jsonb));
    end if;
  end if;
  if v_booked and v_status in ('Inactive', 'Archived') then
    v := v || jsonb_build_array(jsonb_build_object('code', 'not_in_use', 'level', 'Warning', 'instructor_id', v_person,
           'text', v_name || ' is ' || lower(v_status) || ' but still confirmed for this class week.',
           'fixes', '["release_and_ask_next", "keep"]'::jsonb));
  end if;

  -- The last instructor who gave way to a sooner class, while this week is still looking.
  if not v_booked then
    select r.instructor_id, i.full_name into v_gone
      from public.request r join public.instructor i on i.id = r.instructor_id
     where r.module_week_id = p_mw and r.kind = 'Outreach' and r.status = 'Withdrawn' and r.close_reason = 'Sooner class'
     order by r.created_at desc limit 1;
    if v_gone.instructor_id is not null then
      v_now_name := case when v_person is not null then v_name end;
      v := v || jsonb_build_array(jsonb_build_object('code', 'sooner_class_first', 'level', 'Information',
             'instructor_id', v_gone.instructor_id,
             'text', v_gone.full_name || ' is busy with a sooner class at the same time'
                     || coalesce(', so ' || v_now_name || ' is asked instead.', '.'),
             'fixes', '[]'::jsonb));
    end if;
  end if;

  -- A proposed time waiting for a decision.
  select tp.instructor_id, i.full_name into v_gone from public.time_proposal tp join public.instructor i on i.id = tp.instructor_id
   where tp.module_week_id = p_mw and tp.status = 'Pending';
  if v_gone.instructor_id is not null then
    v := v || jsonb_build_array(jsonb_build_object('code', 'proposed_time', 'level', 'Information', 'instructor_id', v_gone.instructor_id,
           'text', v_gone.full_name || ' proposed another time.', 'fixes', '["accept_proposal", "reject_proposal"]'::jsonb));
  end if;
  -- A class moved and the confirmed instructor has not answered yet.
  if v_booked and exists (select 1 from public.request q where q.module_week_id = p_mw and q.kind = 'TimeChange'
                            and q.status in ('Queued', 'Sent', 'Reminded')) then
    v := v || jsonb_build_array(jsonb_build_object('code', 'waiting_new_time', 'level', 'Information', 'instructor_id', v_person,
           'text', 'Waiting for ' || v_name || ' to confirm the new time.', 'fixes', '[]'::jsonb));
  end if;

  -- A class shared by several cohorts.
  if w.shared_with is not null then
    v := v || jsonb_build_array(jsonb_build_object('code', 'shared_class', 'level', 'Information',
           'text', 'Taught together with ' || private.mw_label(w.shared_with) || '.', 'fixes', '["stop_sharing"]'::jsonb));
  elsif exists (select 1 from public.module_week x where x.shared_with = p_mw) then
    v := v || jsonb_build_array(jsonb_build_object('code', 'shared_class', 'level', 'Information',
           'text', 'Shared with ' || (select string_agg(coalesce(co.name, private.mw_label(x.id)), ', ' order by co.name)
                                      from public.module_week x left join public.cohort co on co.id = x.cohort_id
                                     where x.shared_with = p_mw) || '.', 'fixes', '["stop_sharing"]'::jsonb));
  end if;

  -- One line per problem: a full day or the monthly limit is the same problem for each class of the day.
  return coalesce((
    select jsonb_agg(e order by ord)
      from (select distinct on (e ->> 'code', e ->> 'text') e, ord
              from jsonb_array_elements(v) with ordinality as t(e, ord)
             order by e ->> 'code', e ->> 'text', ord) s), '[]');
end;
$$;

revoke execute on function private.share_guard() from public, anon, authenticated;
revoke execute on function private.share_follow() from public, anon, authenticated;
revoke execute on function private.week_classes(uuid) from public, anon, authenticated;
revoke execute on function private.share_plan(uuid, uuid[], uuid, boolean) from public, anon, authenticated;
revoke execute on function public.share_class_weeks(uuid, uuid[], uuid, boolean, boolean, boolean, text) from public, anon;
revoke execute on function public.stop_sharing(uuid) from public, anon;
grant execute on function public.share_class_weeks(uuid, uuid[], uuid, boolean, boolean, boolean, text) to authenticated, service_role;
grant execute on function public.stop_sharing(uuid) to authenticated, service_role;
