-- Demo fixes, part 2 (docs/DEMO_SCRIPT.md, decision 268).
-- 1. Each Discord user is tagged once. Discord refuses a message that lists the same person twice, which
--    happened when one person was both owner and operations, or (in the Sandbox) also the test instructor.
--    The team list leaves out the instructor (already tagged in the greeting) and repeats, and every message
--    keeps each mention once.
-- 2. The task and alert about a failed message say in plain words what failed, what still reached the person
--    and where to look. The technical error stays in the admin channel and in Activity history.
-- 3. Instructor messages no longer list the materials: one line says how to get help before class instead.

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
        -- No materials list in instructor messages: one line on where to get help instead.
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
    'first_class', '', 'weekday', '', 'contact', '', 'materials', ''); end if;
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

create or replace function public.report_message_result(p_message_id uuid, p_ok boolean, p_external_id text default null,
  p_error text default null, p_permanent boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  m public.message;
  q public.request;
  v_urgent boolean := false;
  v_now timestamptz;
  v_notice boolean;
  v_reach text;
  v_what text;
  v_who text;
  v_first text;
  v_got text[];
  v_title text;
  v_fix text;
begin
  perform private.require_team();
  perform private.set_actor('System', null, 'System');
  select * into m from public.message where id = p_message_id for update;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'unknown message'); end if;
  v_now := case when m.domain_id is not null then private.domain_now(m.domain_id) else now() end;
  if p_ok then
    update public.message set status = 'Sent', sent_at = now(), external_id = p_external_id, last_error = null where id = m.id;
    perform private.log_event(case when m.channel = 'Discord' then 'Discord' else 'Messages' end,
      m.template_id || ' sent to ' || coalesce(m.recipient_label, '?') || ' via ' || private.message_route(m),
      'message', m.id, null, null, null, m.domain_id, null, m.module_week_id, null, m.instructor_id, null, m.is_test);
    return jsonb_build_object('ok', true, 'status', 'Sent');
  end if;
  if m.attempts < 3 and not p_permanent then
    update public.message set status = 'Pending', last_error = p_error where id = m.id;
    return jsonb_build_object('ok', true, 'status', 'Retry');
  end if;
  update public.message set status = 'Failed', last_error = p_error where id = m.id;
  if m.instructor_id is not null and m.channel = 'Discord' and not m.is_test then
    update public.instructor set discord_failed_at = now() where id = m.instructor_id;
  end if;
  if m.request_id is not null then
    select * into q from public.request where id = m.request_id;
    v_urgent := q.kind in ('Outreach', 'CheckIn', 'TimeChange') and q.status in ('Sent', 'Reminded')
                and private.days_until(q.module_week_id, v_now) < private.setting_int(q.module_week_id, 'short_notice_days');
  end if;
  perform private.log_event(case when m.channel = 'Discord' then 'Discord' else 'Messages' end,
    m.template_id || ' failed to ' || coalesce(m.recipient_label, '?') || ' via ' || private.message_route(m),
    'message', m.id, null, null, private.message_fix(m, p_error) || ' (' || coalesce(p_error, 'no reason given') || ')', m.domain_id, null, m.module_week_id, null, m.instructor_id, null, m.is_test);
  -- A message about a failure that fails itself is only logged (and posted in the admin channel):
  -- raising a new alert for it could go round and round.
  v_notice := m.template_id = 'T14'
              or exists (select 1 from public.attention_item ai where ai.id = m.attention_item_id and ai.type = 'MessageFailed');
  if m.audience = 'Team' and not v_notice and m.channel = 'Discord' and m.discord_dm_user_id is not null and m.team_member_id is not null then
    -- A team member's direct message failed: they get the same message by email instead.
    perform private.queue_team_message(m.template_id, m.domain_id, 'email', null, array[m.team_member_id],
      m.subject, m.body_text, coalesce(m.unique_key, m.id::text) || ':fallback', now(), false, m.attention_item_id, m.module_week_id, m.help_request_id);
  end if;
  -- Say in plain words what failed and what still reached the person, from what was really queued.
  v_what := 'The ' || coalesce(lower(private.template_defaults() -> m.template_id ->> 'name'), 'message');
  v_who := coalesce(nullif(m.recipient_label, ''), 'the person');
  v_first := coalesce(nullif(private.first_name(v_who), ''), v_who);
  v_title := v_what || case
    when m.channel = 'Discord' and m.discord_channel_id is not null and m.audience = 'Instructor'
      then ' could not be posted in ' || v_who || '''s Discord channel.'
    when m.channel = 'Discord' and m.discord_channel_id is not null then ' could not be posted in ' || v_who || '.'
    when m.channel = 'Discord' then ' could not be sent to ' || v_who || ' as a Discord direct message.'
    else ' could not be emailed to ' || v_who || '.' end;
  select array_agg(distinct case when x.channel = 'Email' then 'email'
                                 when x.discord_dm_user_id is not null then 'direct message'
                                 else 'their Discord channel' end)
    into v_got
    from public.message x
   where x.id <> m.id and x.template_id = m.template_id and x.status <> 'Failed'
     and x.module_week_id is not distinct from m.module_week_id and x.request_id is not distinct from m.request_id
     and x.help_request_id is not distinct from m.help_request_id and x.instructor_id is not distinct from m.instructor_id
     and x.team_member_id is not distinct from m.team_member_id
     and not (x.channel = m.channel and x.discord_dm_user_id is not distinct from m.discord_dm_user_id
              and x.discord_channel_id is not distinct from m.discord_channel_id);
  v_reach := case
    when m.audience = 'Team' and m.channel = 'Discord' and m.discord_dm_user_id is not null
      then ' ' || v_first || ' gets it by email instead.'
    when cardinality(v_got) > 0
      then ' ' || v_first || ' still got it by ' || array_to_string(v_got, ' and ') || '.'
    else ' It did not reach ' || v_first || ' any other way.' end;
  -- The specific advice when the error is a known one; otherwise where to look, without the technical error.
  v_fix := ' ' || private.message_fix(m, p_error);
  if p_error is not null and position(p_error in v_fix) > 0 then
    v_fix := case
      when m.channel = 'Discord' and m.discord_channel_id is not null then ' Check the channel on Settings, Connections.'
      when m.channel = 'Discord' and m.audience = 'Instructor' then ' Check their Discord account on Setup, Instructors.'
      when m.channel = 'Discord' then ' Check their Discord account on Setup, Team.'
      else ' Check the email connection on Settings, Connections.' end;
  end if;
  if m.audience <> 'Admin' and not v_notice then
    -- One task, and the alert about it goes to the operations team by email (see queue_team_message: T14).
    perform private.raise_attention(m.domain_id, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
      v_title,
      ltrim(v_reach || v_fix),
      'msgfail:' || m.id,
      coalesce(nullif(private.domain_role_ids(m.domain_id, 'Ops'), '{}'),
               private.all_operations_ids()),
      v_now, jsonb_build_object('module_week_id', m.module_week_id, 'instructor_id', m.instructor_id, 'message_id', m.id), true, 'T14');
  end if;
  if m.audience <> 'Admin' then
    perform private.queue_team_message('T14', m.domain_id, 'admin', null, '{}', 'Message failed',
      '❗ ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel || ' failed: ' || coalesce(p_error, '?'),
      'T14:' || m.id, now());
  end if;
  return jsonb_build_object('ok', true, 'status', 'Failed');
end;
$$;

create or replace function private.message_unique_mentions()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.mention_user_ids is not null then
    new.mention_user_ids := array(select x from unnest(new.mention_user_ids) with ordinality t(x, o)
                                   where x is not null group by x order by min(o));
  end if;
  return new;
end;
$$;
drop trigger if exists message_unique_mentions on public.message;
create trigger message_unique_mentions before insert or update of mention_user_ids on public.message
  for each row execute function private.message_unique_mentions();
