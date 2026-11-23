-- Release 3, owner's items B6 to B9: setup is simpler and says what it means.
--
-- B6. The contact check is optional. Instructors the team adds are asked whether or not they confirmed a contact
--     check: private.eligibility no longer gives "Not verified", the setup check no longer names it, no task is
--     raised for it any more (open ones close by themselves), and the practice class needs two test instructors,
--     checked or not. instructor.verified_at stays and is shown as information only; "Send contact check" stays.
-- B7. A short welcome message (M22, editable on Settings, Message templates) when an instructor's Discord channel
--     is first chosen for a domain (public.set_instructor_channel) and when a new instructor is added with an email
--     (public.send_welcome_message, called by the app). It goes through the normal message queue, so testing, quiet
--     hours, the beta rules and delivery apply. A new setting, "Send a welcome message to new instructors" (default
--     on, Settings, Automation), switches it off; changing it is logged like every setting. Activity history says
--     "Welcome message sent to <name>", or "Welcome message to <name> blocked" with the reason. It is never sent
--     twice to one instructor for the same domain and channel; one that was blocked may go once the reason is gone.
-- B8. A module is Ready with at least 1 instructor in its instructor order: the setting min_active_instructors now
--     defaults to 1 (was 2) and says what it is for, and the setup step on Home uses it.
-- B9. Modules are Draft (status Inactive: being set up, nobody is asked), Live (status Active: instructors are
--     asked) or Archived. Only the words change; the stored values stay as they are, so no data moves.
-- Rollback: supabase/rollback/20261123000032_setup_simple.sql.

-- B8: the number of instructors a module needs to be Ready, 1 by default.
update public.setting_definition
   set default_value = '1', label = 'A module is ready with at least this many instructors in its instructor order',
       help = 'Counts instructors in use. Shown on Modules and in the setup steps on Home.'
 where key = 'min_active_instructors';

-- B7: the welcome message can be switched off for a domain.
insert into public.setting_definition (key, group_name, label, value_type, default_value, help, sort_order) values
  ('welcome_message', 'Outreach', 'Send a welcome message to new instructors', 'bool', 'true',
   'Once on Discord when their channel in this domain is first chosen, and once by email when they are added.', 45);

-- private.eligibility: B6: instructors are asked whether or not their contact details were checked (was 20261122000004_beta_guard.sql).
create or replace function private.eligibility(p_instructor uuid, p_mw uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_domain uuid;
  v_status text;
  v_reason text;
begin
  select * into i from public.instructor where id = p_instructor;
  select w.domain_id, d.status into v_domain, v_status
    from public.module_week w join public.domain d on d.id = w.domain_id where w.id = p_mw;
  if i.id is null then return 'Unknown instructor'; end if;
  if i.status = 'Inactive' then return 'Inactive'; end if;
  if i.status = 'Archived' then return 'Archived'; end if;
  if v_status = 'Live' and i.is_test
     and (select c.environment from public.app_config c where c.id = 1) <> 'Sandbox'
     and (select c.message_recipients from public.app_config c where c.id = 1) = 'Anyone' then return 'Test instructor (not allowed in Live domains)'; end if;
  if i.discord_user_id is null and i.email_bounced_at is not null then return 'No working contact details'; end if;

  select 'Unavailable ' || to_char(u.from_date, 'Mon FMDD') || ' to ' || to_char(u.to_date, 'Mon FMDD')
    into v_reason
    from public.instructor_unavailability u
   where u.instructor_id = p_instructor
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and (c.starts_at at time zone private.region_tz(c.region))::date between u.from_date and u.to_date)
   order by u.from_date limit 1;
  if v_reason is not null then return v_reason; end if;

  -- Clashes are checked on the real time (UTC), across every cohort, domain and region.
  return private.week_clash(p_instructor, p_mw);
end;
$$;

