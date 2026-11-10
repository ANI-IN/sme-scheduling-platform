-- Release Milestone 7: Sandbox and Production.
-- Each environment has its own Supabase project. The database knows which one it is
-- (app_config.environment, written by `npm run configure -w scripts`) and enforces two hard rules
-- on every outgoing message, whatever any workflow does:
--   * Production never messages test instructors.
--   * Sandbox only sends to Discord servers and email domains on its allow lists.
-- Sandbox data can be reset to a known starting point; Activity history is never deleted.

alter table public.app_config add column sandbox_allowed_discord_servers text[] not null default '{}';
alter table public.app_config add column sandbox_allowed_email_domains text[] not null default '{}';

-- -------------------------------------------------------------------------------------
-- The guard on every outgoing message
-- -------------------------------------------------------------------------------------
create or replace function private.message_block_reason(m public.message)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  c public.app_config;
  i public.instructor;
  v_server text;
  v_domain text;
begin
  if m.direction <> 'Outbound' then return null; end if;
  select * into c from public.app_config where id = 1;
  if m.instructor_id is not null then
    select * into i from public.instructor where id = m.instructor_id;
  end if;
  if c.environment = 'Production' and m.audience = 'Instructor' and coalesce(i.is_test, false) then
    return 'Production never messages test instructors.';
  end if;
  if c.environment = 'Sandbox' then
    if m.channel = 'Email' then
      v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
      if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.sandbox_allowed_email_domains) x))) then
        return 'Sandbox only sends email to allowed domains. ' || coalesce(nullif(v_domain, ''), 'This address') || ' is not on the list.';
      end if;
    elsif m.channel = 'Discord' then
      -- An instructor's own channel is in their server; everything else is in the company server.
      v_server := case when i.id is not null and m.discord_channel_id is not distinct from i.discord_channel_id
                         and i.discord_server_id is not null then i.discord_server_id
                       else c.discord_guild_id end;
      if v_server is null or not (v_server = any (c.sandbox_allowed_discord_servers)) then
        return 'Sandbox only posts to allowed Discord servers. ' || coalesce('Server ' || v_server, 'This server') || ' is not on the list.';
      end if;
    end if;
  end if;
  return null;
end;
$$;

create or replace function private.message_environment_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_reason text;
begin
  if new.status not in ('Scheduled', 'Pending', 'Sending') then return new; end if;
  v_reason := private.message_block_reason(new);
  if v_reason is not null then
    new.status := 'Cancelled';
    new.last_error := v_reason;
    perform private.log_event('Messages', 'Message blocked', 'message', new.id, null,
      jsonb_build_object('template', new.template_id, 'channel', new.channel, 'to', coalesce(new.recipient_label, new.to_address)),
      v_reason, new.domain_id, null, new.module_week_id, null, new.instructor_id, null, coalesce(new.is_test, false));
  end if;
  return new;
end;
$$;
create trigger message_environment_guard before insert or update of status, to_address, discord_channel_id on public.message
  for each row execute function private.message_environment_guard();

-- -------------------------------------------------------------------------------------
-- Environment settings, from the setup script
-- -------------------------------------------------------------------------------------
drop function public.configure_environment(text, text);
create or replace function public.configure_environment(p_environment text, p_allowed_email_domain text,
  p_sandbox_discord_servers text[] default null, p_sandbox_email_domains text[] default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_service() then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_environment not in ('Development', 'Sandbox', 'Production') then
    raise exception 'The environment must be Development, Sandbox or Production.' using errcode = '22023';
  end if;
  if coalesce(trim(p_allowed_email_domain), '') !~ '^[a-z0-9.-]+\.[a-z]{2,}$' then
    raise exception 'The allowed email domain should look like yourcompany.com.' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(p_sandbox_discord_servers, '{}')) x where x !~ '^\d{17,20}$') then
    raise exception 'Each allowed Discord server ID is 17 to 20 digits.' using errcode = '22023';
  end if;
  update public.app_config
     set environment = p_environment,
         company_email_domain = lower(trim(p_allowed_email_domain)),
         sandbox_allowed_discord_servers = coalesce(p_sandbox_discord_servers, sandbox_allowed_discord_servers),
         sandbox_allowed_email_domains = coalesce(array(select lower(trim(x)) from unnest(p_sandbox_email_domains) x where trim(x) <> ''),
                                                  sandbox_allowed_email_domains)
   where id = 1;
  perform private.log_event('System', 'Environment set to ' || p_environment, 'app_config', null, null,
    jsonb_build_object('environment', p_environment, 'allowed_email_domain', lower(trim(p_allowed_email_domain)),
      'sandbox_allowed_discord_servers', to_jsonb(coalesce(p_sandbox_discord_servers, '{}')),
      'sandbox_allowed_email_domains', to_jsonb(coalesce(p_sandbox_email_domains, '{}'))));
