-- The demo data set (scripts/src/demo-load.ts, docs/DEMO_SCRIPT.md). A temporary function: it exists only while the
-- command runs, so nothing is added to the database schema. Runs right after Reset Sandbox data.
create or replace function pg_temp.demo_load(p_me uuid, p_server text, p_alerts text, p_chan_a text, p_chan_b text,
  p_chan_c text, p_discord_id text, p_discord_username text, p_mailbox text)
returns jsonb language plpgsql set search_path = ''
as $$
declare
  v_local text := split_part(p_mailbox, '@', 1);
  v_mail text := split_part(p_mailbox, '@', 2);
  v_dom uuid; v_us uuid; v_in uuid; v_mod uuid; v_first uuid;
  v_inst uuid[] := '{}'; v_i uuid;
  v_chans text[] := array[p_chan_a, p_chan_b, p_chan_c];
  v_start date; v_rows jsonb; n_weeks int := 0;
  k int; m record;
begin
  -- First Saturday at least 35 days from now (Pacific): outside the 30 day asking window, so nothing is asked
  -- on its own before the demo, and "Start asking now" asks at once.
  v_start := (now() at time zone 'America/Los_Angeles')::date + 35;
  v_start := v_start + ((6 - extract(dow from v_start)::int + 7) % 7);

  insert into public.domain (name, status, alert_discord_channel_id, test_email, discord_server_id)
  values ('Backend', 'Live', p_alerts, lower(v_local || '+testing@' || v_mail), p_server)
  returning id into v_dom;
  insert into public.domain_team (domain_id, team_member_id, role)
  values (v_dom, p_me, 'Operations'), (v_dom, p_me, 'Escalation');
  insert into public.cohort (domain_id, name, start_date, status, region)
  values (v_dom, 'US cohort', v_start, 'Running', 'US') returning id into v_us;
  insert into public.cohort (domain_id, name, start_date, status, region)
  values (v_dom, 'India cohort', v_start, 'Running', 'India') returning id into v_in;

  for k in 1 .. 3 loop
    insert into public.instructor (full_name, primary_email, discord_user_id, discord_username, discord_server_id,
                                   is_test, verified_at, notes)
    values ((array['Maya Rao', 'Arjun Mehta', 'Sara Lee'])[k], lower(v_local || '+instructor-' || chr(96 + k) || '@' || v_mail),
            -- Test instructors: the Sandbox only ever contacts these (migration 20261113000004 lets a Live
            -- Sandbox domain ask them). They use your Discord account and the B2C plus addresses.
            -- Only the Discord ID: saving a username clears the ID until n8n looks the name up again.
            p_discord_id, null, p_server, true, now(), 'Demo test instructor on the B2C mailbox.')
    returning id into v_i;
    v_inst := v_inst || v_i;
    insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name)
    values (v_i, v_dom, v_chans[k], 'test-instructor-' || chr(96 + k));
  end loop;

  for m in select * from (values (1, 'Concurrency', 'https://yourcompany.com/demo/concurrency'),
                                 (2, 'API Design', 'https://yourcompany.com/demo/api-design')) x(n, name, link) loop
    insert into public.module (domain_id, name, rotation_order) values (v_dom, m.name, m.n) returning id into v_mod;
    if m.n = 1 then v_first := v_mod; end if;
    insert into public.module_owner (module_id, team_member_id) values (v_mod, p_me);
    insert into public.module_operations (module_id, team_member_id) values (v_mod, p_me);
    -- US cohort (module default, Pacific): Saturday live class, Sunday assignment review.
    insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
    values (v_mod, 'Live class', '{module}: Live class', 0, '09:00', 180, 1),
           (v_mod, 'Assignment review', '{module}: Assignment review', 1, '10:00', 90, 2);
    -- India cohort (IST): Saturday and Sunday mornings India time.
    insert into public.class_pattern_item (module_id, cohort_id, class_type, title_template, day_offset, start_time, duration_minutes, sort_order)
    values (v_mod, v_in, 'Live class', '{module}: Live class', 0, '10:00', 180, 1),
           (v_mod, v_in, 'Assignment review', '{module}: Assignment review', 1, '11:00', 90, 2);
    insert into public.module_ranking (module_id, instructor_id, rank)
    select v_mod, v_inst[j], j from generate_series(1, 3) j;
  end loop;

  v_rows := public.generate_classes(v_dom, v_first, array(select v_start + 7 * j from generate_series(0, 3) j), 'US cohort', 'US');
  n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Demo data') ->> 'created')::int, 0);
  v_rows := public.generate_classes(v_dom, v_first, array(select v_start + 7 * j from generate_series(0, 3) j), 'India cohort', 'India');
  n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Demo data') ->> 'created')::int, 0);

  -- Start reading the instructors' channels from now, so messages typed there before (a rehearsal) are not
  -- picked up as new replies during the demo. A Discord message ID holds its time: (ms since 2015) << 22.
  insert into public.discord_cursor (channel_id, last_message_id)
  select c, (((extract(epoch from now()) * 1000)::bigint - 1420070400000) << 22)::text from unnest(v_chans) c
  on conflict (channel_id) do update set last_message_id = excluded.last_message_id, updated_at = now();

  perform private.log_event('System', 'Demo data loaded', null, null, null,
    jsonb_build_object('domain', 'Backend', 'modules', 2, 'class_weeks', n_weeks, 'test_instructors', 3));
  return jsonb_build_object('class_weeks', n_weeks, 'first_class', v_start, 'test_instructors', 3);
end;
$$;
