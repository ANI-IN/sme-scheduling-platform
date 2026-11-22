-- Release 3, owner's item 1: one set of status words everywhere a person reads them.
--
-- A class week's status is only ever shown as Confirmed, Waiting for an answer, Needs instructor, Proposed time,
-- Not asked yet, Setup incomplete, Paused, Cancelled, Completed or Break (docs/GLOSSARY.md). The database keeps its
-- own codes (module_week.status: Planned, NotReady, Ready, Asking, NeedsInstructor and so on); this changes only the
-- text it writes for people:
--   1. private.week_status_text: the status of a class week in those words, from private.board_status (the board's
--      own order), with the instructor's name for Confirmed, Waiting for an answer and Proposed time.
--   2. The owner check in message (T11) said "Asking <name>" and showed raw codes (Planned, NotReady, Ready) for the
--      other class weeks; it now uses private.week_status_text.
--   3. The practice class said "Class week is Ready" (a code); it now says "Status: Not asked yet".
-- Rollback: supabase/rollback/20261123000028_status_words.sql.

-- private.week_status_text: new.
create or replace function private.week_status_text(p_mw uuid, p_now timestamptz)
returns text language sql stable security definer set search_path = ''
as $$
  select case s ->> 'status' when 'Waiting' then 'Waiting for an answer' else s ->> 'status' end
      || case when s ->> 'status' in ('Confirmed', 'Waiting', 'Proposed time') and s ->> 'instructor' is not null
              then ': ' || (s ->> 'instructor') else '' end
    from private.board_status(p_mw, p_now) s;
$$;
revoke execute on function private.week_status_text(uuid, timestamptz) from public, anon, authenticated;

-- private.step_owner_checkins: the status in the board's words (was 20261122000016_shared_classes.sql).
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
      -- The status in the board's words, with the instructor who is confirmed, asked or proposing a time.
      v_status := private.week_status_text(w.id, p_now)
        || case when w.at_risk then ' (at risk: ' || coalesce(w.at_risk_reason, '') || ')' else '' end;
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