end;
$$;
revoke execute on function public.configure_environment(text, text, text[], text[]) from anon, authenticated, public;
grant execute on function public.configure_environment(text, text, text[], text[]) to service_role;

-- -------------------------------------------------------------------------------------
-- Sandbox starting data
-- -------------------------------------------------------------------------------------
-- Backend and Fullstack in testing, a weekend cohort and a weekday cohort at the same time, test
-- instructors (sharing one Discord user ID and using plus addresses of one mailbox when given),
-- a small team, and eight class weeks for each cohort.
create or replace function private.load_sandbox_seed(p_test_email text default null, p_test_discord_user_id text default null,
  p_test_channel_id text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_local text := coalesce(nullif(split_part(coalesce(p_test_email, ''), '@', 1), ''), 'sandbox.instructor');
  v_mail_domain text := coalesce(nullif(split_part(coalesce(p_test_email, ''), '@', 2), ''), 'example.com');
  v_chan text := coalesce(p_test_channel_id, '100000000000000002');
  v_owner uuid; v_ops uuid; v_esc uuid;
  v_dom uuid; v_mod uuid; v_coh_we uuid; v_coh_wd uuid;
  v_tests uuid[] := '{}';
  v_i uuid;
  d record; m record;
  k int;
  v_first_we date; v_first_wd date;
  n_weeks int := 0;
  v_rows jsonb;
begin
  perform set_config('app.actor_kind', 'System', true);
  perform set_config('app.actor_label', 'Sandbox data', true);

  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Owner', 'sandbox.owner@' || v_mail_domain, 'Product manager', true) returning id into v_owner;
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Operations', 'sandbox.operations@' || v_mail_domain, 'Operations', true) returning id into v_ops;
  insert into public.team_member (name, email, job_title, is_placeholder)
  values ('Sandbox Escalation', 'sandbox.escalation@' || v_mail_domain, 'Lead', true) returning id into v_esc;

  for k in 1 .. 6 loop
    insert into public.instructor (full_name, primary_email, discord_user_id, is_test, verified_at, notes)
    values ('Test Instructor ' || chr(64 + k), lower(v_local || '+' || chr(96 + k) || '@' || v_mail_domain),
            p_test_discord_user_id, true, now(), 'Sandbox test instructor. Messages go to the testing channel.')
    returning id into v_i;
    v_tests := v_tests || v_i;
  end loop;

  -- Next Saturday and next Tuesday (Pacific), so both cohorts start within two weeks.
  v_first_we := (now() at time zone 'America/Los_Angeles')::date + ((6 - extract(dow from now() at time zone 'America/Los_Angeles')::int + 7) % 7) + 7;
  v_first_wd := (now() at time zone 'America/Los_Angeles')::date + ((2 - extract(dow from now() at time zone 'America/Los_Angeles')::int + 7) % 7) + 7;

  for d in select * from (values ('Backend', array['Database Design', 'API Design', 'Concurrency']),
                                 ('Fullstack', array['React Basics', 'Node Services', 'Deployment'])) x(name, mods) loop
    insert into public.domain (name, status, alert_discord_channel_id, test_discord_channel_id, test_email)
    values (d.name, 'Test', v_chan, v_chan, lower(v_local || '+testing@' || v_mail_domain))
    returning id into v_dom;
    insert into public.domain_team (domain_id, team_member_id, role)
    values (v_dom, v_ops, 'Operations'), (v_dom, v_esc, 'Escalation');
    insert into public.cohort (domain_id, name, start_date, status) values (v_dom, 'Weekend cohort', v_first_we, 'Running')
    returning id into v_coh_we;
    insert into public.cohort (domain_id, name, start_date, status) values (v_dom, 'Weekday cohort', v_first_wd, 'Running')
    returning id into v_coh_wd;
    for k in 1 .. cardinality(d.mods) loop
      insert into public.module (domain_id, name, rotation_order) values (v_dom, d.mods[k], k) returning id into v_mod;
      insert into public.module_owner (module_id, team_member_id) values (v_mod, v_owner);
      insert into public.module_resource (module_id, title, url)
      values (v_mod, d.mods[k] || ' module page', 'https://example.com/sandbox/' || lower(replace(d.mods[k], ' ', '-')));
      -- Module default (used by the weekend cohort): Saturday live class and Sunday review.
      insert into public.class_pattern_item (module_id, class_type, title_template, day_offset, start_time_pt, duration_minutes, sort_order)
      values (v_mod, 'Live class', '{module}: Live class', 0, '09:00', 240, 1),
             (v_mod, 'Assignment review', '{module}: Assignment review', 1, '10:00', 120, 2);
      -- Weekday cohort: Tuesday and Thursday evenings.
      insert into public.class_pattern_item (module_id, cohort_id, class_type, title_template, day_offset, start_time_pt, duration_minutes, sort_order)
      values (v_mod, v_coh_wd, 'Live class', '{module}: Live class', 0, '18:00', 120, 1),
             (v_mod, v_coh_wd, 'Assignment review', '{module}: Assignment review', 2, '18:00', 90, 2);
      -- Instructor order: three test instructors, rotated so each module has a different Primary.
      insert into public.module_ranking (module_id, instructor_id, rank)
      select v_mod, v_tests[((k - 1 + j) % 6) + 1], j + 1 from generate_series(0, 2) j;
    end loop;
    select id into v_mod from public.module where domain_id = v_dom and rotation_order = 1;
    v_rows := public.generate_classes(v_dom, v_mod, array(select v_first_we + 7 * j from generate_series(0, 7) j), 'Weekend cohort');
    n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Sandbox data') ->> 'created')::int, 0);
    v_rows := public.generate_classes(v_dom, v_mod, array(select v_first_wd + 7 * j from generate_series(0, 7) j), 'Weekday cohort');
    n_weeks := n_weeks + coalesce((public.create_module_weeks(v_dom, v_rows, true, 'Sandbox data') ->> 'created')::int, 0);
  end loop;
  perform private.log_event('System', 'Sandbox data loaded', null, null, null,
    jsonb_build_object('domains', 2, 'class_weeks', n_weeks, 'test_instructors', cardinality(v_tests)));
  return jsonb_build_object('class_weeks', n_weeks, 'test_instructors', cardinality(v_tests));
end;
$$;

-- "Reset Sandbox data": everything except Activity history, settings definitions and the
-- environment settings goes back to the Sandbox starting data. Never in Production.
create or replace function public.reset_sandbox_data(p_confirm text, p_test_email text default null,
  p_test_discord_user_id text default null, p_test_channel_id text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_env text := (select environment from public.app_config where id = 1); v jsonb;
begin
  perform private.require_team();
  if v_env = 'Production' then
    raise exception 'Sandbox data can never be reset in Production.' using errcode = '42501';
  end if;
  if p_confirm is distinct from 'RESET' then
    raise exception 'Type RESET to confirm.' using errcode = '22023';
  end if;
  perform private.log_event('System', 'Sandbox data reset started');
  -- Run any checks still waiting in this transaction (instructor order) before clearing tables.
  set constraints all immediate;
  -- Keep holidays and settings that apply to every domain (truncating domains would remove them).
  create temp table reset_keep_holiday on commit drop as select date, name from public.holiday where domain_id is null;
  create temp table reset_keep_setting on commit drop as select key, value from public.setting where scope = 'Global';
  truncate table public.message, public.request, public.response_link, public.booking_slot, public.booking,
    public.checklist_item, public.help_request, public.reminder, public.attention_item, public.manual_queue_item,
    public.class_session, public.module_week, public.setting, public.module_operations, public.module_ranking,
    public.module_owner, public.module_resource, public.class_pattern_item, public.module, public.cohort,
    public.class_type, public.message_template, public.domain_team, public.instructor_unavailability,
    public.instructor_email, public.instructor, public.action_queue, public.app_error, public.domain,
    public.discord_cursor
    restart identity cascade;
  -- Real people keep their sign in and profile; only the made up Sandbox people are replaced.
  delete from public.team_member where is_placeholder;
  insert into public.holiday (date, name) select date, name from reset_keep_holiday on conflict do nothing;
  insert into public.setting (scope, key, value) select 'Global', key, value from reset_keep_setting;
  update public.system_state set outreach_enabled = true where id = 1;
  v := private.load_sandbox_seed(p_test_email, p_test_discord_user_id, p_test_channel_id);
  set constraints all deferred;
  return v;
end;
$$;
revoke execute on function public.reset_sandbox_data(text, text, text, text) from anon, public;
grant execute on function public.reset_sandbox_data(text, text, text, text) to authenticated, service_role;
