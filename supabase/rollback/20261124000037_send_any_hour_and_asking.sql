-- Rollback of 20261124000037_send_any_hour_and_asking.sql.
drop trigger if exists request_closed_settle on public.request;
drop function if exists private.request_closed_settle();
drop function if exists private.settle_asking_weeks(timestamptz);
drop function if exists private.settle_asking_week(uuid, timestamptz);
drop function if exists private.instructor_send_time(uuid, timestamptz, boolean, text, uuid);

create or replace function private.instructor_send_time(p_domain uuid, p_ts timestamptz, p_urgent boolean, p_region text default 'US')
returns timestamptz language sql stable set search_path = ''
as $$
  select case when p_urgent
    then private.next_allowed(p_ts, private.region_tz(p_region),
           private.setting_text(p_domain, 'instructor_urgent_quiet_start'), private.setting_text(p_domain, 'instructor_urgent_quiet_end'))
    else private.next_allowed(p_ts, private.region_tz(p_region),
           private.setting_text(p_domain, 'instructor_quiet_start'), private.setting_text(p_domain, 'instructor_quiet_end'))
  end;
$$;

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
  if not v_vars ? 'module' then v_vars := v_vars || jsonb_build_object('module', 'SME Scheduling', 'domain', '', 'classes', '',
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

create or replace function private.ask_next(p_mw uuid, p_now timestamptz)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  l record;
  v_pick record;
  v_found boolean := false;
  v_skips text := '';
  v_req uuid;
  v_win record;
  v_urgent boolean;
  v_send timestamptz;
  v_deadline timestamptz;
  v_first boolean;
  v_test boolean;
  v_now_reason text;
  c record;
  v_later uuid[] := '{}';
  v_sent boolean;
  v_lw uuid;
begin
  select * into w from public.module_week where id = p_mw for update;
  if w.status in ('Cancelled', 'Completed') then
    return null;
  end if;
  if w.paused or w.first_class_at is null or w.first_class_at <= p_now
     or not private.instructor_messages_allowed(w.domain_id) then
    -- Can't ask right now (paused, kill switch, class started): never leave the week "Asking" with
    -- nobody asked — set it back to Ready so the next allowed run picks it up.
    if w.status = 'Asking' and not exists (select 1 from public.request r where r.module_week_id = p_mw
                                            and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')) then
      update public.module_week set status = 'Ready' where id = p_mw;
    end if;
    return null;
  end if;
  select r.id into v_req from public.request r
   where r.module_week_id = p_mw and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded');
  if v_req is not null then return v_req; end if;
  if exists (select 1 from public.booking b where b.module_week_id = p_mw and b.status = 'Active') then
    return null;
  end if;

  for l in select * from private.build_line(p_mw) order by pos loop
    if l.reason is null then
      -- M7: one asking at a time per instructor, then check again with what other runs have just saved.
      perform pg_advisory_xact_lock(hashtextextended('ask:' || l.instructor_id::text, 0));
      v_now_reason := private.sooner_class_reason(l.instructor_id, p_mw);
      if v_now_reason is null then
        v_pick := l;
        v_found := true;
        exit;
      end if;
      v_skips := v_skips || l.full_name || ' — ' || v_now_reason || '; ';
    elsif l.reason not in ('Already declined this module week', 'Did not reply earlier', 'Skipped by ops',
                           'Cancelled this module week earlier', 'Being asked now') then
      v_skips := v_skips || l.full_name || ' — ' || l.reason || '; ';
    end if;
  end loop;
  v_test := private.is_test_domain(w.domain_id);

  if not v_found then
    if w.status <> 'NeedsInstructor' then
      update public.module_week set status = 'NeedsInstructor' where id = p_mw;
      perform private.log_event('System', 'Nobody left to ask', 'module_week', p_mw, null, null,
        nullif(v_skips, ''), w.domain_id, w.module_id, p_mw, null, null, null, v_test);
    end if;
    -- Only one open task per class week: "Nobody left to ask" replaces "Class at risk" (decision 271).
    perform private.close_at_risk_for(p_mw, p_now);
    perform private.raise_attention(w.domain_id, 'RankingExhausted', 'Urgent',
      'Needs instructor: ' || private.mw_label(p_mw),
      'Everyone in line has been asked or can''t be asked. Assign someone manually or add instructors to the instructor order.'
        || coalesce(E'\nSkipped: ' || nullif(v_skips, ''), ''),
      'exhausted:' || p_mw, private.recipients_for_week(p_mw, true), p_now, private.mw_refs(p_mw),
      true, 'T4');
    return null;
  end if;

  -- M7: this week is sooner, so a later week that is asking the same person at an overlapping time lets them go.
  -- They hear "no longer needed" only if that request had already reached them.
  for c in select * from private.competing_requests(v_pick.instructor_id, p_mw) where not sooner loop
    v_sent := exists (select 1 from public.message m where m.request_id = c.request_id and m.template_id = 'M1'
                        and m.status in ('Sending', 'Sent'));
    if private.withdraw_open_request(c.module_week_id, 'Sooner class', p_now, v_sent) is not null then
      v_later := v_later || c.module_week_id;
      perform private.log_event('Messages', 'Sooner class first: ' || v_pick.full_name, 'module_week', c.module_week_id,
        null, jsonb_build_object('sooner_week', p_mw, 'sooner', private.mw_label(p_mw), 'told', v_sent),
        v_pick.full_name || ' is needed for a sooner class at the same time (' || private.mw_label(p_mw)
          || '), so this class week asks its next instructor.',
        (select x.domain_id from public.module_week x where x.id = c.module_week_id),
        (select x.module_id from public.module_week x where x.id = c.module_week_id),
        c.module_week_id, null, v_pick.instructor_id, null, v_test);
    end if;
  end loop;

  v_win := private.window_hours(p_mw, p_now);
  v_urgent := v_win.band = 'Short';
  v_send := private.instructor_send_time(w.id, p_now, v_urgent, private.week_region(p_mw));
  v_deadline := least(private.instructor_send_time(w.id, v_send + make_interval(hours => v_win.move_h), v_urgent, private.week_region(p_mw)),
                      w.first_class_at);
  insert into public.request (module_week_id, instructor_id, kind, status, time_version, line_source,
    declined_before, sent_at, reminder_at, deadline_at, is_test)
  values (p_mw, v_pick.instructor_id, 'Outreach', 'Sent', w.time_version, v_pick.source,
    v_pick.warning is not null, v_send,
    case when v_win.reminder_h is null then null else least(private.instructor_send_time(w.id, v_send + make_interval(hours => v_win.reminder_h), v_urgent, private.week_region(p_mw)), v_deadline) end,
    v_deadline, v_test)
  returning id into v_req;
  if v_pick.queue_item_id is not null then
    update public.manual_queue_item set asked_request_id = v_req where id = v_pick.queue_item_id;
  end if;
  perform private.queue_instructor_message('M1', v_pick.instructor_id, p_mw, v_req, p_now,
    private.buttons(v_req, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local(v_deadline, private.week_region(p_mw))), v_urgent);

  v_first := w.outreach_started_at is null;
  update public.module_week
     set status = 'Asking', outreach_started_at = coalesce(outreach_started_at, p_now)
   where id = p_mw;
  perform private.log_event('Messages', 'Asked ' || v_pick.full_name, 'request', v_req, null,
    jsonb_build_object('deadline', v_deadline, 'band', v_win.band, 'source', v_pick.source),
    nullif('Skipped: ' || v_skips, 'Skipped: '), w.domain_id, w.module_id, p_mw, null, v_pick.instructor_id, null, v_test);
  if v_first then
    perform private.queue_team_message('T1', w.domain_id, 'alert', null, private.owners_or_leads(w.module_id),
      'Asking started: ' || private.mw_label(p_mw),
      '📣 Asking started for ' || private.mw_label(p_mw) || ': asking ' || v_pick.full_name || '.',
      'T1:' || p_mw, p_now, false, null, p_mw);
  end if;
  if v_urgent then
    perform private.raise_attention(w.domain_id, 'ClassAtRisk', 'Urgent',
      'Under ' || private.setting_int(w.id, 'urgent_band_days') || ' days and no instructor yet: ' || private.mw_label(p_mw),
      'Now asking ' || v_pick.full_name || ' (moves on after ' || v_win.move_h || 'h). Consider phoning people too.',
      'urgentfill:' || p_mw, private.recipients_for_week(p_mw, true), p_now, private.mw_refs(p_mw));
  end if;

  -- The later weeks ask their next instructor now (each is later, so this always ends).
  foreach v_lw in array v_later loop
    perform private.ask_next(v_lw, p_now);
  end loop;
  return v_req;
end;
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
          'deadline', private.fmt_local(v_min_deadline, private.week_region(g.weeks[v_part * 8 + 1]))), v_any_urgent);
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end;
$$;

