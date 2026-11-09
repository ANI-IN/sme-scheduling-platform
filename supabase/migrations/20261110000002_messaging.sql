-- =====================================================================================
-- Milestone 2a — Formatting, message catalogue (PRD §11.3–11.5), outbox queueing with
-- write-before-send (§9.10), quiet hours (§9.4, §9.8), test-mode routing (§11.1), attention items.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- Formatting
-- -------------------------------------------------------------------------------------
create or replace function private.html_escape(p text)
returns text language sql immutable set search_path = ''
as $$ select replace(replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;'); $$;

-- "Sun, Jan 31 · 9:00 AM PST"
create or replace function private.fmt_pt(p_ts timestamptz)
returns text language sql immutable set search_path = ''
as $$
  select to_char(p_ts at time zone 'America/Los_Angeles', 'Dy, Mon FMDD · FMHH12:MI AM') || ' ' || private.pt_abbrev(p_ts);
$$;

-- "Sun, Jan 31 · 9:00 AM – 1:00 PM PST"
create or replace function private.fmt_pt_range(p_start timestamptz, p_end timestamptz)
returns text language sql immutable set search_path = ''
as $$
  select to_char(p_start at time zone 'America/Los_Angeles', 'Dy, Mon FMDD · FMHH12:MI AM') || ' – '
      || to_char(p_end at time zone 'America/Los_Angeles', 'FMHH12:MI AM') || ' ' || private.pt_abbrev(p_start);
$$;

-- Team-facing times are in IST (PRD §12).
create or replace function private.fmt_ist(p_ts timestamptz)
returns text language sql immutable set search_path = ''
as $$ select to_char(p_ts at time zone 'Asia/Kolkata', 'Dy, Mon FMDD · FMHH12:MI AM') || ' IST'; $$;

create or replace function private.first_name(p_full text)
returns text language sql immutable set search_path = ''
as $$ select split_part(trim(coalesce(p_full, '')), ' ', 1); $$;

-- "Concurrency · Sun Jan 31 + Thu Feb 4"
create or replace function private.mw_label(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select m.name || coalesce(' (' || nullif(w.cohort, '') || ')', '') || ' · '
      || coalesce((select string_agg(to_char(c.starts_at at time zone 'America/Los_Angeles', 'Dy Mon FMDD'), ' + ' order by c.starts_at)
                     from public.class_session c where c.module_week_id = w.id and c.status <> 'Cancelled'), 'no classes')
    from public.module_week w join public.module m on m.id = w.module_id where w.id = p_mw;
$$;

-- -------------------------------------------------------------------------------------
-- Clock: real time, or the domain's test clock (PRD TST-2)
-- -------------------------------------------------------------------------------------
create or replace function private.domain_now(p_domain uuid)
returns timestamptz language sql stable security definer set search_path = ''
as $$
  -- app.test_now is a session-only override used by the database tests and the mock runner.
  select coalesce(nullif(current_setting('app.test_now', true), '')::timestamptz,
                  (select d.test_clock_at from public.domain d where d.id = p_domain and d.status = 'Test'), now());
$$;

-- Days (fractional) from p_now until the first class of the module week.
create or replace function private.days_until(p_mw uuid, p_now timestamptz)
returns numeric language sql stable security definer set search_path = ''
as $$
  select extract(epoch from (w.first_class_at - p_now)) / 86400.0 from public.module_week w where w.id = p_mw;
$$;

-- Response-window band for a module week at a moment: Long (> short_notice_days), Mid, Short (< urgent band).
create or replace function private.band(p_mw uuid, p_now timestamptz)
returns text language sql stable security definer set search_path = ''
as $$
  select case
    when private.days_until(p_mw, p_now) > private.setting_int(w.domain_id, 'short_notice_days') then 'Long'
    when private.days_until(p_mw, p_now) >= private.setting_int(w.domain_id, 'urgent_band_days') then 'Mid'
    else 'Short' end
  from public.module_week w where w.id = p_mw;
$$;

-- Next moment at or after p_ts outside a local quiet window [p_start, p_end) in zone p_zone.
create or replace function private.next_allowed(p_ts timestamptz, p_zone text, p_start text, p_end text)
returns timestamptz language plpgsql immutable set search_path = ''
as $$
declare
  v_local timestamp := p_ts at time zone p_zone;
  v_t time := v_local::time;
  v_s time := p_start::time;
  v_e time := p_end::time;
begin
  if v_s = v_e then
    return p_ts;
  elsif v_s > v_e then                      -- window crosses midnight, e.g. 21:00 → 08:00
    if v_t >= v_s then
      return ((v_local::date + 1) + v_e) at time zone p_zone;
    elsif v_t < v_e then
      return (v_local::date + v_e) at time zone p_zone;
    end if;
  elsif v_t >= v_s and v_t < v_e then       -- window inside one day, e.g. 01:00 → 06:00
    return (v_local::date + v_e) at time zone p_zone;
  end if;
  return p_ts;
end;
$$;

-- Instructor quiet hours (PT). The urgent band uses the narrower urgent window.
create or replace function private.instructor_send_time(p_domain uuid, p_ts timestamptz, p_urgent boolean)
returns timestamptz language sql stable set search_path = ''
as $$
  select case when p_urgent
    then private.next_allowed(p_ts, 'America/Los_Angeles',
           private.setting_text(p_domain, 'instructor_urgent_quiet_start'), private.setting_text(p_domain, 'instructor_urgent_quiet_end'))
    else private.next_allowed(p_ts, 'America/Los_Angeles',
           private.setting_text(p_domain, 'instructor_quiet_start'), private.setting_text(p_domain, 'instructor_quiet_end'))
  end;
$$;

-- Team quiet hours (IST), for non-urgent reminders.
create or replace function private.team_send_time(p_domain uuid, p_ts timestamptz)
returns timestamptz language sql stable set search_path = ''
as $$
  select private.next_allowed(p_ts, 'Asia/Kolkata',
           private.setting_text(p_domain, 'team_quiet_start'), private.setting_text(p_domain, 'team_quiet_end'));
$$;

-- -------------------------------------------------------------------------------------
-- People helpers
-- -------------------------------------------------------------------------------------
create or replace function private.module_owner_ids(p_module uuid)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(o.team_member_id order by t.name), '{}')
    from public.module_owner o join public.team_member t on t.id = o.team_member_id
   where o.module_id = p_module and t.active;
$$;

create or replace function private.domain_role_ids(p_domain uuid, p_role text)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(dt.team_member_id order by t.name), '{}')
    from public.domain_team dt join public.team_member t on t.id = dt.team_member_id
   where dt.domain_id = p_domain and dt.role = p_role and t.active;
