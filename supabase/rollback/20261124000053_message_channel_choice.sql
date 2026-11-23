-- Rollback of 20261124000053_message_channel_choice.sql.
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
  -- Decision 333: a Draft domain sends nothing to instructors, so nothing is created or scheduled. Said in history.
  if d.id is not null and d.status = 'Draft' then
    perform private.log_event('Messages', 'Not sent: ' || d.name || ' is a draft domain', 'instructor', p_instructor, null,
      jsonb_build_object('template', p_template), 'Draft domains send nothing to instructors. Set it to Testing or Live first.',
      d.id, null, p_mw, null, p_instructor, null, private.is_test_domain(d.id));
    return 0;
  end if;
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