-- private.step_health: B6: no task for an instructor whose contact details are not checked; open ones close (was 20261113000008_final_round.sql).
create or replace function private.step_health(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  m record;
  i record;
  v_min int;
  v_weeks int := private.setting_int(p_domain, 'schedule_low_weeks');
  v_last date;
  v_cnt int;
  v_live boolean := (select d.status = 'Live' from public.domain d where d.id = p_domain);
  n int := 0;
begin
  for m in select * from public.module where domain_id = p_domain and status = 'Active' loop
    v_min := private.setting_int(m.id, 'min_active_instructors');
    select count(*) into v_cnt from public.module_ranking k join public.instructor ins on ins.id = k.instructor_id
     where k.module_id = m.id and ins.status = 'Active' and (not v_live or not ins.is_test or (select c.environment from public.app_config c where c.id = 1) = 'Sandbox');
    if v_cnt < v_min then
      perform private.raise_attention(p_domain, 'ThinBench', 'Normal',
        'Thin bench: ' || m.name || ' has ' || v_cnt || ' active instructor' || case when v_cnt = 1 then '' else 's' end || ' (minimum ' || v_min || ')',
        'Add instructors to the instructor order.', 'thinbench:' || m.id, private.owners_or_leads(m.id), p_now,
        jsonb_build_object('module_id', m.id));
      n := n + 1;
    else
      perform private.resolve_attention('thinbench:' || m.id, 'Enough active instructors');
    end if;
  end loop;

  -- The contact check is optional (B6): a task about it from before closes by itself.
  for i in select a.dedupe_key from public.attention_item a
            where a.domain_id = p_domain and a.type = 'UnverifiedInRanking' and a.status <> 'Done' loop
    perform private.resolve_attention(i.dedupe_key, 'The contact check is optional');
  end loop;

  select max(mw.week_start_date) into v_last from public.module_week mw where mw.domain_id = p_domain and mw.status <> 'Cancelled';
  if v_last is null or v_last < (p_now at time zone 'America/Los_Angeles')::date + v_weeks * 7 then
    perform private.raise_attention(p_domain, 'ScheduleLow', 'Normal',
      'Schedule running low: classes planned only until ' || coalesce(to_char(v_last, 'Mon FMDD, YYYY'), 'nothing planned'),
      'Plan at least ' || v_weeks || ' weeks ahead (Schedule → Plan classes).', 'schedulelow:' || p_domain,
      private.uniq(private.domain_role_ids(p_domain, 'Ops') || private.domain_role_ids(p_domain, 'Lead')), p_now);
  else
    perform private.resolve_attention('schedulelow:' || p_domain, 'Enough weeks planned');
  end if;
  return n;
end;
$$;

-- public.run_practice_class: B6: the practice class needs two test instructors, checked or not (was 20261123000028_status_words.sql).
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
   where i.is_test and i.status = 'Active';
  if coalesce(cardinality(v_tests), 0) < 2 then
    raise exception 'Add at least two test instructors first.' using errcode = '22023';
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

-- private.readiness_problems: B6 and B9: the setup check no longer needs a contact check, and says Draft (was 20261113000007_no_materials.sql).
create or replace function private.readiness_problems(p_mw uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  w public.module_week;
  m public.module;
  v jsonb := '[]';
begin
  select * into w from public.module_week where id = p_mw;
  select * into m from public.module where id = w.module_id;
  if not exists (select 1 from public.class_session c where c.module_week_id = p_mw and c.status = 'Planned') then
    v := v || jsonb_build_object('code', 'no_classes', 'text', 'No classes planned for this week', 'blocking', true);
  end if;
  if m.status <> 'Active' then
    v := v || jsonb_build_object('code', 'module_inactive', 'text', 'The module is a draft, so nobody is asked', 'blocking', true);
  end if;
  if cardinality(private.module_owner_ids(m.id)) = 0 then
    v := v || jsonb_build_object('code', 'no_owner', 'text', 'No owner set for the module', 'blocking', true);
  end if;
  if not exists (select 1 from private.build_line(p_mw) l where l.reason is null) then
    v := v || jsonb_build_object('code', 'no_instructor',
      'text', 'Nobody in line is in use, available and free at that time', 'blocking', true);
  end if;
  return v;
end;
$$;

-- public.domain_setup_status: B8: every module needs at least the set number of instructors in its order (was 20261111000006_release_pages.sql).
create or replace function public.domain_setup_status(p_domain_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with d as (select * from public.domain where id = p_domain_id),
       mods as (select m.* from public.module m where m.domain_id = p_domain_id and m.status = 'Active')
  select jsonb_build_array(
    jsonb_build_object('key', 'modules', 'label', 'Add at least one module', 'link', '/setup/modules',
      'done', exists (select 1 from mods)),
    jsonb_build_object('key', 'class_times', 'label', 'Add class times to every module', 'link', '/setup/modules',
      'done', exists (select 1 from mods) and not exists (select 1 from mods m where not exists (select 1 from public.class_pattern_item p where p.module_id = m.id))),
    jsonb_build_object('key', 'instructors', 'label',
      'Put at least ' || private.setting_int(p_domain_id, 'min_active_instructors') || ' instructor'
        || case when private.setting_int(p_domain_id, 'min_active_instructors') = 1 then '' else 's' end
        || ' in the instructor order of every module', 'link', '/setup/modules',
      'done', exists (select 1 from mods) and not exists (select 1 from mods m
        where (select count(*) from public.module_ranking k join public.instructor i on i.id = k.instructor_id
                where k.module_id = m.id and k.cohort_id is null and i.status = 'Active')
              < private.setting_int(m.id, 'min_active_instructors'))),
    jsonb_build_object('key', 'owners', 'label', 'Choose an owner for every module', 'link', '/setup/modules',
      'done', exists (select 1 from mods) and not exists (select 1 from mods m where not exists (select 1 from public.module_owner o where o.module_id = m.id))),
    jsonb_build_object('key', 'operations', 'label', 'Choose the operations team', 'link', '/setup/domains',
      'done', cardinality(private.domain_role_ids(p_domain_id, 'Operations')) > 0
              or (exists (select 1 from mods) and not exists (select 1 from mods m where not exists (select 1 from public.module_operations o where o.module_id = m.id)))),
    jsonb_build_object('key', 'escalation', 'label', 'Choose escalation contacts', 'link', '/setup/domains',
      'done', cardinality(private.domain_role_ids(p_domain_id, 'Escalation')) > 0),
    jsonb_build_object('key', 'alert_channel', 'label', 'Add the alert channel for the team', 'link', '/setup/domains',
      'done', (select alert_discord_channel_id is not null from d)),
    jsonb_build_object('key', 'testing', 'label', 'Turn on testing', 'link', '/settings/testing',
      'done', (select status in ('Test', 'Live') or paused_from = 'Test' from d)))
  where private.is_team_user() or private.is_service();
$$;

-- public.save_standard_schedule: B9: modules are Live or Draft (was 20261122000013_standard_fixes.sql).
create or replace function public.save_standard_schedule(p_id uuid, p_domain_id uuid, p_name text, p_module_ids uuid[],
  p_breaks jsonb default '[]', p_notes text default null, p_expected_version int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  s public.standard_schedule;
  v_name text := trim(coalesce(p_name, ''));
  v_n int := coalesce(cardinality(p_module_ids), 0);
  b jsonb;
  v_after int[] := '{}';
  i int;
  v_changed boolean := false;
begin
  perform private.require_team();
  if p_id is not null then
    select * into s from public.standard_schedule where id = p_id for update;
    if s.id is null then raise exception 'This standard schedule no longer exists.' using errcode = '22023'; end if;
    if p_expected_version is not null and s.version <> p_expected_version then
      raise exception 'Someone else saved this standard schedule after you opened it. Reload the page to see their changes, then try again.' using errcode = '40001';
    end if;
  elsif not exists (select 1 from public.domain where id = p_domain_id) then
    raise exception 'Choose a domain.' using errcode = '22023';
  end if;
  if v_name = '' then raise exception 'Give the standard schedule a name.' using errcode = '22023'; end if;
  if exists (select 1 from public.standard_schedule x where x.domain_id = coalesce(s.domain_id, p_domain_id)
              and lower(x.name) = lower(v_name) and x.id is distinct from p_id) then
    raise exception 'This domain already has a standard schedule named %.', v_name using errcode = '23505';
  end if;
  if v_n = 0 then raise exception 'Add at least one module to the standard schedule.' using errcode = '22023'; end if;
  if (select count(distinct x) from unnest(p_module_ids) x) <> v_n then
    raise exception 'Each module can be in a standard schedule once.' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_module_ids) x left join public.module m on m.id = x
              where m.id is null or m.domain_id <> coalesce(s.domain_id, p_domain_id) or m.status <> 'Active') then
    raise exception 'Only live modules of this domain can be in its standard schedules.' using errcode = '22023';
  end if;
  for b in select * from jsonb_array_elements(coalesce(p_breaks, '[]')) loop
    if coalesce((b ->> 'after_position')::int, 0) not between 1 and v_n - 1 then
      raise exception 'A break goes between two modules of the standard schedule.' using errcode = '22023';
    end if;
    if coalesce((b ->> 'weeks')::int, 0) not between 1 and 8 then
      raise exception 'A break lasts 1 to 8 weeks.' using errcode = '22023';
    end if;
    if (b ->> 'after_position')::int = any (v_after) then
      raise exception 'There is already a break after module %.', b ->> 'after_position' using errcode = '22023';
    end if;
    v_after := v_after || (b ->> 'after_position')::int;
  end loop;

  if s.id is null then
    insert into public.standard_schedule (domain_id, name, notes) values (p_domain_id, v_name, nullif(trim(coalesce(p_notes, '')), ''))
    returning * into s;
  elsif s.name is distinct from v_name or s.notes is distinct from nullif(trim(coalesce(p_notes, '')), '') then
    update public.standard_schedule set name = v_name, notes = nullif(trim(coalesce(p_notes, '')), '') where id = s.id returning * into s;
  end if;
  -- Only what changed is saved, so Activity history shows only real changes.
  if array(select module_id from public.standard_schedule_module where schedule_id = s.id order by position) is distinct from p_module_ids then
    delete from public.standard_schedule_module where schedule_id = s.id;
    -- A module taken out of the standard takes its class times with it.
    delete from public.standard_schedule_class where schedule_id = s.id and module_id <> all (p_module_ids);
    v_changed := true;
    for i in 1 .. v_n loop
      insert into public.standard_schedule_module (schedule_id, module_id, position) values (s.id, p_module_ids[i], i);
    end loop;
  end if;
  if (select coalesce(jsonb_agg(jsonb_build_object('after_position', after_position, 'weeks', weeks) order by after_position), '[]')
        from public.standard_schedule_break where schedule_id = s.id)
     is distinct from
     (select coalesce(jsonb_agg(jsonb_build_object('after_position', (x ->> 'after_position')::int, 'weeks', (x ->> 'weeks')::int)
                                order by (x ->> 'after_position')::int), '[]')
        from jsonb_array_elements(coalesce(p_breaks, '[]')) x) then
    delete from public.standard_schedule_break where schedule_id = s.id;
    v_changed := true;
    insert into public.standard_schedule_break (schedule_id, after_position, weeks)
    select s.id, (x ->> 'after_position')::int, (x ->> 'weeks')::int from jsonb_array_elements(coalesce(p_breaks, '[]')) x;
  end if;
  -- Any change to the order or the breaks is a new version too, so two people editing at once are told.
  if v_changed then update public.standard_schedule set updated_at = now() where id = s.id; end if;
  return jsonb_build_object('id', s.id, 'version', (select version from public.standard_schedule where id = s.id));
end;
$$;

-- private.template_defaults: B7: the welcome message (M22) (was 20261122000015_time_proposals.sql).
create or replace function private.template_defaults()
returns jsonb language sql immutable set search_path = ''
as $$
  select jsonb_build_object(
    'M1', jsonb_build_object('name', 'Request to teach', 'subject', 'Can you teach {module}? ({first_class})',
      'body', E'Hi {first_name},\n\nCan you teach {module} for the {domain} cohort?\n\n{classes}\n\nPlease reply by {deadline}.',
      'required', jsonb_build_array('module', 'classes', 'deadline')),
    'M2', jsonb_build_object('name', 'Reminder about the request', 'subject', 'Reminder: can you teach {module}?',
      'body', E'Hi {first_name},\n\nA friendly reminder: can you teach {module} for the {domain} cohort?\n\n{classes}\n\nPlease reply by {deadline}.',
      'required', jsonb_build_array('module', 'classes', 'deadline')),
    'M3', jsonb_build_object('name', 'Request closed', 'subject', '{module}: no worries',
      'body', 'No worries. We will check with you next time. (We have closed the request for {module}.)',
      'required', jsonb_build_array('module')),
    'M4', jsonb_build_object('name', 'Confirmation', 'subject', 'You are confirmed for {module} 🎉',
      'body', E'Thank you, {first_name}. You are confirmed for {module} 🎉\n\n{classes}{help}\n\nYour contact: {contact}',
      'required', jsonb_build_array('module', 'classes')),
    'M5', jsonb_build_object('name', 'Class time change', 'subject', '{module} moved: does this still work?',
      'body', E'{module} moved to new times:\n\n{classes}\n\nDoes this still work?{reply_by}',
      'required', jsonb_build_array('module', 'classes')),
    'M6', jsonb_build_object('name', 'Reminder before class', 'subject', '{module} is in {days} days: all set?',
      'body', E'{module} is {days} days away ({first_class}). Anything you need?\n\n{classes}{help}',
      'required', jsonb_build_array('module', 'classes')),
    'M7', jsonb_build_object('name', 'Final reminder before class', 'subject', '{module} is on {weekday}',
      'body', E'{module} is on {first_class}.\n\n{classes}{help}\n\nAll set?',
      'required', jsonb_build_array('module', 'classes')),
    'M8', jsonb_build_object('name', 'Early reminder before class', 'subject', '{module} in {days} days: how is your prep going?',
      'body', E'{module} is {days} days away ({first_class}). How is your prep going?\n\n{classes}',
      'required', jsonb_build_array('module', 'classes')),
    'M9', jsonb_build_object('name', 'Follow up reminder', 'subject', 'Reminder: {module} is coming up',
      'body', 'A quick reminder: {module} is coming up ({first_class}). Please let us know you are all set.',
      'required', jsonb_build_array('module')),
    'M10', jsonb_build_object('name', 'Cancellation received', 'subject', '{module}: thanks for letting us know',
      'body', 'Thanks for letting us know. We will take it from here.', 'required', '[]'::jsonb),
    'M11', jsonb_build_object('name', 'Class cancelled', 'subject', '{module}: class cancelled',
      'body', E'We are sorry, we have had to cancel {what}:\n\n{classes}\n\nThank you for your flexibility. Nothing else is needed from you.',
      'required', jsonb_build_array('classes')),
    'M12', jsonb_build_object('name', 'Request withdrawn', 'subject', '{module}: no longer needed',
      'body', 'Thanks. This one is no longer needed ({module}). No action required.', 'required', jsonb_build_array('module')),
    'M13', jsonb_build_object('name', 'Help request received', 'subject', '{module}: help request received',
      'body', 'Got it. {helper} will reply by {by}.', 'required', jsonb_build_array('helper', 'by')),
    'M14', jsonb_build_object('name', 'Reply to a help request', 'subject', '{module}: reply to your help request',
      'body', E'{text}\n\nFrom {from}', 'required', jsonb_build_array('text')),
    'M15', jsonb_build_object('name', 'Contact check', 'subject', 'Test message from SME Scheduling',
      'body', 'This is a test from SME Scheduling. Please tap the button to confirm you received it.', 'required', '[]'::jsonb),
    'M16', jsonb_build_object('name', 'Release note', 'subject', '{module}: thank you',
      'body', E'Thank you for being ready to teach {module}. Plans have changed, so you are no longer needed for these classes:\n\n{classes}\n\nNothing else is needed from you. We hope to work with you again soon.',
      'required', jsonb_build_array('module', 'classes')),
    'M17', jsonb_build_object('name', 'Classes moved for a break', 'subject', 'Your classes moved: do they still work?',
      'body', E'{text}

{classes}

Do these still work? Answer for each class week with the buttons.{reply_by}',
      'required', jsonb_build_array('classes')),
    'M18', jsonb_build_object('name', 'Proposed time received', 'subject', '{module}: we got your proposed time',
      'body', 'Thanks for proposing another time for {module}. The team checks it with the cohort and replies to you soon. Until then, nothing changes.',
      'required', jsonb_build_array('module')),
    'M19', jsonb_build_object('name', 'Proposed time accepted', 'subject', '{module}: your proposed time is accepted',
      'body', E'Good news: {module} moved to the time you proposed, and you stay confirmed.\n\n{classes}{help}',
      'required', jsonb_build_array('module', 'classes')),
    'M20', jsonb_build_object('name', 'Proposed time not possible', 'subject', '{module}: we kept the original time',
      'body', E'Thanks for proposing another time for {module}. We could not move the class, so the time stays:\n\n{classes}{text}\n\nPlease answer with the buttons below.{reply_by}',
      'required', jsonb_build_array('module', 'classes')),
    'M22', jsonb_build_object('name', 'Welcome', 'subject', 'Welcome to SME Scheduling',
      'body', E'You are set up to receive class requests from SME Scheduling.\n\nWhen we ask you to teach, answer with the buttons in the message.',
      'required', '[]'::jsonb));
$$;

-- private.render_instructor: B7: a message about a domain without a class week (the welcome) uses the domain's own text (was 20261113000007_no_materials.sql).
create or replace function private.render_instructor(p_template text, p_mw uuid, p_instructor uuid, p_extra jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_name text;
  v_dom uuid;
  v_vars jsonb;
  v_first timestamptz;
  v_materials text := '';
  v_def jsonb := private.template_defaults() -> p_template;
  v_custom public.message_template;
  v_subject text;
  v_body text;
begin
  if v_def is null then raise exception 'Unknown instructor template %', p_template; end if;
  select i.full_name into v_name from public.instructor i where i.id = p_instructor;
  v_vars := jsonb_build_object('first_name', private.first_name(v_name), 'name', v_name);
  if p_mw is not null then
    select w.domain_id, w.first_class_at into v_dom, v_first from public.module_week w where w.id = p_mw;
    v_materials := private.materials_line(p_mw);
    v_vars := v_vars || (select jsonb_build_object(
        'module', m.name, 'domain', d.name, 'classes', private.class_lines(p_mw),
        'first_class', private.fmt_local(v_first, private.week_region(p_mw)),
        'weekday', to_char(v_first at time zone private.region_tz(private.week_region(p_mw)), 'FMDay'),
        'contact', private.team_names(private.owners_or_leads(m.id)),
        -- No materials in instructor messages: one line on where to get help instead. {materials} in a
        -- template saved before gives the same line.
        'help', E'\n\nNeed anything before class? Press Need help below or reply to this message, and '
          || coalesce(nullif(private.team_names(private.owners_or_leads(m.id)), ''), 'the team') || ' will help you.',
        'materials', E'\n\nNeed anything before class? Press Need help below or reply to this message, and '
          || coalesce(nullif(private.team_names(private.owners_or_leads(m.id)), ''), 'the team') || ' will help you.')
      from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id
     where w.id = p_mw);
  end if;
  -- The welcome message has a domain but no class week.
  if p_mw is null and nullif(p_extra ->> 'domain_id', '') is not null then
    v_dom := (p_extra ->> 'domain_id')::uuid;
  end if;
  v_vars := v_vars || jsonb_build_object(
    'deadline', coalesce(p_extra ->> 'deadline', ''),
    'reply_by', case when p_extra ->> 'deadline' is not null then E'\nPlease reply by ' || (p_extra ->> 'deadline') || '.' else '' end,
    'days', coalesce(p_extra ->> 'days', ''),
    'what', coalesce(p_extra ->> 'what', v_vars ->> 'module', ''),
    'helper', coalesce(p_extra ->> 'helper', ''),
    'by', coalesce(p_extra ->> 'by', ''),
    'text', coalesce(p_extra ->> 'text', ''),
    'from', coalesce(p_extra ->> 'from', ''));
  if p_extra ? 'classes' then v_vars := v_vars || jsonb_build_object('classes', p_extra ->> 'classes'); end if;
  if not v_vars ? 'module' then v_vars := v_vars || jsonb_build_object('module', 'SME Scheduling',
    'domain', coalesce((select d.name from public.domain d where d.id = v_dom), ''), 'classes', '',
    'first_class', '', 'weekday', '', 'contact', '', 'help', '', 'materials', ''); end if;
  if v_dom is not null then
    select * into v_custom from public.message_template where domain_id = v_dom and template_id = p_template;
  end if;
  v_subject := private.fill_template(coalesce(v_custom.subject, v_def ->> 'subject'), v_vars);
  v_body := private.fill_template(coalesce(v_custom.body, v_def ->> 'body'), v_vars);
  -- The message adds its own greeting ("Hi Maya 👋" on Discord, "Hi Maya," by email), so a greeting the
  -- template starts with is dropped instead of showing twice.
  v_body := regexp_replace(v_body, '^\s*(hi|hello|dear)\s[^\n]{0,60},[ \t]*\n+', '', 'i');
  return jsonb_build_object('subject', private.plain_message_text(v_subject), 'body', private.plain_message_text(v_body),
    'first_name', private.first_name(v_name), 'name', v_name);
end;
$$;

-- private.queue_instructor_message: B7: a message about a domain without a class week (the welcome) goes by that domain's rules (was 20261113000006_demo_messages.sql).
create or replace function private.queue_instructor_message(
  p_template text,
  p_instructor uuid,
  p_mw uuid,
  p_request uuid,
  p_now timestamptz,
  p_buttons jsonb default '[]',
  p_extra jsonb default '{}',
  p_urgent boolean default false,
  p_key_suffix text default '',
  p_help_request uuid default null,
  p_only_channel text default null
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  d public.domain;
  v_domain uuid;
  v_channels text;
  v_r jsonb;
  v_tv int;
  v_send timestamptz;
  v_test boolean;
  v_prefix text := '';
  v_count int := 0;
  v_n int;
  v_ch text;
  v_key text;
  v_text text;
  v_html text;
  v_btn_html text;
  v_chan text;
  v_team text[] := '{}';
  v_dm boolean;
  v_targets text[];
  v_t text;
begin
  select * into i from public.instructor where id = p_instructor;
  if p_mw is not null then
    select w.domain_id, w.time_version into v_domain, v_tv from public.module_week w where w.id = p_mw;
  end if;
  if p_request is not null then
    select r.time_version into v_tv from public.request r where r.id = p_request;
  end if;
  -- The welcome message has a domain but no class week.
  if v_domain is null and p_mw is null and nullif(p_extra ->> 'domain_id', '') is not null then
    v_domain := (p_extra ->> 'domain_id')::uuid;
  end if;
  select * into d from public.domain where id = v_domain;
  -- The instructor's channel in this domain (Release 2: one channel per domain).
  -- A message without a domain (the contact check) uses the instructor's first channel.
  v_chan := (select ic.channel_id from public.instructor_channel ic
              where ic.instructor_id = p_instructor and (ic.domain_id = v_domain or v_domain is null)
              order by ic.created_at limit 1);
  v_test := private.is_test_domain(d.id);
  v_channels := 'Both';
  v_r := private.render_instructor(p_template, p_mw, p_instructor, p_extra);
  if v_test then
    v_prefix := '[TEST → would go to ' || i.full_name || '] ';
  end if;
  v_send := private.instructor_send_time(coalesce(p_mw, v_domain), p_now, p_urgent, coalesce(private.week_region(p_mw), 'US'));

  select coalesce(string_agg(format('<a href="%s" style="display:inline-block;margin:4px 8px 4px 0;padding:10px 16px;background:#1f6feb;color:#fff;border-radius:6px;text-decoration:none;font-weight:600">%s</a>',
                                    private.html_escape(b ->> 'url'), private.html_escape(b ->> 'label')), ''), '')
    into v_btn_html from jsonb_array_elements(p_buttons) b;

  -- Where the Discord copy goes: the test channel (testing), the instructor's channel, or a direct message.
  v_dm := not v_test and v_chan is null and i.discord_user_id is not null;
  -- The confirmation tags every owner and the operations team in the instructor's channel.
  if p_template = 'M4' and p_mw is not null and not v_test then
    v_team := private.team_discord_ids(array(select distinct x from unnest(
      private.owners_or_leads((select w.module_id from public.module_week w where w.id = p_mw))
      || private.ops_for_week(p_mw)) x));
  end if;
  -- Each person is tagged once: the instructor is tagged in the greeting, so the team list leaves them out,
  -- and someone who is both owner and operations appears once.
  v_team := array(select x from unnest(v_team) with ordinality t(x, o)
                   where x is distinct from i.discord_user_id group by x order by min(o));
  -- Discord, email, and for a confirmation in a channel also a direct message to the instructor.
  v_targets := array['Discord', 'Email'];
  if p_template = 'M4' and not v_test and v_chan is not null and i.discord_user_id is not null then
    v_targets := array['Discord', 'DM', 'Email'];
  end if;

  foreach v_t in array v_targets loop
    v_ch := case v_t when 'DM' then 'Discord' else v_t end;
    continue when p_only_channel is not null and v_ch <> p_only_channel;
    continue when v_ch = 'Discord' and v_channels = 'EmailOnly';
    continue when v_ch = 'Email' and v_channels = 'DiscordOnly';
    continue when v_t = 'Discord' and not v_test and v_chan is null and not v_dm;
    continue when v_ch = 'Email' and not v_test and coalesce(i.primary_email, '') = '';
    v_key := p_template || ':' || coalesce(p_request::text, coalesce(p_mw::text, '-') || ':' || p_instructor::text)
             || ':' || coalesce(v_tv, 0) || ':' || v_t || coalesce(nullif(':' || p_key_suffix, ':'), '');
    if v_ch = 'Discord' then
      v_text := v_prefix || 'Hi ' ||
                case when i.discord_user_id is not null and (not v_test or i.is_test) then '<@' || i.discord_user_id || '>'
                     else (v_r ->> 'first_name') end
                || ' 👋 ' || (v_r ->> 'body')
                || case when v_t = 'Discord' and not v_dm and not v_test and cardinality(v_team) > 0
                        then E'

Team: ' || (select string_agg('<@' || x || '>', ' ') from unnest(v_team) x) else '' end;
      v_html := null;
    else
      v_text := v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')
                || case when jsonb_array_length(p_buttons) > 0 then E'\n\n' ||
                     (select string_agg((b ->> 'label') || ': ' || (b ->> 'url'), E'\n') from jsonb_array_elements(p_buttons) b) else '' end
                || E'\n\nThanks,\nSME Scheduling';
      v_html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#1f2328">'
                || replace(private.html_escape(v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')), E'\n', '<br>')
                || case when v_btn_html <> '' then '<p style="margin-top:16px">' || v_btn_html || '</p>' else '' end
                || '<p style="color:#59636e;font-size:13px">Thanks,<br>SME Scheduling</p></div>';
    end if;
    insert into public.message (
      domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id, module_week_id,
      request_id, help_request_id, recipient_label, to_address, discord_channel_id, discord_dm_user_id, mention_user_ids, subject,
      body_text, body_html, buttons, is_test)
    values (
      v_domain, 'Instructor', p_template, v_ch, v_key,
      case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, p_instructor, p_mw,
      p_request, p_help_request, i.full_name,
      case when v_ch = 'Email' then case when v_test then d.test_email else i.primary_email end end,
      case when v_t = 'Discord' then case when v_test then d.test_discord_channel_id when v_dm then null else v_chan end end,
      case when v_t = 'DM' or (v_t = 'Discord' and v_dm) then i.discord_user_id end,
      case when v_ch = 'Discord'
           then case when i.discord_user_id is not null and (not v_test or i.is_test) then array[i.discord_user_id] else '{}'::text[] end
                || case when v_t = 'Discord' and not v_dm and not v_test then v_team else '{}'::text[] end
           else '{}' end,
      v_prefix || (v_r ->> 'subject'), v_text, v_html, p_buttons, v_test)
    on conflict (unique_key) where unique_key is not null do nothing;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
  end loop;
  return v_count;
end;
$$;

-- private.send_welcome: new. Queues the welcome message for one instructor on one channel ('Discord' in the
-- instructor's channel of p_domain, or 'Email'), unless it is switched off or was already sent, and logs what
-- happened. Returns 'sent', 'blocked: <reason>', 'off', 'already sent' or why nothing was queued.
create or replace function private.send_welcome(p_instructor uuid, p_domain uuid, p_channel text)
returns text language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_base text;
  v_suffix text;
  v_tries int;
  m public.message;
begin
  if p_channel not in ('Discord', 'Email') then
    raise exception 'A welcome message goes by Discord or by email.' using errcode = '22023';
  end if;
  select * into i from public.instructor where id = p_instructor;
  if i.id is null or i.status <> 'Active' then return 'not in use'; end if;
  if not private.setting_bool(p_domain, 'welcome_message') then return 'off'; end if;
  if p_channel = 'Email' and coalesce(i.primary_email, '') = '' then return 'no email'; end if;
  if p_channel = 'Discord' and not exists (select 1 from public.instructor_channel c
                                             where c.instructor_id = p_instructor and c.domain_id = p_domain) then
    return 'no channel';
  end if;
  -- One per instructor and channel: on Discord once for each domain, by email once. The key is the one
  -- private.queue_instructor_message gives a message without a class week.
  perform 1 from public.instructor where id = p_instructor for update;
  v_base := 'M22:-:' || p_instructor || ':0:' || p_channel || ':'
    || case when p_channel = 'Email' then 'welcome' else p_domain::text end;
  if exists (select 1 from public.message x where (x.unique_key = v_base or x.unique_key like v_base || ':%')
               and x.status <> 'Cancelled') then
    return 'already sent';
  end if;
  -- One that was blocked (by the beta list, for example) may go once the reason is gone.
  select count(*) into v_tries from public.message x where x.unique_key = v_base or x.unique_key like v_base || ':%';
  v_suffix := case when p_channel = 'Email' then 'welcome' else p_domain::text end
    || case when v_tries > 0 then ':' || v_tries else '' end;
  perform private.queue_instructor_message('M22', p_instructor, null, null, now(), '[]',
    jsonb_build_object('domain_id', p_domain), false, v_suffix, null, p_channel);
  select * into m from public.message x
   where x.unique_key = 'M22:-:' || p_instructor || ':0:' || p_channel || ':' || v_suffix;
  if m.id is null then return 'not queued'; end if;
  if m.status = 'Cancelled' then
    perform private.log_event('Messages', 'Welcome message to ' || i.full_name || ' blocked', 'instructor', p_instructor,
      null, jsonb_build_object('channel', p_channel), m.last_error, p_domain, null, null, null, p_instructor, null,
      coalesce(m.is_test, false));
    return 'blocked: ' || coalesce(m.last_error, '');
  end if;
  perform private.queue_deliver('welcome message');
  perform private.log_event('Messages', 'Welcome message sent to ' || i.full_name, 'instructor', p_instructor,
    null, jsonb_build_object('channel', p_channel),
    case when p_channel = 'Email' then 'By email' else 'On Discord' end
      || case when m.is_test then ', to the testing ' || case when p_channel = 'Email' then 'email' else 'channel' end else '' end
      || case when m.status = 'Scheduled' then ', after quiet hours' else '' end || '.',
    p_domain, null, null, null, p_instructor, null, coalesce(m.is_test, false));
  return 'sent';
end;
$$;
revoke execute on function private.send_welcome(uuid, uuid, text) from public, anon, authenticated;

-- public.send_welcome_message: new. The app calls it after adding an instructor: the welcome by email, with the
-- rules and text of the domain the team member is working in.
create or replace function public.send_welcome_message(p_instructor_id uuid, p_domain_id uuid default null)
returns text language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if not exists (select 1 from public.instructor where id = p_instructor_id) then
    raise exception 'Instructor not found.' using errcode = '22023';
  end if;
  return private.send_welcome(p_instructor_id, p_domain_id, 'Email');
end;
$$;
revoke execute on function public.send_welcome_message(uuid, uuid) from public, anon;
grant execute on function public.send_welcome_message(uuid, uuid) to authenticated, service_role;

-- public.set_instructor_channel: B7: the first channel in a domain sends the welcome message (was 20261122000006_security_data_findings.sql).
create or replace function public.set_instructor_channel(p_instructor_id uuid, p_domain_id uuid, p_channel_id text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  c public.discord_channel;
begin
  perform private.require_team();
  if p_channel_id is null then
    delete from public.instructor_channel where instructor_id = p_instructor_id and domain_id = p_domain_id;
    return;
  end if;
  select * into c from public.discord_channel where id = p_channel_id;
  if c.id is null then
    raise exception 'That channel is not in the list. Press Refresh channels on Connections, then choose again.' using errcode = '22023';
  end if;
  if exists (select 1 from public.domain d where p_channel_id in (d.alert_discord_channel_id, d.test_discord_channel_id))
     or p_channel_id = (select a.admin_discord_channel_id from public.app_config a where a.id = 1) then
    raise exception '#% is an alert or testing channel. Choose the instructor''s own channel.', c.name using errcode = '22023';
  end if;
  if not private.server_allowed(c.server_id, p_domain_id) then
    raise exception 'An admin must approve the Discord server of #% for this domain first (Settings, Connections).', c.name
      using errcode = '22023';
  end if;
  if c.bot_can_post = false then
    raise exception 'The bot cannot post in #%. Give the bot''s role View Channels and Send Messages there, press Check on Connections, then choose it again.', c.name
      using errcode = '22023';
  end if;
  if exists (select 1 from public.instructor_channel x join public.instructor i on i.id = x.instructor_id
              where x.domain_id = p_domain_id and x.channel_id = p_channel_id and x.instructor_id <> p_instructor_id and i.status = 'Active') then
    raise exception '#% is already the channel of %. Each instructor needs their own channel, so nobody else can answer for them.',
      c.name, (select i.full_name from public.instructor_channel x join public.instructor i on i.id = x.instructor_id
                where x.domain_id = p_domain_id and x.channel_id = p_channel_id and x.instructor_id <> p_instructor_id limit 1)
      using errcode = '22023';
  end if;
  insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name)
  values (p_instructor_id, p_domain_id, c.id, c.name)
  on conflict (instructor_id, domain_id) do update set channel_id = excluded.channel_id, channel_name = excluded.channel_name;
  -- A new channel needs a new contact check.
  update public.instructor set verified_at = null, discord_failed_at = null, version = version
   where id = p_instructor_id and verified_at is not null;
  -- B7: a short welcome in the new channel, once per instructor and domain.
  perform private.send_welcome(p_instructor_id, p_domain_id, 'Discord');
end;
$$;