$$;

-- Owners of the module, or the domain leads when the module has no owner (PRD edge case 31).
create or replace function private.owners_or_leads(p_module uuid)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select case when cardinality(private.module_owner_ids(p_module)) > 0 then private.module_owner_ids(p_module)
              else private.domain_role_ids((select m.domain_id from public.module m where m.id = p_module), 'Lead') end;
$$;

create or replace function private.uniq(p uuid[])
returns uuid[] language sql immutable set search_path = ''
as $$ select coalesce(array_agg(distinct x), '{}') from unnest(p) x where x is not null; $$;

create or replace function private.team_names(p uuid[])
returns text language sql stable security definer set search_path = ''
as $$ select coalesce(string_agg(t.name, ', ' order by t.name), 'the team') from public.team_member t where t.id = any (p); $$;

create or replace function private.team_discord_ids(p uuid[])
returns text[] language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(t.discord_user_id), '{}') from public.team_member t
   where t.id = any (p) and t.discord_user_id is not null and t.active;
$$;

-- -------------------------------------------------------------------------------------
-- Response links (PRD §11.2): random single-use token per (request, answer)
-- -------------------------------------------------------------------------------------
create or replace function private.new_token()
returns text language sql volatile set search_path = ''
as $$ select rtrim(translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_'), '='); $$;

create or replace function private.link_for(p_request uuid, p_answer text)
returns text language plpgsql volatile security definer set search_path = ''
as $$
declare v_token text;
begin
  select token into v_token from public.response_link where request_id = p_request and answer = p_answer;
  if v_token is null then
    v_token := private.new_token();
    insert into public.response_link (token, request_id, answer) values (v_token, p_request, p_answer);
  end if;
  return coalesce((select c.response_base_url from public.app_config c where c.id = 1), 'https://RESPONSE_BASE_URL_NOT_SET')
      || '?t=' || v_token;
end;
$$;

create or replace function private.answer_label(p_answer text)
returns text language sql immutable set search_path = ''
as $$
  select case p_answer
    when 'Yes' then '✅ Yes, I can teach'
    when 'No' then '❌ No, I can''t'
    when 'NeedHelp' then '🙋 Need help'
    when 'CantMakeIt' then 'Can''t make it'
    when 'CantMakeItAnymore' then 'Can''t make it anymore'
    when 'AllSet' then '👍 All set'
    when 'StillWorks' then '✅ Still works'
    when 'DoesntWork' then '❌ Doesn''t work'
    when 'GotIt' then '✅ Got it'
    when 'OwnerAllGood' then '👍 All good'
    when 'OwnerNeedHelp' then '🙋 Need help'
    when 'NeedMoreHelp' then '🙋 Need more help'
    else p_answer end;
$$;

-- Buttons for a request: [{label, url, answer}]
create or replace function private.buttons(p_request uuid, p_answers text[])
returns jsonb language sql volatile security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', private.answer_label(a),
           'answer', case when a = 'CantMakeItAnymore' then 'CantMakeIt' when a = 'NeedMoreHelp' then 'NeedHelp' else a end,
           'url', private.link_for(p_request, case when a = 'CantMakeItAnymore' then 'CantMakeIt' when a = 'NeedMoreHelp' then 'NeedHelp' else a end))
         order by o), '[]'::jsonb)
    from unnest(p_answers) with ordinality as x(a, o);
