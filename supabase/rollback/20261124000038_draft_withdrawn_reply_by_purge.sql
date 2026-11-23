-- Rollback of 20261124000038_draft_withdrawn_reply_by_purge.sql.

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
  v_send := private.instructor_send_time(coalesce(p_mw, v_domain), p_now, p_urgent, coalesce(private.week_region(p_mw), 'US'), p_instructor);

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
  if c.environment = 'Production' and c.message_recipients = 'Anyone' and m.audience = 'Instructor' and coalesce(i.is_test, false) then
    return 'Production never messages test instructors.';
  end if;
  if m.channel = 'Discord' and m.discord_channel_id is not null and m.discord_dm_user_id is not null then
    return 'A Discord message goes either to a channel or to one person, not both.';
  end if;
  -- Release 3 beta guard (decision 287): settings checked in every environment, for every recipient and tag.
  if m.channel = 'Email' and coalesce(array_length(c.recipient_email_domains, 1), 0) > 0 then
    v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
    if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.recipient_email_domains) x))) then
      return 'Not sent: during the beta, email goes only to ' || array_to_string(c.recipient_email_domains, ', ') || ' addresses. '
        || coalesce(nullif(v_domain, ''), 'This address') || ' is not one of them. Use an address there, or change Settings, Admin.';
    end if;
  end if;
  if c.message_recipients = 'Test instructors and signed in colleagues' then
    -- Owner, 23 November 2026: also anyone who is a signed in colleague or, while the setting is on, on the beta list.
    if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
       and not private.is_beta_instructor(i.id) then
      return 'Not sent: during the beta, messages go only to test instructors, signed in colleagues and people on the beta list. '
        || 'Add ' || coalesce(i.full_name, 'this instructor') || '''s email to the beta list on Settings, Admin, or mark them as a test instructor, then press Send again.';
    end if;
    if m.channel = 'Discord' then
      if m.discord_dm_user_id is not null and not private.is_beta_discord(m.discord_dm_user_id, i.id) then
        return 'Not sent: during the beta, Discord direct messages go only to colleagues who have signed in or are on the beta list. '
          || 'Ask them to sign in once, or add their email to the beta list on Settings, Admin, then press Send again.';
      end if;
      if exists (select 1 from unnest(coalesce(m.mention_user_ids, '{}')) x where not private.is_beta_discord(x, i.id)) then
        return 'Not sent: during the beta, a message may only tag colleagues who have signed in or are on the beta list. '
          || 'Ask them to sign in once, or add their email to the beta list on Settings, Admin, then press Send again.';
      end if;
    end if;
  end if;
  -- Discord servers approved by an admin (decision 288), in every environment.
  if m.channel = 'Discord' and m.discord_channel_id is not null then
    v_server := (select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id);
    if v_server is null then
      return 'The bot only posts in channels it has listed. Press Refresh on Settings, Connections first.';
    end if;
    if not private.server_allowed(v_server, m.domain_id) then
      return 'The bot only posts in Discord servers an admin has approved for this domain.';
    end if;
  elsif m.channel = 'Discord' and m.discord_dm_user_id is not null and m.domain_id is not null
        and (select d.discord_server_id from public.domain d where d.id = m.domain_id) is not null
        and not private.server_allowed((select d.discord_server_id from public.domain d where d.id = m.domain_id), m.domain_id) then
    return 'The bot sends direct messages for this domain only once an admin has approved its Discord server.';
  end if;
  if c.environment = 'Sandbox' then
    if m.channel = 'Email' then
      if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
         and not private.is_test_domain(m.domain_id) then
        return 'Sandbox never contacts real instructors by email, even at an allowed address. Mark them as a test instructor to try this.';
      end if;
      v_domain := lower(split_part(coalesce(m.to_address, ''), '@', 2));
      if v_domain = '' or not (v_domain = any (array(select lower(x) from unnest(c.sandbox_allowed_email_domains) x))) then
        return 'Sandbox only sends email to allowed domains. ' || coalesce(nullif(v_domain, ''), 'This address') || ' is not on the list.';
      end if;
    elsif m.channel = 'Discord' then
      if m.audience = 'Instructor' and m.instructor_id is not null and not coalesce(i.is_test, false)
         and not private.is_test_domain(m.domain_id) then
        return 'Sandbox never contacts real instructors on Discord. Mark them as a test instructor to try this.';
      end if;
      -- A post goes to the server of its channel. A direct message is allowed only to a test instructor
      -- or a team member (Sandbox never contacts real instructors).
      if m.discord_dm_user_id is not null and m.discord_channel_id is null then
        if m.audience = 'Instructor' and not coalesce(i.is_test, false) then
          return 'Sandbox only sends direct messages to test instructors.';
        end if;
        -- SEC-5: only to the Discord account of a team member who still has access (test instructors use
        -- the account of the person testing), never to an account a real instructor uses or one the bot
        -- found in another server.
        if exists (select 1 from public.instructor x where x.discord_user_id = m.discord_dm_user_id and not x.is_test)
           or not exists (select 1 from public.team_member t where t.discord_user_id = m.discord_dm_user_id
                           and t.access_removed_at is null) then
          return 'Sandbox only sends direct messages to the Discord accounts of team members. Test instructors use the Discord account of the person testing.';
        end if;
        return null;
      end if;
      -- The channel must be one the bot listed, in an allowed server (no guessing from the domain).
      v_server := (select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id);
      if v_server is null then
        return 'Sandbox only posts to channels the bot has listed. Press Check on Settings, Connections first.';
      end if;
    end if;
  end if;
  return null;
end;
$$;

create or replace function public.set_domain_status(p_domain_id uuid, p_status text)
returns void language plpgsql security definer set search_path = ''
as $$
declare d public.domain;
begin
  perform private.require_team();
  select * into d from public.domain where id = p_domain_id for update;
  if d.id is null then raise exception 'Domain not found.' using errcode = '22023'; end if;
  if d.status = p_status then return; end if;
  -- Owner, 23 November 2026: what is missing is said exactly, and nothing changes.
  if jsonb_array_length(public.domain_status_problems(p_domain_id, p_status)) > 0 then
    raise exception '%', (select string_agg(x ->> 'text', ' ') from jsonb_array_elements(public.domain_status_problems(p_domain_id, p_status)) x)
      using errcode = '22023';
  end if;
  perform set_config('app.suppress_setup_log', 'on', true);
  update public.domain set status = p_status,
         test_clock_at = case when p_status = 'Test' or (p_status = 'Paused' and status = 'Test') then test_clock_at end
   where id = p_domain_id;
  perform set_config('app.suppress_setup_log', 'off', true);
  perform private.log_event('Setup changes',
    case p_status when 'Live' then 'Went live' when 'Test' then 'Testing turned on' when 'Paused' then 'Domain paused'
                  else 'Moved back to Draft' end,
    'domain', d.id, jsonb_build_object('status', d.status), jsonb_build_object('status', p_status), null, d.id);
end;
$$;

create or replace function private.week_history_reason(p_instructor uuid, p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select case
              when r.status in ('Sent', 'Reminded', 'Queued') then 'Being asked now'
              when r.status = 'Declined' then 'Already declined this module week'
              when r.status = 'Expired' then 'Did not reply earlier'
              when r.status = 'Withdrawn' then 'Skipped by ops'
            end
       from public.request r
      where r.module_week_id = p_mw and r.instructor_id = p_instructor and r.kind = 'Outreach'
        and ((r.status in ('Sent', 'Reminded', 'Queued', 'Expired'))
             or (r.status = 'Declined' and r.close_reason is distinct from 'Clash')
             or (r.status = 'Withdrawn' and r.close_reason in ('Skipped', 'Outreach changed by ops')))
      order by (r.status in ('Sent', 'Reminded', 'Queued')) desc, r.created_at desc limit 1),
    (select 'Cancelled this module week earlier' from public.booking b
      where b.module_week_id = p_mw and b.instructor_id = p_instructor and b.status = 'Released' limit 1));
$$;

create or replace function private.break_messages(p_weeks uuid[], p_text text, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  g record;
  v_mw uuid;
  v_req uuid;
  v_first_req uuid;
  v_win record;
  v_urgent boolean;
  v_any_urgent boolean;
  v_send timestamptz;
  v_deadline timestamptz;
  v_min_deadline timestamptz;
  v_buttons jsonb;
  v_lines text;
  v_n int := 0;
  v_part int;
  b record;
begin
  for g in select bk.instructor_id, array_agg(w.id order by w.first_class_at, w.id) as weeks
             from public.booking bk join public.module_week w on w.id = bk.module_week_id
            where w.id = any (coalesce(p_weeks, '{}')) and bk.status = 'Active' and not w.paused
              and w.first_class_at > p_now and private.instructor_messages_allowed(w.domain_id)
            group by bk.instructor_id loop
    for v_part in 0 .. (cardinality(g.weeks) - 1) / 8 loop
      v_buttons := '[]'; v_lines := ''; v_first_req := null; v_min_deadline := null; v_any_urgent := false;
      foreach v_mw in array g.weeks[v_part * 8 + 1 : v_part * 8 + 8] loop
        select bk.*, w.time_version as mw_tv, w.first_class_at, w.domain_id, m.name as module_name,
               private.week_region(w.id) as region into b
          from public.booking bk join public.module_week w on w.id = bk.module_week_id join public.module m on m.id = w.module_id
         where bk.module_week_id = v_mw and bk.status = 'Active';
        update public.request set status = 'Superseded', close_reason = 'Time changed again'
         where module_week_id = v_mw and kind = 'TimeChange' and status in ('Queued', 'Sent', 'Reminded');
        v_win := private.window_hours(v_mw, p_now);
        v_urgent := v_win.band = 'Short';
        v_any_urgent := v_any_urgent or v_urgent;
        v_send := private.instructor_send_time(v_mw, p_now, v_urgent, b.region);
        v_deadline := least(private.instructor_send_time(v_mw, v_send + make_interval(hours => v_win.move_h), v_urgent, b.region), b.first_class_at);
        insert into public.request (module_week_id, instructor_id, booking_id, kind, status, time_version, sent_at, reminder_at,
          deadline_at, is_test)
        values (v_mw, b.instructor_id, b.id, 'TimeChange', 'Sent', b.mw_tv, v_send,
          case when v_win.reminder_h is null then null else least(private.instructor_send_time(v_mw, v_send + make_interval(hours => v_win.reminder_h), v_urgent, b.region), v_deadline) end,
          v_deadline, b.is_test)
        returning id into v_req;
        perform private.log_event('Messages', 'Time-change request sent', 'request', v_req, null,
          jsonb_build_object('time_version', b.mw_tv, 'combined', true), null, b.domain_id, null, v_mw, null, b.instructor_id, null, b.is_test);
        v_first_req := coalesce(v_first_req, v_req);
        v_min_deadline := least(coalesce(v_min_deadline, v_deadline), v_deadline);
        v_buttons := v_buttons || (select coalesce(jsonb_agg(x || jsonb_build_object('label', (x ->> 'label') || ': ' || b.module_name
                        || ', ' || to_char(b.first_class_at at time zone private.region_tz(b.region), 'Mon FMDD')) order by o), '[]')
                      from jsonb_array_elements(private.buttons(v_req, array['StillWorks', 'DoesntWork'])) with ordinality t(x, o));
        v_lines := v_lines || case when v_lines = '' then '' else E'\n\n' end || b.module_name || E'\n' || private.class_lines(v_mw);
      end loop;
      perform private.queue_instructor_message('M17', g.instructor_id, g.weeks[v_part * 8 + 1], v_first_req, p_now, v_buttons,
        jsonb_build_object('classes', v_lines, 'text', p_text,
          'deadline', private.fmt_local_both(v_min_deadline, private.week_region(g.weeks[v_part * 8 + 1]))), v_any_urgent);
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end;
$$;

create or replace function private.step_checkins(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  b record;
  r record;
  n int := 0;
  v_days int[];
  v_last int;
  v_due int;
  v_req uuid;
  v_rem int;
  v_send timestamptz;
  v_deadline timestamptz;
  v_tpl text;
  v_urgent_band int;
  v_name text;
begin

  for b in select bk.*, mw.first_class_at, mw.module_id
             from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and not mw.paused and mw.first_class_at > p_now
            for update of bk skip locked loop
    v_days := private.checkin_days_for(b.module_week_id);
    v_last := private.last_checkin_day(b.module_week_id);
    v_urgent_band := private.setting_int(b.module_week_id, 'urgent_band_days');
    select min(d) into v_due from unnest(v_days) d
     where b.first_class_at - make_interval(days => d) <= p_now
       and b.confirmed_at < b.first_class_at - make_interval(days => d);
    continue when v_due is null;
    continue when exists (select 1 from public.request q where q.booking_id = b.id and q.kind = 'CheckIn' and q.check_in_days <= v_due);
    v_rem := case when v_due > v_urgent_band then 24 else 12 end;
    v_send := private.instructor_send_time(b.module_week_id, p_now, v_due <= v_urgent_band, private.week_region(b.module_week_id));
    v_deadline := least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => 2 * v_rem), v_due <= v_urgent_band, private.week_region(b.module_week_id)), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, check_in_days, status, sent_at,
      reminder_at, deadline_at, is_test, time_version)
    values (b.module_week_id, b.instructor_id, b.id, 'CheckIn', v_due, 'Sent', v_send,
      least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => v_rem), v_due <= v_urgent_band, private.week_region(b.module_week_id)), v_deadline),
      v_deadline, b.is_test, (select mw.time_version from public.module_week mw where mw.id = b.module_week_id))
    returning id into v_req;
    v_tpl := case when v_due = v_last then 'M7' when v_due = 14 and v_due <> all (array(select x::int from jsonb_array_elements_text(private.get_setting(b.module_week_id, 'checkin_days')) x)) then 'M8' else 'M6' end;
    perform private.queue_instructor_message(v_tpl, b.instructor_id, b.module_week_id, v_req, p_now,
      private.buttons(v_req, case when v_tpl = 'M8' then array['AllSet', 'NeedHelp'] else array['AllSet', 'NeedHelp', 'CantMakeIt'] end),
      jsonb_build_object('days', v_due), v_due <= v_urgent_band);
    perform private.log_event('Messages', v_due || '-day check-in sent', 'request', v_req, null, null, null,
      p_domain, b.module_id, b.module_week_id, null, b.instructor_id, null, b.is_test);
    n := n + 1;
  end loop;

  for r in select q.*, mw.module_id from public.request q join public.module_week mw on mw.id = q.module_week_id
            where mw.domain_id = p_domain and q.kind = 'CheckIn' and q.status in ('Sent', 'Reminded') and not mw.paused
            for update of q skip locked loop
    select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
    v_last := private.last_checkin_day(r.module_week_id);
    v_urgent_band := private.setting_int(r.module_week_id, 'urgent_band_days');
    if r.deadline_at <= p_now then
      update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
      perform private.log_event('Messages', 'No reply to the ' || r.check_in_days || '-day check-in from ' || v_name, 'request', r.id,
        null, null, null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
      if r.check_in_days = v_last and private.setting_text(r.module_week_id, 'last_checkin_no_reply') = 'Release' then
        perform private.release_booking_flow(r.booking_id, 'NoReplyRelease', p_now);
      else
        perform private.raise_attention(p_domain, 'CheckInNoReply',
          case when r.check_in_days = v_last then 'Urgent' else 'Normal' end,
          'No reply to the ' || r.check_in_days || '-day check-in: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'The booking is kept. Please check with them.', 'checkin_noreply:' || r.id,
          private.ops_for_week(r.module_week_id), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)));
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now and private.setting_bool(r.module_week_id, 'remind_instructor_after_assign') then
      update public.request set status = 'Reminded', reminded_at = p_now where id = r.id;
      perform private.queue_instructor_message('M9', r.instructor_id, r.module_week_id, r.id, p_now,
        private.buttons(r.id, array['AllSet', 'NeedHelp', 'CantMakeIt']), '{}', r.check_in_days <= v_urgent_band);
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

create or replace function private.step_time_changes(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare b record; n int := 0; v_req uuid; v_win record; v_send timestamptz; v_deadline timestamptz; v_urgent boolean;
begin
  for b in select bk.*, mw.time_version as mw_tv, mw.first_class_at, mw.domain_id
             from public.booking bk join public.module_week mw on mw.id = bk.module_week_id
            where mw.domain_id = p_domain and bk.status = 'Active' and not mw.paused
              and mw.time_version > bk.time_version_confirmed and mw.first_class_at > p_now
              and not exists (select 1 from public.request q where q.module_week_id = mw.id and q.kind = 'TimeChange'
                                and q.time_version = mw.time_version)
            for update of bk skip locked loop
    update public.request set status = 'Superseded', close_reason = 'Time changed again'
     where module_week_id = b.module_week_id and kind = 'TimeChange' and status in ('Queued', 'Sent', 'Reminded');
    v_win := private.window_hours(b.module_week_id, p_now);
    v_urgent := v_win.band = 'Short';
    v_send := private.instructor_send_time(b.module_week_id, p_now, v_urgent, private.week_region(b.module_week_id));
    v_deadline := least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => v_win.move_h), v_urgent, private.week_region(b.module_week_id)), b.first_class_at);
    insert into public.request (module_week_id, instructor_id, booking_id, kind, status, time_version, sent_at, reminder_at,
      deadline_at, is_test)
    values (b.module_week_id, b.instructor_id, b.id, 'TimeChange', 'Sent', b.mw_tv, v_send,
      case when v_win.reminder_h is null then null else least(private.instructor_send_time(b.module_week_id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(b.module_week_id)), v_deadline) end,
      v_deadline, b.is_test)
    returning id into v_req;
    perform private.queue_instructor_message('M5', b.instructor_id, b.module_week_id, v_req, p_now,
      private.buttons(v_req, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_local_both(v_deadline, private.week_region(b.module_week_id))), v_urgent);
    perform private.log_event('Messages', 'Time-change request sent', 'request', v_req, null,
      jsonb_build_object('time_version', b.mw_tv), null, p_domain, null, b.module_week_id, null, b.instructor_id, null, b.is_test);
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function private.week_times_changed(p_mw uuid, p_now timestamptz, p_clash boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  b public.booking;
  r public.request;
  v_win record;
  v_urgent boolean;
  v_send timestamptz;
  v_deadline timestamptz;
begin
  update public.module_week set time_version = time_version + 1 where id = p_mw returning * into w;
  select * into b from public.booking where module_week_id = w.id and status = 'Active';
  if b.id is not null then
    if p_clash then
      perform private.release_booking_flow(b.id, 'TimeClash', p_now, true);
      return jsonb_build_object('released', true, 'reason', 'clash');
    end if;
    -- The time-change request (M5) is created by the engine step; run it now unless instructor
    -- messages are paused (then the next allowed hourly run creates it).
    if private.instructor_messages_allowed(w.domain_id) and not w.paused then
      perform private.step_time_changes(w.domain_id, p_now);
    end if;
    return jsonb_build_object('time_change_request', exists (
      select 1 from public.request q where q.module_week_id = w.id and q.kind = 'TimeChange'
         and q.status in ('Queued', 'Sent', 'Reminded')));
  end if;

  select * into r from public.request
   where module_week_id = w.id and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded') for update;
  if r.id is not null then
    -- Recalculate the response window for the new times (the class may now be much closer).
    v_win := private.window_hours(w.id, p_now);
    v_urgent := v_win.band = 'Short';
    v_send := private.instructor_send_time(w.id, p_now, v_urgent, private.week_region(w.id));
    v_deadline := least(greatest(r.sent_at, p_now) + make_interval(hours => v_win.move_h), w.first_class_at);
    v_deadline := least(private.instructor_send_time(w.id, v_deadline, v_urgent, private.week_region(w.id)), w.first_class_at);
    update public.request
       set time_version = w.time_version,
           deadline_at = least(deadline_at, v_deadline),
           reminder_at = case when v_win.reminder_h is null or reminder_at is null then null else least(reminder_at, private.instructor_send_time(w.id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(w.id)), v_deadline) end
     where id = r.id
    returning * into r;
    perform private.queue_instructor_message('M5', r.instructor_id, w.id, r.id, p_now,
      private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local_both(r.deadline_at, private.week_region(w.id))), v_urgent);
    return jsonb_build_object('updated_request', true);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.resend_message(p_message_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare m public.message; v_id uuid; v_now timestamptz; v_send timestamptz;
begin
  perform private.require_team();
  select * into m from public.message where id = p_message_id;
  if m.id is null or m.direction <> 'Outbound' then raise exception 'Choose a sent message to resend.'; end if;
  -- A message a beta rule stopped can be sent again once the rule allows it (owner, 23 November 2026).
  if m.status not in ('Sent', 'Failed') and not (m.status = 'Cancelled' and coalesce(m.blocked, false)) then
    raise exception 'That message hasn''t gone out yet (it is %), so there is nothing to resend.', lower(m.status);
  end if;
  if m.domain_id is not null and m.audience <> 'Admin' and m.is_test <> private.is_test_domain(m.domain_id) then
    raise exception 'Testing was switched on or off since this message was sent. Send a new message instead, from Instructor requests after the next check.';
  end if;
  v_now := coalesce(private.domain_now(m.domain_id), now());
  v_send := case when m.audience = 'Instructor' then private.instructor_send_time(coalesce(m.module_week_id, m.domain_id), v_now, false, coalesce(private.week_region(m.module_week_id), 'US')) else v_now end;
  if m.request_id is not null and exists (select 1 from public.request r where r.id = m.request_id
       and r.status not in ('Queued', 'Sent', 'Reminded', 'Accepted')) then
    raise exception 'That request has closed, so the message would confuse the instructor. Ask again instead.';
  end if;
  insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id,
    team_member_id, module_week_id, request_id, help_request_id, attention_item_id, recipient_label, to_address,
    discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html, buttons, is_test)
  select domain_id, audience, template_id, channel,
         coalesce(unique_key, id::text) || ':resend:' || extract(epoch from clock_timestamp())::bigint,
         case when v_send > v_now then 'Scheduled' else 'Pending' end, v_send, instructor_id, team_member_id, module_week_id, request_id, help_request_id, attention_item_id,
         recipient_label, to_address, discord_channel_id, discord_dm_user_id, mention_user_ids, subject, body_text, body_html,
         buttons, is_test
    from public.message where id = p_message_id
  returning id into v_id;
  perform private.log_event('Team actions', case when m.status = 'Cancelled' then 'Sent again after it was blocked: ' else 'Resent ' end
      || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
    'message', v_id, null, null, null, m.domain_id, null, m.module_week_id, null, m.instructor_id);
  perform private.queue_deliver('resend');
  return jsonb_build_object('ok', true, 'message_id', v_id);
end;
$$;

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
end;
$$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobname) from cron.job where jobname = 'sme-run-log-purge';
  end if;
end;
$$;
drop function if exists private.purge_run_log(interval);