create or replace function private.step_requests(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  n int := 0;
  v_reason text;
  v_urgent boolean;
  v_name text;
begin
  for r in select q.*, mw.module_id, mw.first_class_at
             from public.request q join public.module_week mw on mw.id = q.module_week_id
            where mw.domain_id = p_domain and not mw.paused
              and q.kind in ('Outreach', 'TimeChange') and q.status in ('Sent', 'Reminded')
            for update of q skip locked loop
    select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
    v_urgent := private.band(r.module_week_id, p_now) = 'Short';
    if r.kind = 'Outreach' then
      v_reason := private.eligibility(r.instructor_id, r.module_week_id);
      if v_reason is not null and (v_reason in ('Inactive', 'Archived') or v_reason like 'Unavailable%') then
        perform private.withdraw_open_request(r.module_week_id, 'No longer available: ' || v_reason, p_now, true);
        perform private.ask_next(r.module_week_id, p_now);
        n := n + 1;
        continue;
      end if;
    end if;
    if r.deadline_at <= p_now then
      if r.kind = 'Outreach' then
        update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
        perform private.queue_instructor_message('M3', r.instructor_id, r.module_week_id, r.id, p_now);
        perform private.log_event('Messages', 'No reply from ' || v_name || ' — moving on', 'request', r.id, null, null,
          null, p_domain, r.module_id, r.module_week_id, null, r.instructor_id, null, r.is_test);
        if private.band(r.module_week_id, p_now) <> 'Long' then
          perform private.queue_team_message('T3', p_domain, 'alert', null, private.owners_or_leads(r.module_id),
            'No reply: ' || private.mw_label(r.module_week_id),
            'No reply from ' || v_name || ' for ' || private.mw_label(r.module_week_id) || ' — asking the next instructor.',
            'T3:' || r.id, p_now, false, null, r.module_week_id);
        end if;
        perform private.ask_next(r.module_week_id, p_now);
      else
        update public.request set status = 'Expired', close_reason = 'No reply' where id = r.id;
        perform private.raise_attention(p_domain, 'TimeChangeNotConfirmed',
          case when private.days_until(r.module_week_id, p_now) < private.setting_int(r.module_week_id, 'short_notice_days') then 'Urgent' else 'Normal' end,
          'New time not confirmed: ' || v_name || ' — ' || private.mw_label(r.module_week_id),
          'No reply to the time-change message. The booking is kept; please check with them.',
          'timechange:' || r.module_week_id, private.recipients_for_week(r.module_week_id, true), p_now,
          private.mw_refs(r.module_week_id, jsonb_build_object('instructor_id', r.instructor_id, 'request_id', r.id)), true);
      end if;
      n := n + 1;
    elsif r.status = 'Sent' and r.reminder_at <= p_now and (private.window_hours(r.module_week_id, p_now)).reminder_h is not null then
      update public.request set status = 'Reminded', reminded_at = p_now where id = r.id;
      if r.kind = 'Outreach' then
        perform private.queue_instructor_message('M2', r.instructor_id, r.module_week_id, r.id, p_now,
          private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local(r.deadline_at, private.week_region(r.module_week_id))), v_urgent);
      else
        perform private.queue_instructor_message('M5', r.instructor_id, r.module_week_id, r.id, p_now,
          private.buttons(r.id, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_local(r.deadline_at, private.week_region(r.module_week_id))),
          v_urgent, 'reminder');
      end if;
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
      private.buttons(v_req, array['StillWorks', 'DoesntWork']), jsonb_build_object('deadline', private.fmt_local(v_deadline, private.week_region(b.module_week_id))), v_urgent);
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
      private.buttons(r.id, array['Yes', 'No']), jsonb_build_object('deadline', private.fmt_local(r.deadline_at, private.week_region(w.id))), v_urgent);
    return jsonb_build_object('updated_request', true);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function private.clock_tick(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_reason text;
  v_result text;
  v_runs int;
  st public.clock_state;
begin
  -- Owner, 23 November 2026: a Discord check finishes or fails within a few minutes, never "Checking" for hours.
  perform private.expire_stuck_checks(coalesce(p_now, now()));
  if not coalesce((select c.clock_enabled from public.app_config c where c.id = 1), false) then
    return jsonb_build_object('skipped', 'clock off');
  end if;
  select * into st from public.clock_state where id = 1 for update;
  -- One alert a month when the brakes start.
  v_runs := public.n8n_runs_this_month(v_now);
  if v_runs >= 8000 and st.budget_alert_month is distinct from date_trunc('month', v_now at time zone 'UTC')::date then
    perform private.log_event('System', 'n8n budget: replies read less often', null, null, null,
      jsonb_build_object('runs_this_month', v_runs,
        'reading', case when v_runs < 9300 then 'every 20 minutes' else 'only when n8n runs for other work' end));
    update public.clock_state set budget_alert_month = date_trunc('month', v_now at time zone 'UTC')::date where id = 1;
  end if;
  v_reason := private.clock_work(v_now);
  if v_reason is null then return jsonb_build_object('work', false); end if;
  if st.last_poke_at is not null and st.last_poke_at > v_now - interval '1 minute' then
    return jsonb_build_object('work', true, 'reason', v_reason, 'skipped', 'called less than a minute ago');
  end if;
  v_result := private.poke_n8n(v_reason);
  update public.clock_state
     set last_poke_at = case when v_result = 'sent' then v_now else last_poke_at end,
         last_reason = v_reason, last_result = v_result, updated_at = now()
   where id = 1;
  return jsonb_build_object('work', true, 'reason', v_reason, 'result', v_result);
end;
$$;

delete from public.setting where key = 'instructor_quiet_hours_on';
delete from public.setting_definition where key = 'instructor_quiet_hours_on';
update public.setting_definition set label = 'Instructors: no messages from (Pacific)' where key = 'instructor_quiet_start';
update public.setting_definition set label = 'Instructors: messages allowed again at (Pacific)' where key = 'instructor_quiet_end';
update public.setting_definition set label = 'Instructors in the urgent period: no messages from (Pacific)' where key = 'instructor_urgent_quiet_start';
update public.setting_definition set label = 'Instructors in the urgent period: messages allowed again at (Pacific)' where key = 'instructor_urgent_quiet_end';
drop function if exists private.class_lines_both(uuid);
drop function if exists private.fmt_local_both(timestamptz, text);
alter table public.instructor drop column if exists time_zone;