$$;

-- -------------------------------------------------------------------------------------
-- Module-week context used by templates
-- -------------------------------------------------------------------------------------
create or replace function private.class_lines(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(string_agg('• ' || c.class_type || ': ' || private.fmt_pt_range(c.starts_at, c.ends_at), E'\n' order by c.starts_at), '')
    from public.class_session c where c.module_week_id = p_mw and c.status <> 'Cancelled';
$$;

create or replace function private.materials_line(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(string_agg(r.title || ': ' || r.url, E'\n' order by r.sort_order, r.title), '')
    from public.module_week w join public.module_resource r on r.module_id = w.module_id
   where w.id = p_mw and r.include_in_confirmation;
$$;

-- -------------------------------------------------------------------------------------
-- Message catalogue — instructors (M1–M15). Fixed text, variables filled in by code.
-- Returns {subject, lines[]} ; the greeting line is added per channel.
-- -------------------------------------------------------------------------------------
create or replace function private.render_instructor(p_template text, p_mw uuid, p_instructor uuid, p_extra jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_mod text; v_dom text; v_name text;
  v_classes text := '';
  v_first timestamptz;
  v_materials text := '';
  v_contact text;
  v_subject text;
  v_body text;
  v_deadline text := p_extra ->> 'deadline';
begin
  select i.full_name into v_name from public.instructor i where i.id = p_instructor;
  if p_mw is not null then
    select m.name, d.name, w.first_class_at, private.team_names(private.owners_or_leads(m.id))
      into v_mod, v_dom, v_first, v_contact
      from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id
     where w.id = p_mw;
    v_classes := private.class_lines(p_mw);
    v_materials := private.materials_line(p_mw);
  end if;

  case p_template
  when 'M1' then
    v_subject := format('Can you teach %s? (%s)', v_mod, private.fmt_pt(v_first));
    v_body := format(E'Can you teach %s for the %s cohort?\n\n%s\n\nPlease reply by %s.', v_mod, v_dom, v_classes, v_deadline);
  when 'M2' then
    v_subject := format('Reminder: can you teach %s?', v_mod);
    v_body := format(E'Friendly reminder — can you teach %s for the %s cohort?\n\n%s\n\nPlease reply by %s.', v_mod, v_dom, v_classes, v_deadline);
  when 'M3' then
    v_subject := format('%s — no worries', v_mod);
    v_body := format('No worries — we''ll check with you next time. (We''ve closed the request for %s.)', v_mod);
  when 'M4' then
    v_subject := format('You''re confirmed for %s 🎉', v_mod);
    v_body := format(E'Thank you — you''re confirmed for %s 🎉\n\n%s%s\n\nYour contact: %s',
      v_mod, v_classes, case when v_materials <> '' then E'\n\nMaterials:\n' || v_materials else '' end, v_contact);
  when 'M5' then
    v_subject := format('%s moved — does this still work?', v_mod);
    v_body := format(E'%s moved to new times:\n\n%s\n\nDoes this still work?%s', v_mod, v_classes,
      case when v_deadline is not null then E'\nPlease reply by ' || v_deadline || '.' else '' end);
  when 'M6' then
    v_subject := format('%s is in %s days — all set?', v_mod, p_extra ->> 'days');
    v_body := format(E'%s is %s days away (%s). Anything you need?\n\n%s%s', v_mod, p_extra ->> 'days', private.fmt_pt(v_first),
      v_classes, case when v_materials <> '' then E'\n\nMaterials:\n' || v_materials else '' end);
  when 'M7' then
    v_subject := format('%s is on %s', v_mod, to_char(v_first at time zone 'America/Los_Angeles', 'FMDay'));
    v_body := format(E'%s is on %s.\n\n%s%s\n\nAll set?', v_mod, private.fmt_pt(v_first), v_classes,
      case when v_materials <> '' then E'\n\nMaterials:\n' || v_materials else '' end);
  when 'M8' then
    v_subject := format('%s in %s days — prep check-in', v_mod, p_extra ->> 'days');
    v_body := format(E'%s is %s days away (%s). How is your prep going?\n\n%s', v_mod, p_extra ->> 'days', private.fmt_pt(v_first), v_classes);
  when 'M9' then
    v_subject := format('Reminder: %s check-in', v_mod);
    v_body := format(E'Quick reminder — %s is coming up (%s). Please let us know you''re all set.', v_mod, private.fmt_pt(v_first));
  when 'M10' then
    v_subject := format('%s — thanks for letting us know', v_mod);
    v_body := 'Thanks for letting us know — we''ll take it from here.';
  when 'M11' then
    v_subject := format('%s — class cancelled', v_mod);
    v_body := format(E'We''re sorry — we''ve had to cancel %s:\n\n%s\n\nThank you for your flexibility. Nothing else is needed from you.',
      coalesce(p_extra ->> 'what', v_mod), coalesce(p_extra ->> 'classes', v_classes));
  when 'M12' then
    v_subject := format('%s — no longer needed', v_mod);
    v_body := format('Thanks — this one''s no longer needed (%s). No action required.', v_mod);
  when 'M13' then
    v_subject := format('%s — help request received', v_mod);
    v_body := format('Got it — %s will reply by %s.', p_extra ->> 'helper', p_extra ->> 'by');
  when 'M14' then
    v_subject := format('%s — reply to your help request', coalesce(v_mod, 'SME Scheduling'));
    v_body := format(E'%s\n\n— %s', p_extra ->> 'text', p_extra ->> 'from');
  when 'M15' then
    v_subject := 'Test message from SME Scheduling';
    v_body := 'This is a test from SME Scheduling — please tap to confirm you received it.';
  else
    raise exception 'Unknown instructor template %', p_template;
  end case;
  return jsonb_build_object('subject', v_subject, 'body', v_body, 'first_name', private.first_name(v_name), 'name', v_name);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Queue an instructor message on each channel (write-before-send). Returns rows inserted.
-- Unique key: template:request:time_version:channel (or module week + instructor when no request).
-- -------------------------------------------------------------------------------------
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
begin
  select * into i from public.instructor where id = p_instructor;
  if p_mw is not null then
    select w.domain_id, w.time_version into v_domain, v_tv from public.module_week w where w.id = p_mw;
  end if;
  if p_request is not null then
    select r.time_version into v_tv from public.request r where r.id = p_request;
  end if;
  select * into d from public.domain where id = v_domain;
  v_test := coalesce(d.status = 'Test', false);
  v_channels := private.setting_text(v_domain, 'instructor_channels');
  v_r := private.render_instructor(p_template, p_mw, p_instructor, p_extra);
  if v_test then
    v_prefix := '[TEST → would go to ' || i.full_name || '] ';
  end if;
  v_send := private.instructor_send_time(v_domain, p_now, p_urgent);

  select coalesce(string_agg(format('<a href="%s" style="display:inline-block;margin:4px 8px 4px 0;padding:10px 16px;background:#1f6feb;color:#fff;border-radius:6px;text-decoration:none;font-weight:600">%s</a>',
                                    private.html_escape(b ->> 'url'), private.html_escape(b ->> 'label')), ''), '')
    into v_btn_html from jsonb_array_elements(p_buttons) b;

  foreach v_ch in array array['Discord', 'Email'] loop
    continue when p_only_channel is not null and v_ch <> p_only_channel;
    continue when v_ch = 'Discord' and v_channels = 'EmailOnly';
    continue when v_ch = 'Email' and v_channels = 'DiscordOnly';
    continue when v_ch = 'Discord' and not v_test and i.discord_channel_id is null;
    continue when v_ch = 'Email' and not v_test and coalesce(i.primary_email, '') = '';
    v_key := p_template || ':' || coalesce(p_request::text, coalesce(p_mw::text, '-') || ':' || p_instructor::text)
             || ':' || coalesce(v_tv, 0) || ':' || v_ch || coalesce(nullif(':' || p_key_suffix, ':'), '');
    if v_ch = 'Discord' then
      v_text := v_prefix || 'Hi ' ||
                case when i.discord_user_id is not null and (not v_test or i.is_test) then '<@' || i.discord_user_id || '>'
                     else (v_r ->> 'first_name') end
                || ' 👋 ' || (v_r ->> 'body');
      v_html := null;
    else
      v_text := v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')
                || case when jsonb_array_length(p_buttons) > 0 then E'\n\n' ||
                     (select string_agg((b ->> 'label') || ': ' || (b ->> 'url'), E'\n') from jsonb_array_elements(p_buttons) b) else '' end
                || E'\n\n— SME Scheduling';
      v_html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#1f2328">'
                || replace(private.html_escape(v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')), E'\n', '<br>')
                || case when v_btn_html <> '' then '<p style="margin-top:16px">' || v_btn_html || '</p>' else '' end
                || '<p style="color:#59636e;font-size:13px">— SME Scheduling</p></div>';
    end if;
    insert into public.message (
      domain_id, audience, template_id, channel, unique_key, status, not_before, instructor_id, module_week_id,
      request_id, help_request_id, recipient_label, to_address, discord_channel_id, mention_user_ids, subject,
      body_text, body_html, buttons, is_test)
    values (
      v_domain, 'Instructor', p_template, v_ch, v_key,
      case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, p_instructor, p_mw,
      p_request, p_help_request, i.full_name,
      case when v_ch = 'Email' then case when v_test then d.test_email else i.primary_email end end,
      case when v_ch = 'Discord' then case when v_test then d.test_discord_channel_id else i.discord_channel_id end end,
      case when v_ch = 'Discord' and i.discord_user_id is not null and (not v_test or i.is_test) then array[i.discord_user_id] else '{}' end,
      v_prefix || (v_r ->> 'subject'), v_text, v_html, p_buttons, v_test)
    on conflict (unique_key) where unique_key is not null do nothing;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
  end loop;
  return v_count;
end;
$$;

-- -------------------------------------------------------------------------------------
-- Team messages (T1–T15, reminders).
--   p_target: 'alert' (domain alert channel), 'admin' (admin channel) or 'person' (p_person).
-- -------------------------------------------------------------------------------------
create or replace function private.queue_team_message(
  p_template text,
  p_domain uuid,
  p_target text,
  p_person uuid,
  p_mentions uuid[],
  p_subject text,
  p_text text,
  p_key text,
  p_now timestamptz,
  p_quiet boolean default false,
  p_attention uuid default null,
  p_mw uuid default null,
  p_help uuid default null
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  d public.domain;
  t public.team_member;
  v_test boolean;
  v_prefix text := '';
  v_send timestamptz := p_now;
  v_channel text;
  v_count int := 0;
  v_n int;
  v_ch text;
  v_mentions text[] := private.team_discord_ids(p_mentions);
  v_app text := (select c.app_base_url from public.app_config c where c.id = 1);
  v_text text;
begin
  select * into d from public.domain where id = p_domain;
  v_test := coalesce(d.status = 'Test', false);
  if v_test then v_prefix := '[TEST] '; end if;
  if p_quiet then
    v_send := private.team_send_time(p_domain, p_now);
  end if;
  v_text := p_text || case when v_app is not null then E'\nOpen the app: ' || v_app else '' end;

  if p_target in ('alert', 'admin') then
    v_channel := case when p_target = 'admin' then (select c.admin_discord_channel_id from public.app_config c where c.id = 1)
                      when v_test then d.test_discord_channel_id else d.alert_discord_channel_id end;
    if v_channel is null and p_target = 'alert' then
      v_channel := (select c.admin_discord_channel_id from public.app_config c where c.id = 1);
    end if;
    insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before,
      module_week_id, help_request_id, attention_item_id, recipient_label, discord_channel_id, mention_user_ids,
      subject, body_text, is_test)
    values (p_domain, case when p_target = 'admin' then 'Admin' else 'Team' end, p_template, 'Discord', p_key || ':Discord',
      case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, p_mw, p_help, p_attention,
      case when p_target = 'admin' then 'Admin channel' else coalesce(d.name, '') || ' alert channel' end,
      v_channel, v_mentions, v_prefix || p_subject,
      v_prefix || case when cardinality(v_mentions) > 0
                       then (select string_agg('<@' || m || '>', ' ') from unnest(v_mentions) m) || ' ' else '' end || v_text,
      v_test)
    on conflict (unique_key) where unique_key is not null do nothing;
    get diagnostics v_count = row_count;
  else
    select * into t from public.team_member where id = p_person;
    if t.id is null or not t.active then
      return 0;
    end if;
    foreach v_ch in array array['Discord', 'Email'] loop
      continue when v_ch = 'Discord' and (t.digest_channel = 'Email' or t.discord_user_id is null);
      -- Email when the person chose it, or when the domain sends team reminders by Discord and email.
      continue when v_ch = 'Email' and t.digest_channel = 'Discord'
                    and private.setting_text(p_domain, 'team_channels') <> 'DiscordAndEmail';
      insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before,
        team_member_id, module_week_id, help_request_id, attention_item_id, recipient_label, to_address,
        discord_dm_user_id, subject, body_text, is_test)
      values (p_domain, 'Team', p_template, v_ch, p_key || ':' || t.id || ':' || v_ch,
        case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, t.id, p_mw, p_help, p_attention, t.name,
        case when v_ch = 'Email' then t.email end,
        case when v_ch = 'Discord' then t.discord_user_id end,
        v_prefix || p_subject, v_prefix || v_text, v_test)
      on conflict (unique_key) where unique_key is not null do nothing;
      get diagnostics v_n = row_count;
      v_count := v_count + v_n;
    end loop;
  end if;
  return v_count;
end;
$$;

-- -------------------------------------------------------------------------------------
-- Attention items (PRD §7.3, §9.8)
-- Urgent items notify immediately (R1 now); normal items wait for the daily digest.
-- -------------------------------------------------------------------------------------
create or replace function private.raise_attention(
  p_domain uuid,
  p_type text,
  p_severity text,
  p_title text,
  p_detail text,
  p_dedupe text,
  p_recipients uuid[],
  p_now timestamptz,
  p_refs jsonb default '{}',
  p_notify_now boolean default false,     -- post R1 now even for Normal items (e.g. T5 class at risk, T7 need help)
  p_alert_template text default 'R1'
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  a public.attention_item;
  v_new boolean := false;
  v_upgraded boolean := false;
  v_test boolean := coalesce((select d.status = 'Test' from public.domain d where d.id = p_domain), false);
begin
  if p_dedupe is not null then
    select * into a from public.attention_item where dedupe_key = p_dedupe and status <> 'Done' for update;
  end if;
  if a.id is null then
    insert into public.attention_item (domain_id, type, severity, title, detail, dedupe_key, recipients, opened_at,
      module_id, module_week_id, class_id, instructor_id, request_id, help_request_id, message_id, is_test, due_at)
    values (p_domain, p_type, p_severity, p_title, p_detail, p_dedupe, private.uniq(p_recipients), p_now,
      (p_refs ->> 'module_id')::uuid, (p_refs ->> 'module_week_id')::uuid, (p_refs ->> 'class_id')::uuid,
      (p_refs ->> 'instructor_id')::uuid, (p_refs ->> 'request_id')::uuid, (p_refs ->> 'help_request_id')::uuid,
      (p_refs ->> 'message_id')::uuid, v_test, (p_refs ->> 'due_at')::timestamptz)
    returning * into a;
    v_new := true;
    perform private.log_event('Reminders', 'Needs attention: ' || p_title, 'attention_item', a.id, null,
      jsonb_build_object('type', p_type, 'severity', p_severity), p_detail, p_domain,
      a.module_id, a.module_week_id, a.class_id, a.instructor_id, null, v_test);
  else
    if p_severity = 'Urgent' and a.severity = 'Normal' then
      v_upgraded := true;
    end if;
    update public.attention_item
       set severity = case when p_severity = 'Urgent' then 'Urgent' else severity end,
           title = p_title,
           detail = coalesce(p_detail, detail),
           recipients = private.uniq(recipients || p_recipients)
     where id = a.id
    returning * into a;
  end if;

  if (v_new and p_notify_now) or ((v_new or v_upgraded) and a.severity = 'Urgent') then
    perform private.queue_team_message(p_alert_template, p_domain, 'alert', null,
      case when a.assigned_to is not null then array[a.assigned_to] else a.recipients end,
      case when a.severity = 'Urgent' then '🚨 ' else '' end || a.title,
      case when a.severity = 'Urgent' then '🚨 Urgent: ' else 'Needs attention: ' end || a.title || coalesce(E'\n' || a.detail, ''),
      'R1:' || a.id || ':' || a.severity, p_now, false, a.id, a.module_week_id, a.help_request_id);
    update public.attention_item set r1_at = p_now, last_reminder_at = p_now where id = a.id;
    insert into public.reminder (attention_item_id, recipient, level, sent_at)
    select a.id, r, 'R1', p_now from unnest(a.recipients) r;
  end if;
  return a.id;
end;
$$;

create or replace function private.resolve_attention(p_dedupe text, p_note text)
returns void language plpgsql security definer set search_path = ''
as $$
declare a record;
begin
  for a in update public.attention_item
              set status = 'Done', done_at = now(), done_note = p_note
            where dedupe_key = p_dedupe and status <> 'Done'
           returning id, title, domain_id, module_week_id loop
    perform private.log_event('Reminders', 'Resolved automatically: ' || a.title, 'attention_item', a.id,
      null, null, p_note, a.domain_id, null, a.module_week_id);
  end loop;
end;
$$;