-- public.run_practice_class: the setup check stage names the status in the board's words (was
-- 20261111000006_release_pages.sql).
create or replace function public.run_practice_class(p_domain_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  d public.domain;
  v_mod public.module;
  v_tests uuid[];
  v_cohort uuid;
  v_mw uuid;
  v_first date;
  v_steps jsonb := '[]';
  v_now timestamptz;
  r public.request;
  v_tok text;
  v_ok boolean;
  v_class uuid;
  v_status text;
  v_failed text;
  v_clock timestamptz;

begin
  perform private.require_team();
  select * into d from public.domain where id = p_domain_id;
  if d.status <> 'Test' then
    raise exception 'Turn on testing for this domain first. A practice class only runs in testing.' using errcode = '22023';
  end if;
  select m.* into v_mod from public.module m
   where m.domain_id = p_domain_id and m.status = 'Active'
     and exists (select 1 from public.class_pattern_item p where p.module_id = m.id and p.cohort_id is null)
   order by m.rotation_order limit 1;
  if v_mod.id is null then raise exception 'Add a module with class times first.' using errcode = '22023'; end if;
  select array_agg(i.id order by i.full_name) into v_tests from public.instructor i
   where i.is_test and i.status = 'Active' and i.verified_at is not null;
  if coalesce(cardinality(v_tests), 0) < 2 then
    raise exception 'Add at least two test instructors with checked contact details first.' using errcode = '22023';
  end if;
  v_clock := d.test_clock_at;

  begin
    v_first := (now() at time zone 'America/Los_Angeles')::date + 60;
    insert into public.cohort (domain_id, name, status) values (p_domain_id, 'Practice class ' || to_char(now(), 'YYYYMMDDHH24MISS'), 'Planned')
    returning id into v_cohort;
    v_mw := ((public.create_module_weeks(p_domain_id, jsonb_build_array(jsonb_build_object('module_id', v_mod.id, 'cohort_id', v_cohort,
      'classes', public.generate_classes(p_domain_id, v_mod.id, array[v_first], 'Main cohort') -> 0 -> 'classes')), true, 'Practice class'))
      -> 'module_week_ids' ->> 0)::uuid;
    perform public.set_outreach_queue(v_mw, 'Manual', v_tests[1:2], 'Stop', null, false);

    -- 1. Setup check
    v_now := (select first_class_at from public.module_week where id = v_mw) - make_interval(days => private.setting_int(v_mw, 'readiness_days'));
    update public.domain set test_clock_at = v_now where id = p_domain_id;
    perform public.engine_tick(p_domain_id);
    v_status := (select status from public.module_week where id = v_mw);
    v_steps := v_steps || jsonb_build_object('step', 'Setup check passes', 'passed', v_status = 'Ready', 'detail', 'Status: ' || private.week_status_text(v_mw, v_now));

    -- 2. Asked
    v_now := (select first_class_at from public.module_week where id = v_mw) - make_interval(days => private.setting_int(v_mw, 'outreach_days'));
    update public.domain set test_clock_at = v_now where id = p_domain_id;
    perform public.engine_tick(p_domain_id);
    select * into r from public.request where module_week_id = v_mw and kind = 'Outreach' and status in ('Sent', 'Reminded');
    v_steps := v_steps || jsonb_build_object('step', 'The first test instructor is asked', 'passed', r.instructor_id = v_tests[1],
      'detail', coalesce((select full_name from public.instructor where id = r.instructor_id), 'Nobody was asked'));

    -- 3. Reminded
    if r.id is not null then
      update public.domain set test_clock_at = r.reminder_at + interval '1 minute' where id = p_domain_id;
      perform public.engine_tick(p_domain_id);
    end if;
    v_steps := v_steps || jsonb_build_object('step', 'A reminder is sent when there is no reply',
      'passed', (select status from public.request where id = r.id) = 'Reminded', 'detail', null);

    -- 4. Moved on
    if r.id is not null then
      update public.domain set test_clock_at = r.deadline_at + interval '1 minute' where id = p_domain_id;
      perform public.engine_tick(p_domain_id);
    end if;
    select * into r from public.request where module_week_id = v_mw and kind = 'Outreach' and status in ('Sent', 'Reminded');
    v_steps := v_steps || jsonb_build_object('step', 'The next test instructor is asked after the reply time',
      'passed', r.instructor_id = v_tests[2], 'detail', coalesce((select full_name from public.instructor where id = r.instructor_id), 'Nobody was asked'));

    -- 5. Confirmed
    select l.token into v_tok from public.response_link l where l.request_id = r.id and l.answer = 'Yes';
    if v_tok is not null then perform public.record_response(v_tok, 'Yes'); end if;
    v_ok := exists (select 1 from public.booking where module_week_id = v_mw and status = 'Active' and instructor_id = v_tests[2]);
    v_steps := v_steps || jsonb_build_object('step', 'A Yes confirms the instructor', 'passed', v_ok, 'detail', null);

    -- 6. Reminder before class
    update public.domain set test_clock_at = (select first_class_at from public.module_week where id = v_mw)
      - make_interval(days => (private.checkin_days_for(v_mw))[cardinality(private.checkin_days_for(v_mw))]) + interval '1 hour'
     where id = p_domain_id;
    perform public.engine_tick(p_domain_id);
    select * into r from public.request where module_week_id = v_mw and kind = 'CheckIn' order by created_at desc limit 1;
    v_steps := v_steps || jsonb_build_object('step', 'The reminder before class is sent', 'passed', r.id is not null, 'detail', null);

    -- 7. Help request
    perform public.create_help_request(v_mw, array['zoom'], 'Practice: the Zoom link is missing.', 'Within24h');
    v_steps := v_steps || jsonb_build_object('step', 'A help request reaches the team',
      'passed', exists (select 1 from public.attention_item a where a.module_week_id = v_mw and a.type = 'HelpRequest'), 'detail', null);

    -- 8. Time change
    select c.id into v_class from public.class_session c where c.module_week_id = v_mw and c.status = 'Planned' order by c.starts_at limit 1;
    perform public.change_class_time(v_class,
      ((select starts_at from public.class_session where id = v_class) at time zone 'America/Los_Angeles')::date,
      ((select starts_at from public.class_session where id = v_class) at time zone 'America/Los_Angeles')::time + interval '1 hour',
      ((select ends_at from public.class_session where id = v_class) at time zone 'America/Los_Angeles')::time + interval '1 hour');
    v_steps := v_steps || jsonb_build_object('step', 'A time change asks the instructor to confirm the new time',
      'passed', exists (select 1 from public.request where module_week_id = v_mw and kind = 'TimeChange'), 'detail', null);

    -- 9. Cancellation by the instructor
    select l.token into v_tok from public.response_link l join public.request q on q.id = l.request_id
     where q.module_week_id = v_mw and q.kind = 'CheckIn' and l.answer = 'CantMakeIt' order by q.created_at desc limit 1;
    if v_tok is not null then perform public.record_response(v_tok, 'CantMakeIt'); end if;
    v_steps := v_steps || jsonb_build_object('step', 'A cancellation releases the instructor and asks others',
      'passed', not exists (select 1 from public.booking where module_week_id = v_mw and status = 'Active'), 'detail', null);

    v_steps := v_steps || jsonb_build_object('step', 'Messages are written', 'passed',
      (select count(*) from public.message where module_week_id = v_mw) > 0,
      'detail', (select count(*) from public.message where module_week_id = v_mw) || ' messages would have been sent');
    raise exception 'practice_rollback';
  exception when others then
    if sqlerrm <> 'practice_rollback' then
      v_failed := sqlerrm;
    end if;
  end;
  -- Everything above is undone: classes, requests, messages and history of the practice.
  update public.domain set test_clock_at = v_clock where id = p_domain_id;
  if v_failed is not null then
    v_steps := v_steps || jsonb_build_object('step', 'The practice stopped early', 'passed', false, 'detail', v_failed);
  end if;
  perform private.log_event('Team actions', 'Practice class run', 'domain', p_domain_id, null,
    jsonb_build_object('steps', v_steps, 'passed', not exists (select 1 from jsonb_array_elements(v_steps) s where not (s ->> 'passed')::boolean)),
    null, p_domain_id);
  return jsonb_build_object('steps', v_steps,
    'passed', not exists (select 1 from jsonb_array_elements(v_steps) s where not coalesce((s ->> 'passed')::boolean, false)));
end;
$$;

