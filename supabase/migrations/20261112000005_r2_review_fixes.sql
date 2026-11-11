-- Release 2 Milestone F: fixes for the findings of the independent reviews (docs/reviews).
-- Each block names the finding it fixes, for example DIS-1 (docs/reviews/discord-and-notifications.md).


-- ------------------------------------------------------------------ DIS-6: one place for channels
-- Release 1 kept one channel per instructor on the instructor row. Release 2 copied it into
-- instructor_channel (one per domain); from now on only instructor_channel is used, so choosing
-- "No channel" really means a direct message. The old values are cleared without touching the
-- contact check (the channel itself did not change: it moved).
alter table public.instructor disable trigger instructor_before_write;
alter table public.instructor disable trigger instructor_history;
update public.instructor set discord_channel_id = null, discord_channel_link = null
 where discord_channel_id is not null or discord_channel_link is not null;
alter table public.instructor enable trigger instructor_history;
alter table public.instructor enable trigger instructor_before_write;

-- ------------------------------------------------------------------ DIS-12: can the bot post there?
alter table public.discord_channel add column if not exists bot_can_post boolean;
comment on column public.discord_channel.bot_can_post is
  'Whether the bot''s roles allow View Channels and Send Messages in this channel (null: not known yet).';
alter table public.app_config add column if not exists discord_bot_user_id text;

/** Discord permission maths: the bot's server roles, then the channel's overwrites (everyone, roles, the bot). */
create or replace function private.discord_can_post(p_channel jsonb, p_server text, p_roles jsonb, p_bot_roles jsonb, p_bot_id text)
returns boolean language plpgsql immutable set search_path = ''
as $$
declare
  v bigint := 0;
  r jsonb;
  o jsonb;
  v_allow bigint := 0;
  v_deny bigint := 0;
  v_mine text[] := array(select jsonb_array_elements_text(coalesce(p_bot_roles, '[]')));
begin
  if p_roles is null or jsonb_typeof(p_roles) <> 'array' then return null; end if;
  for r in select * from jsonb_array_elements(p_roles) loop
    if r ->> 'id' = p_server or (r ->> 'id') = any (v_mine) then
      v := v | coalesce((r ->> 'permissions')::bigint, 0);
    end if;
  end loop;
  if v & 8 <> 0 then return true; end if;   -- Administrator
  for o in select * from jsonb_array_elements(coalesce(p_channel -> 'permission_overwrites', '[]')) where value ->> 'id' = p_server loop
    v := (v & ~coalesce((o ->> 'deny')::bigint, 0)) | coalesce((o ->> 'allow')::bigint, 0);
  end loop;
  for o in select * from jsonb_array_elements(coalesce(p_channel -> 'permission_overwrites', '[]'))
            where (value ->> 'type')::int = 0 and value ->> 'id' = any (v_mine) loop
    v_allow := v_allow | coalesce((o ->> 'allow')::bigint, 0);
    v_deny := v_deny | coalesce((o ->> 'deny')::bigint, 0);
  end loop;
  v := (v & ~v_deny) | v_allow;
  for o in select * from jsonb_array_elements(coalesce(p_channel -> 'permission_overwrites', '[]'))
            where (value ->> 'type')::int = 1 and value ->> 'id' = p_bot_id loop
    v := (v & ~coalesce((o ->> 'deny')::bigint, 0)) | coalesce((o ->> 'allow')::bigint, 0);
  end loop;
  return v & 1024 <> 0 and v & 2048 <> 0;
end;
$$;
revoke execute on function private.discord_can_post(jsonb, text, jsonb, jsonb, text) from public;

create or replace function public.record_discord_result(p_action_id uuid, p_result jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  a public.action_queue;
  d public.domain;
  v_kind text;
  v_id uuid;
  v_user text;
  v_name text;
  v_label text;
  v_status text;
  v_problem text;
  v_out jsonb;
  s jsonb;
  v_denied text[] := '{}';
  v_searched text[] := '{}';
  v_server_name text;
  v_n int;
begin
  if not private.is_service() then
    raise exception 'Only the automation can do this.' using errcode = '42501';
  end if;
  select * into a from public.action_queue where id = p_action_id;
  if a.id is null then raise exception 'Unknown action.' using errcode = '22023'; end if;

  if (p_result #>> '{me,status}')::int = 200 and p_result #>> '{me,body,id}' is not null then
    update public.app_config set discord_bot_user_id = p_result #>> '{me,body,id}' where id = 1
       and discord_bot_user_id is distinct from p_result #>> '{me,body,id}';
  end if;

  if a.action = 'discord_servers' then
    if (p_result #>> '{guilds,status}')::int = 200 then
      delete from public.discord_server where id not in (select x ->> 'id' from jsonb_array_elements(p_result #> '{guilds,body}') x);
      insert into public.discord_server (id, name, refreshed_at)
      select x ->> 'id', x ->> 'name', now() from jsonb_array_elements(p_result #> '{guilds,body}') x
      on conflict (id) do update set name = excluded.name, refreshed_at = now();
      get diagnostics v_n = row_count;
      v_out := jsonb_build_object('ok', true, 'servers', v_n);
      perform private.log_event('Discord', 'Discord servers listed', null, null, null, v_out,
        'The bot is in ' || v_n || ' server' || case when v_n = 1 then '' else 's' end || '.');
    else
      v_problem := private.discord_http_problem((p_result #>> '{guilds,status}')::int, null);
      v_out := jsonb_build_object('ok', false, 'problem', v_problem);
      perform private.log_event('Discord', 'Discord check failed', null, null, null, v_out, v_problem);
    end if;

  elsif a.action = 'discord_server' then
    select * into d from public.domain where id = (a.payload ->> 'domain_id')::uuid;
    v_status := 'Ready';
    if coalesce((p_result #>> '{guild,status}')::int, 0) <> 200 then
      v_status := 'Problem';
      v_problem := private.discord_http_problem((p_result #>> '{guild,status}')::int, d.discord_server_id);
    else
      v_server_name := p_result #>> '{guild,body,name}';
      insert into public.discord_server (id, name) values (d.discord_server_id, v_server_name)
      on conflict (id) do update set name = excluded.name, refreshed_at = now();
      if coalesce((p_result #>> '{channels,status}')::int, 0) = 200 then
        delete from public.discord_channel where server_id = d.discord_server_id;
        insert into public.discord_channel (id, server_id, name, category, position, bot_can_post)
        select c ->> 'id', d.discord_server_id, c ->> 'name', cat ->> 'name', coalesce((c ->> 'position')::int, 0),
               case when (p_result #>> '{roles,status}')::int = 200 and (p_result #>> '{bot,status}')::int = 200
                    then private.discord_can_post(c, d.discord_server_id, p_result #> '{roles,body}',
                                                  p_result #> '{bot,body,roles}', p_result #>> '{bot,body,user,id}') end
          from jsonb_array_elements(p_result #> '{channels,body}') c
          left join lateral (select k from jsonb_array_elements(p_result #> '{channels,body}') k
                              where k ->> 'id' = c ->> 'parent_id' and (k ->> 'type')::int = 4 limit 1) x(cat) on true
         where (c ->> 'type')::int in (0, 5)
        on conflict (id) do update set server_id = excluded.server_id, name = excluded.name, category = excluded.category,
                                       position = excluded.position, bot_can_post = excluded.bot_can_post, refreshed_at = now();
        get diagnostics v_n = row_count;
        -- Keep the names of chosen channels up to date.
        update public.instructor_channel ic set channel_name = c.name, version = ic.version
          from public.discord_channel c where c.id = ic.channel_id and ic.channel_name is distinct from c.name;
        -- Only channels the bot may post in count.
        v_n := (select count(*) from public.discord_channel c where c.server_id = d.discord_server_id and c.bot_can_post is not false);
        -- DIS-11: an instructor channel that is gone (or the bot lost access) becomes a task now,
        -- before a message fails on it.
        perform private.raise_attention(d.id, 'Other', 'Normal',
          'Discord channel gone: ' || i.full_name,
          'The Discord channel #' || coalesce(ic.channel_name, '?') || ' of ' || i.full_name || ' in ' || d.name
            || case when ch.id is null then ' no longer exists or the bot cannot see it.' else ' does not let the bot post.' end
            || ' Choose a new channel on Setup, Instructors.',
          'channel-gone:' || ic.instructor_id || ':' || ic.domain_id,
          coalesce(nullif(private.domain_role_ids(d.id, 'Ops'), '{}'), private.all_operations_ids()), now(),
          jsonb_build_object('instructor_id', ic.instructor_id), false)
          from public.instructor_channel ic join public.instructor i on i.id = ic.instructor_id
          left join public.discord_channel ch on ch.id = ic.channel_id
         where ic.domain_id = d.id and i.status = 'Active' and (ch.id is null or ch.bot_can_post = false);
        if v_n = 0 then
          v_status := 'Problem';
          v_problem := 'The bot cannot see any text channels in ' || coalesce(v_server_name, 'this server')
            || '. Give the bot''s role access to the 1-1 category (View Channels, Send Messages, Embed Links, Read Message History).';
        end if;
      else
        v_status := 'Problem';
        v_problem := 'The bot could not list the channels of ' || coalesce(v_server_name, 'this server') || '. Give the bot''s role the View Channels permission.';
      end if;
      if v_status = 'Ready' and coalesce((p_result #>> '{members,status}')::int, 200) <> 200 then
        v_status := 'Problem';
        v_problem := 'The bot cannot search the members of ' || coalesce(v_server_name, 'this server')
          || ', so it cannot find people by username. In the Discord Developer Portal, open the bot and turn on Server Members Intent.';
      end if;
    end if;
    update public.domain set discord_status = v_status, discord_problem = v_problem, discord_checked_at = now(), version = version
     where id = d.id;
    v_out := jsonb_build_object('ok', v_status = 'Ready', 'status', v_status, 'problem', v_problem, 'channels', v_n);
    perform private.log_event('Discord', case when v_status = 'Ready' then 'Discord server checked' else 'Discord server has a problem' end,
      'domain', d.id, null, v_out, coalesce(v_problem, coalesce(v_server_name, 'The server') || ' is ready: ' || coalesce(v_n, 0) || ' channels.'),
      d.id, null, null, null, null, null, false, null, d.name);

  elsif a.action = 'discord_member' then
    v_kind := a.payload ->> 'kind';
    v_id := (a.payload ->> 'id')::uuid;
    if v_kind = 'instructor' then
      select discord_username, full_name into v_name, v_label from public.instructor where id = v_id;
    else
      select discord_username, name into v_name, v_label from public.team_member where id = v_id;
    end if;
    if a.payload ? 'username' and a.payload ->> 'username' is distinct from v_name then
      -- The username changed while Discord was being searched: look again for the new one.
      update public.action_queue set status = 'Done', result = jsonb_build_object('ok', true, 'stale', true), processed_at = now()
       where id = p_action_id;
      perform private.queue_discord_member(v_kind, v_id);
      return jsonb_build_object('ok', true, 'status', 'Checking', 'stale', true);
    end if;
    for s in select * from jsonb_array_elements(coalesce(p_result -> 'searches', '[]')) loop
      v_server_name := coalesce((select name from public.discord_server where id = s ->> 'server_id'), 'the server');
      if (s ->> 'status')::int = 200 then
        v_searched := v_searched || v_server_name;
        select m #>> '{user,id}' into v_user from jsonb_array_elements(coalesce(s -> 'body', '[]')) m
         where lower(m #>> '{user,username}') = v_name limit 1;
        exit when v_user is not null;
      else
        v_denied := v_denied || v_server_name;
      end if;
    end loop;
    if v_name is null then
      v_status := 'NotSet';
    elsif v_user is not null then
      v_status := 'Found';
    elsif cardinality(v_searched) = 0 and cardinality(v_denied) > 0 then
      v_status := 'Problem';
      v_problem := 'The bot cannot search the members of ' || array_to_string(v_denied, ', ')
        || '. In the Discord Developer Portal, open the bot and turn on Server Members Intent, then press Check Discord.';
    elsif cardinality(v_searched) = 0 then
      v_status := 'Problem';
      v_problem := 'No Discord server is set up yet. Choose the server of each domain on Connections, then press Check Discord.';
    else
      v_status := 'NotFound';
      v_problem := 'Nobody with the username ' || v_name || ' is in ' || array_to_string(v_searched, ', ')
        || '. Check the spelling (lowercase, without @) and that they joined the server, then press Check Discord.';
    end if;
    begin
      if v_kind = 'instructor' then
        update public.instructor set discord_user_id = case when v_status = 'Found' then v_user else discord_user_id end,
               discord_status = v_status, discord_problem = v_problem, discord_checked_at = now(), version = version
         where id = v_id and discord_username is not distinct from v_name;
      else
        update public.team_member set discord_user_id = case when v_status = 'Found' then v_user else discord_user_id end,
               discord_status = v_status, discord_problem = v_problem, discord_checked_at = now(), version = version
         where id = v_id and discord_username is not distinct from v_name;
      end if;
    exception when unique_violation then
      v_status := 'Problem';
      v_problem := 'This Discord account is already used by '
        || coalesce((select full_name from public.instructor where discord_user_id = v_user and id <> v_id limit 1),
                    (select name from public.team_member where discord_user_id = v_user and id <> v_id limit 1), 'someone else')
        || '. Check the username.';
      v_user := null;
      if v_kind = 'instructor' then
        update public.instructor set discord_user_id = null, discord_status = v_status, discord_problem = v_problem,
               discord_checked_at = now(), version = version where id = v_id;
      else
        update public.team_member set discord_user_id = null, discord_status = v_status, discord_problem = v_problem,
               discord_checked_at = now(), version = version where id = v_id;
      end if;
    end;
    v_out := jsonb_build_object('ok', v_status = 'Found', 'status', v_status, 'problem', v_problem);
    perform private.log_event('Discord', case v_status when 'Found' then 'Discord account found' else 'Discord account not found' end,
      case v_kind when 'instructor' then 'instructor' else 'team_member' end, v_id, null, v_out,
      coalesce(v_problem, v_label || ' is ' || v_name || ' on Discord.'),
      null, null, null, null, case v_kind when 'instructor' then v_id end, null, false, null, v_label);
  end if;

  update public.action_queue set status = case when coalesce((v_out ->> 'ok')::boolean, false) then 'Done' else 'Failed' end,
         result = v_out, error = v_out ->> 'problem', processed_at = now()
   where id = p_action_id;
  return v_out;
end;
$$;
create or replace function public.next_discord_lookups(p_limit int default 20)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v jsonb := '[]'; a public.action_queue;
begin
  if not private.is_service() then
    raise exception 'Only the automation can do this.' using errcode = '42501';
  end if;
  -- Work handed out more than 10 minutes ago and never answered goes back in the queue.
  update public.action_queue set status = 'Queued'
   where status = 'Processing' and action like 'discord\_%' and updated_at < now() - interval '10 minutes';
  for a in
    with c as (select q.id from public.action_queue q where q.status = 'Queued' and q.action like 'discord\_%'
                order by q.created_at limit p_limit for update skip locked)
    update public.action_queue q set status = 'Processing',
           payload = q.payload || case when q.action = 'discord_member' then jsonb_build_object('username',
             case q.payload ->> 'kind' when 'instructor' then (select discord_username from public.instructor where id = (q.payload ->> 'id')::uuid)
                                       else (select discord_username from public.team_member where id = (q.payload ->> 'id')::uuid) end)
             else '{}'::jsonb end
      from c where q.id = c.id returning q.*
  loop
    v := v || jsonb_build_object('action_id', a.id, 'action', a.action) || case a.action
      when 'discord_servers' then '{}'::jsonb
      when 'discord_server' then jsonb_build_object('server_id',
        (select discord_server_id from public.domain where id = (a.payload ->> 'domain_id')::uuid),
        'bot_user_id', (select c.discord_bot_user_id from public.app_config c where c.id = 1))
      else jsonb_build_object('username', a.payload ->> 'username',
        'servers', private.member_servers(a.payload ->> 'kind', (a.payload ->> 'id')::uuid)) end;
  end loop;
  return v;
end;
$$;
create or replace function public.set_instructor_channel(p_instructor_id uuid, p_domain_id uuid, p_channel_id text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_server text := (select discord_server_id from public.domain where id = p_domain_id);
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
  if v_server is distinct from c.server_id then
    raise exception 'That channel is in another Discord server. Choose a channel in the server of this domain.' using errcode = '22023';
  end if;
  insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name)
  values (p_instructor_id, p_domain_id, c.id, c.name)
  on conflict (instructor_id, domain_id) do update set channel_id = excluded.channel_id, channel_name = excluded.channel_name;
  -- A new channel needs a new contact check.
  update public.instructor set verified_at = null, discord_failed_at = null, version = version
   where id = p_instructor_id and verified_at is not null;
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
                || E'\n\n— SME Scheduling';
      v_html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#1f2328">'
                || replace(private.html_escape(v_prefix || 'Hi ' || (v_r ->> 'first_name') || E',\n\n' || (v_r ->> 'body')), E'\n', '<br>')
                || case when v_btn_html <> '' then '<p style="margin-top:16px">' || v_btn_html || '</p>' else '' end
                || '<p style="color:#59636e;font-size:13px">— SME Scheduling</p></div>';
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
  v_test := private.is_test_domain(d.id);
  if v_test then v_prefix := '[TEST] '; end if;
  if p_quiet then
    v_send := private.team_send_time(coalesce(p_mw, p_domain), p_now);
  end if;
  v_text := p_text || case when v_app is not null then E'\nOpen the app: ' || v_app else '' end;

  -- 'people': no channel post (the people are already tagged elsewhere), only their own copies below.
  if p_target in ('alert', 'admin') then
    v_channel := case when p_target = 'admin' then (select c.admin_discord_channel_id from public.app_config c where c.id = 1)
                      when v_test then d.test_discord_channel_id else d.alert_discord_channel_id end;
    if v_channel is null and p_target = 'alert' then
      v_channel := (select c.admin_discord_channel_id from public.app_config c where c.id = 1);
    end if;
    if v_channel is null and p_target = 'alert' and p_domain is not null then
      -- Nowhere to post: one task to choose an alert channel (people still get their own copies below).
      perform private.raise_attention(p_domain, 'Other', 'Normal', 'Choose an alert channel for ' || coalesce(d.name, 'this domain'),
        'Team alerts for ' || coalesce(d.name, 'this domain') || ' have no Discord channel to go to. Choose an alert channel on Setup, Domains. Until then everyone gets their own copy.',
        'noalert:' || p_domain, coalesce(nullif(private.domain_role_ids(p_domain, 'Ops'), '{}'), private.all_operations_ids()), p_now, '{}', false);
    end if;
    if v_channel is not null then
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
    end if;
  end if;

  if p_target in ('alert', 'people', 'email') then
    -- Everyone tagged also gets their own copy: a direct message, or email when they have no Discord.
    -- 'email': email only (used when Discord itself is the problem).
    for t in select * from public.team_member where id = any (coalesce(p_mentions, '{}')) and active loop
      v_ch := case when p_target <> 'email' and p_template <> 'T14' and t.discord_user_id is not null then 'Discord' else 'Email' end;
      continue when v_ch = 'Email' and coalesce(t.email, '') = '';
      insert into public.message (domain_id, audience, template_id, channel, unique_key, status, not_before,
        team_member_id, module_week_id, help_request_id, attention_item_id, recipient_label, to_address,
        discord_dm_user_id, subject, body_text, is_test)
      values (p_domain, 'Team', p_template, v_ch, p_key || ':' || t.id || ':copy',
        case when v_send > p_now then 'Scheduled' else 'Pending' end, v_send, t.id, p_mw, p_help, p_attention, t.name,
        case when v_ch = 'Email' then t.email end,
        case when v_ch = 'Discord' then t.discord_user_id end,
        v_prefix || p_subject, v_prefix || v_text, v_test)
      on conflict (unique_key) where unique_key is not null do nothing;
      get diagnostics v_n = row_count;
      v_count := v_count + v_n;
    end loop;
  elsif p_target = 'person' then
    select * into t from public.team_member where id = p_person;
    if t.id is null or not t.active then
      return 0;
    end if;
    foreach v_ch in array array['Discord', 'Email'] loop
      continue when v_ch = 'Discord' and (t.digest_channel = 'Email' or t.discord_user_id is null);
      -- Email when the person chose it, or when the domain sends team reminders by Discord and email.
      -- Without Discord, email is used whatever the preference says.
      continue when v_ch = 'Email' and t.digest_channel = 'Discord' and t.discord_user_id is not null;
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
create or replace function private.message_fix(m public.message, p_error text)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  e text := lower(coalesce(p_error, ''));
  v_who text := coalesce(m.recipient_label, 'this person');
  v_chan text := coalesce((select '#' || c.name from public.discord_channel c where c.id = m.discord_channel_id),
                          (select '#' || ic.channel_name from public.instructor_channel ic where ic.channel_id = m.discord_channel_id limit 1));
  v_page text := case when m.audience = 'Instructor' then 'Setup, Instructors' else 'Setup, Team' end;
begin
  if m.channel = 'Email' then
    if e ~ '(invalid|not exist|no such user|bounce|address)' then
      return 'The email address of ' || v_who || ' does not work. Correct it on ' || v_page || '.';
    end if;
    return 'Email could not be sent to ' || v_who || '. Check the email connection on Settings, Connections.';
  end if;
  if m.discord_dm_user_id is not null and m.discord_channel_id is null then
    if e ~ '(50007|cannot send messages to this user)' then
      return v_who || ' does not accept direct messages from the server. Ask them to allow direct messages from server members, '
        || case when m.audience = 'Instructor' then 'or choose a channel for them on ' || v_page || '.' else 'or remove their Discord username on ' || v_page || ' so they get email.' end;
    end if;
    return 'The direct message to ' || v_who || ' failed. Press Check Discord for them on ' || v_page || '.';
  end if;
  if e ~ '(10003|unknown channel|404)' then
    return 'The Discord channel ' || coalesce(v_chan, '') || ' no longer exists. Choose a new channel for ' || v_who || ' on ' || v_page || '.';
  end if;
  if e ~ '(50001|50013|missing access|missing permissions|403)' then
    return 'The bot may not post in ' || coalesce(v_chan, 'this channel')
      || '. In Discord, give the bot''s role View Channels, Send Messages, Embed Links and Read Message History there.';
  end if;
  if e ~ '(401|unauthorized)' then
    return 'The bot''s login (token) is wrong. Whoever looks after the automation must update the Discord bot setting.';
  end if;
  return 'Discord did not accept the message to ' || v_who || ' (' || coalesce(p_error, 'no reason given')
    || '). Check the Discord server on Settings, Connections.';
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
  -- Say what still reached the person, from what was really queued.
  v_reach := case
    when m.audience = 'Team' and m.channel = 'Discord' and m.discord_dm_user_id is not null then ' They get it by email instead.'
    when exists (select 1 from public.message x where x.id <> m.id and x.template_id = m.template_id and x.channel <> m.channel
                   and x.status <> 'Failed' and x.module_week_id is not distinct from m.module_week_id
                   and x.request_id is not distinct from m.request_id and x.help_request_id is not distinct from m.help_request_id
                   and x.instructor_id is not distinct from m.instructor_id and x.team_member_id is not distinct from m.team_member_id)
      then case when m.channel = 'Discord' then ' They still get it by email.' else ' They still get it on Discord.' end
    else ' It did not reach them any other way.' end;
  if m.audience <> 'Admin' and not v_notice then
    -- One task, and the alert about it goes to the operations team by email (see queue_team_message: T14).
    perform private.raise_attention(m.domain_id, 'MessageFailed', case when v_urgent then 'Urgent' else 'Normal' end,
      'Message failed: ' || m.template_id || ' to ' || coalesce(m.recipient_label, '?') || ' via ' || m.channel,
      private.message_fix(m, p_error) || v_reach,
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
create or replace function public.claim_outbound_messages(p_limit int default 25)
returns setof public.message language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  -- OUT-2: drop what should no longer go out before handing messages to n8n.
  perform private.cancel_stale_messages();
  update public.message set status = case when attempts >= 3 then 'Failed' else 'Pending' end,
         last_error = case when attempts >= 3 then coalesce(last_error, 'No answer from the automation after 3 tries') else last_error end
   where status = 'Sending' and claimed_at < now() - interval '15 minutes';
  return query
  with c as (
    select m.id from public.message m left join public.domain d on d.id = m.domain_id
     where m.status = 'Pending' and m.direction = 'Outbound'
       and (m.audience <> 'Instructor'
            or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                and coalesce(d.status, 'Live') <> 'Paused'))
     order by m.created_at
     limit greatest(1, least(p_limit, 100))
     for update of m skip locked),
  u as (
    update public.message m set status = 'Sending', claimed_at = now(), attempts = m.attempts + 1
      from c where m.id = c.id
    returning m.*)
  select (jsonb_populate_record(null::public.message, to_jsonb(u) || jsonb_build_object(
           'body_text', private.with_tokens(u.body_text),
           'body_html', private.with_tokens(u.body_html),
           'buttons', private.with_tokens(u.buttons::text)::jsonb))).*
    from u;
end;
$$;
create or replace function public.help_reply(p_help_id uuid, p_text text, p_resolves boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  h public.help_request;
  v_now timestamptz;
  v_req uuid;
  v_n int;
  v_from text := coalesce((select t.name from public.team_member t where t.id = private.current_team_member_id()), 'SME Scheduling');
begin
  perform private.require_team();
  if coalesce(trim(p_text), '') = '' then raise exception 'Write a reply first.'; end if;
  select * into h from public.help_request where id = p_help_id for update;
  v_now := private.mw_now(h.module_week_id);
  if h.requester_instructor_id is not null then
    select r.id into v_req from public.request r join public.booking b on b.request_id = r.id
     where b.module_week_id = h.module_week_id and b.status = 'Active' and b.instructor_id = h.requester_instructor_id;
    v_n := private.queue_instructor_message('M14', h.requester_instructor_id, h.module_week_id, null, v_now,
      case when v_req is not null then private.buttons(v_req, array['NeedMoreHelp']) else '[]'::jsonb end,
      jsonb_build_object('text', p_text, 'from', v_from), false, 'reply:' || h.id || ':' || gen_random_uuid(),
      h.id, null);
    if v_n = 0 then
      raise exception 'The reply could not be sent: % has no email address or Discord. Add one on Setup, Instructors.',
        (select full_name from public.instructor where id = h.requester_instructor_id) using errcode = '22023';
    end if;
  elsif h.requester_team_member_id is not null then
    perform private.queue_team_message('M14', h.domain_id, 'person', h.requester_team_member_id, '{}',
      'Reply to your help request', p_text || E'\n— ' || v_from,
      'M14:' || h.id || ':' || gen_random_uuid(), v_now, false, null, h.module_week_id, h.id);
  end if;
  update public.help_request
     set status = case when p_resolves then 'Resolved' else 'WaitingOnInstructor' end,
         first_response_at = coalesce(first_response_at, v_now),
         resolved_at = case when p_resolves then v_now end,
         assigned_to = coalesce(assigned_to, private.current_team_member_id())
   where id = h.id;
  if p_resolves then
    perform private.resolve_attention('help:' || h.id, 'Resolved with a reply');
    perform private.clear_help_risk(h.module_week_id);
  else
    update public.attention_item set status = 'Acknowledged', ack_until = now() + interval '24 hours'
     where dedupe_key = 'help:' || h.id and status <> 'Done';
  end if;
  perform private.log_event('Help requests', 'Replied' || case when p_resolves then ' and resolved' else '' end, 'help_request', h.id,
    null, jsonb_build_object('text', p_text), null, h.domain_id, null, h.module_week_id);
  perform private.queue_deliver('help reply');
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------------ OUT-2: nothing out of date is sent
/** Messages to instructors that should no longer go out (run before n8n takes messages to send). */
create or replace function private.cancel_stale_messages()
returns int language plpgsql security definer set search_path = ''
as $$
declare n int := 0; v int;
begin
  -- An ask or reminder whose request has closed (withdrawn, expired, superseded or declined).
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the request closed before this went out.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id in ('M1', 'M2', 'M5', 'M6', 'M7', 'M9') and m.request_id is not null
     and exists (select 1 from public.request r where r.id = m.request_id and r.status not in ('Queued', 'Sent', 'Reminded', 'Accepted'));
  get diagnostics v = row_count; n := n + v;
  -- A reminder for a request that was already answered.
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the instructor answered already.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id in ('M2', 'M9') and m.request_id is not null
     and exists (select 1 from public.request r where r.id = m.request_id and r.status = 'Accepted');
  get diagnostics v = row_count; n := n + v;
  -- A confirmation for a booking that has ended (released, cancelled) before it went out.
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the booking ended before this went out.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id = 'M4' and m.module_week_id is not null
     and not exists (select 1 from public.booking b where b.module_week_id = m.module_week_id
                       and b.instructor_id = m.instructor_id and b.status = 'Active');
  get diagnostics v = row_count; n := n + v;
  -- "No longer needed" for an ask that never went out.
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the request it answers never went out.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id in ('M3', 'M12') and m.request_id is not null
     and not exists (select 1 from public.message x where x.request_id = m.request_id and x.template_id in ('M1', 'M2', 'M5')
                       and x.status in ('Sent', 'Sending'));
  get diagnostics v = row_count; n := n + v;
  return n;
end;
$$;
revoke execute on function private.cancel_stale_messages() from public;


-- ------------------------------------------------------------------ SCH-1: classes of one week never overlap
/** "Live class on Sat, Feb 13 ... and Assignment review on ...", or null when the week's classes do not overlap. */
create or replace function private.week_self_overlap(p_mw uuid, p_extra_start timestamptz default null,
  p_extra_end timestamptz default null, p_skip_class uuid default null)
returns text language sql stable security definer set search_path = ''
as $$
  with x as (
    select id::text as id, title, starts_at, ends_at, region from public.class_session
     where module_week_id = p_mw and status = 'Planned' and id is distinct from p_skip_class
    union all
    select 'new', 'The new time', p_extra_start, p_extra_end, null where p_extra_start is not null),
  c as (select row_number() over (order by starts_at, id) as n, * from x)
  select a.title || ' (' || private.fmt_class_range(a.starts_at, a.ends_at, coalesce(a.region, b.region, 'US')) || ') and '
      || b.title || ' (' || private.fmt_class_range(b.starts_at, b.ends_at, coalesce(b.region, a.region, 'US')) || ')'
    from c a join c b on a.n < b.n
   where tstzrange(a.starts_at, a.ends_at, '[)') && tstzrange(b.starts_at, b.ends_at, '[)')
   limit 1;
$$;
revoke execute on function private.week_self_overlap(uuid, timestamptz, timestamptz, uuid) from public;

create or replace function private.confirm_booking(p_mw uuid, p_instructor uuid, p_request uuid, p_via text, p_now timestamptz, p_note text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  r public.request;
  v_reason text;
  v_booking uuid;
  v_req uuid := p_request;
  v_name text := (select i.full_name from public.instructor i where i.id = p_instructor);
  v_test boolean;
  v_clash text;
begin
  select * into w from public.module_week where id = p_mw for update;
  v_test := private.is_test_domain(w.domain_id);
  if w.status in ('Cancelled', 'Completed') then
    return jsonb_build_object('ok', false, 'reason', 'week_closed', 'message', 'This class is no longer scheduled.');
  end if;
  if exists (select 1 from public.booking b where b.module_week_id = p_mw and b.status = 'Active') then
    return jsonb_build_object('ok', false, 'reason', 'already_booked', 'message', 'This module week already has a confirmed instructor.');
  end if;
  if p_via = 'Instructor' then
    select * into r from public.request where id = p_request for update;
    if r.status not in ('Sent', 'Reminded') then
      return jsonb_build_object('ok', false, 'reason', 'closed', 'message', 'This request has closed.');
    end if;
    if r.time_version <> w.time_version then
      return jsonb_build_object('ok', false, 'reason', 'stale', 'message', 'The class times changed — please use the latest message.');
    end if;
  end if;
  -- SCH-1: one instructor teaches the whole week, so its classes must not overlap each other.
  if w.same_instructor and private.week_self_overlap(p_mw) is not null then
    perform private.raise_attention(w.domain_id, 'Other', 'Urgent', 'Classes overlap: ' || private.mw_label(p_mw),
      'Two classes of this class week overlap: ' || private.week_self_overlap(p_mw) || '. Change one of the times so one instructor can teach both.',
      'selfoverlap:' || p_mw, private.ops_for_week(p_mw), p_now, private.mw_refs(p_mw), false);
    return jsonb_build_object('ok', false, 'reason', 'week_overlap',
      'message', 'Thank you! The times of this class week are being corrected, so we cannot confirm it right now. The team will be in touch.');
  end if;
  v_reason := private.eligibility(p_instructor, p_mw);
  if p_via in ('Manual', 'Offline') and v_reason = 'Not verified' then
    v_reason := null;            -- ops may assign someone they confirmed personally
  end if;
  if v_reason is not null then
    return jsonb_build_object('ok', false, 'reason', case when v_reason like 'Teaching %' then 'clash' else 'ineligible' end,
      'message', v_reason);
  end if;

  begin
    insert into public.booking (module_week_id, instructor_id, request_id, confirmed_via, confirmed_at, confirmed_by,
      time_version_confirmed, is_test)
    values (p_mw, p_instructor, null, p_via, p_now, private.current_team_member_id(), w.time_version, v_test)
    returning id into v_booking;
    insert into public.booking_slot (booking_id, class_id, instructor_id, time_range)
    select v_booking, c.id, p_instructor, tstzrange(c.starts_at, c.ends_at, '[)')
      from public.class_session c where c.module_week_id = p_mw and c.status = 'Planned';
  exception
    when exclusion_violation then
      v_clash := private.week_clash(p_instructor, p_mw);
      return jsonb_build_object('ok', false, 'reason', 'clash', 'message', coalesce(v_clash, 'Teaching another class at this time'));
    when unique_violation then
      return jsonb_build_object('ok', false, 'reason', 'already_booked', 'message', 'This module week already has a confirmed instructor.');
  end;

  if p_via <> 'Instructor' then
    -- Another instructor being asked is withdrawn politely; the same instructor's open request is accepted.
    select * into r from public.request
     where module_week_id = p_mw and kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded') for update;
    if r.id is not null and r.instructor_id <> p_instructor then
      perform private.withdraw_open_request(p_mw, 'Assigned to someone else', p_now, true);
      r := null;
    end if;
    if r.id is not null then
      v_req := r.id;
    else
      insert into public.request (module_week_id, instructor_id, kind, status, answer, time_version, line_source,
        sent_at, answered_at, is_test, close_reason)
      values (p_mw, p_instructor, 'Outreach', 'Accepted', 'Yes', w.time_version, p_via, p_now, p_now, v_test,
        case when p_via = 'Manual' then 'Assigned manually' else 'Confirmed offline' end)
      returning id into v_req;
    end if;
  end if;

  update public.request set status = 'Accepted', answer = 'Yes', answered_at = p_now where id = v_req and status <> 'Accepted';
  update public.booking set request_id = v_req where id = v_booking;
  -- OUT-3: pausing is about asking; a confirmed week has nobody left to ask, so reminders and time changes go on.
  update public.module_week set status = 'Confirmed', at_risk = false, at_risk_reason = null, paused = false where id = p_mw;
  if p_via = 'Instructor' then
    update public.instructor set last_response_at = p_now where id = p_instructor;
  end if;
  perform private.resolve_attention('exhausted:' || p_mw, 'Instructor confirmed');
  perform private.resolve_attention('urgentfill:' || p_mw, 'Instructor confirmed');
  perform private.resolve_attention('atrisk:' || p_mw, 'Replacement confirmed');
  perform private.resolve_attention('readiness:' || p_mw, 'Instructor confirmed');

  -- Class checklist (SCH-8)
  insert into public.checklist_item (class_id, booking_id, label, due_at)
  select c.id, v_booking, lbl, w.first_class_at - make_interval(days => private.setting_int(w.id, 'checklist_due_days'))
    from public.class_session c
    cross join lateral jsonb_array_elements_text(private.get_setting(w.id, 'checklist_items')) lbl
   where c.module_week_id = p_mw and c.status = 'Planned'
  on conflict (class_id, label) do update set booking_id = excluded.booking_id;

  perform private.queue_instructor_message('M4', p_instructor, p_mw, v_req, p_now,
    private.buttons(v_req, array['NeedHelp', 'CantMakeItAnymore']));
  perform private.queue_team_message('T2', w.domain_id,
    case when private.is_test_domain(w.domain_id)
              or not exists (select 1 from public.instructor_channel ic where ic.instructor_id = p_instructor and ic.domain_id = w.domain_id)
                 and (select i.discord_channel_id from public.instructor i where i.id = p_instructor) is null
         then 'alert' else 'people' end,
    null, array(select distinct x from unnest(private.owners_or_leads(w.module_id) || private.ops_for_week(p_mw)) x),
    'Confirmed: ' || private.mw_label(p_mw),
    '✅ ' || v_name || ' is confirmed for ' || private.mw_label(p_mw)
      || case p_via when 'Manual' then ' (assigned manually)' when 'Offline' then ' (confirmed offline)' else '' end || '.',
    'T2:' || v_booking, p_now, false, null, p_mw);
  perform private.log_event('Bookings', 'Booked ' || v_name, 'booking', v_booking, null,
    jsonb_build_object('via', p_via, 'time_version', w.time_version), p_note,
    w.domain_id, w.module_id, p_mw, null, p_instructor, null, v_test);
  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'request_id', v_req);
end;
$$;
create or replace function private.step_reminders(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  a record;
  n int := 0;
  v_targets uuid[];
  v_weekly boolean;
  v_r2n int;
  v_r2u int;
  v_esn int;
  v_esu int;
  v_scope uuid;
  v_has_r2 boolean;
  v_escal uuid[];
begin
  for a in select * from public.attention_item
            where domain_id = p_domain and status <> 'Done' and (ack_until is null or ack_until <= p_now)
              -- OUT-6: nothing is reminded about a class week that is over or cancelled.
              and not exists (select 1 from public.module_week mw where mw.id = attention_item.module_week_id
                                and (mw.status in ('Cancelled', 'Completed') or mw.last_class_end_at <= p_now))
            for update skip locked loop
    -- OUT-4: the numbers of the task's own class week (a cohort can change them), else the domain's.
    v_scope := coalesce(a.module_week_id, a.module_id, p_domain);
    v_r2n := private.setting_int(v_scope, 'reminder_r2_normal_h');
    v_r2u := private.setting_int(v_scope, 'reminder_r2_urgent_h');
    v_esn := private.setting_int(v_scope, 'reminder_escalate_normal_h');
    v_esu := private.setting_int(v_scope, 'reminder_escalate_urgent_h');
    v_targets := case when a.assigned_to is not null then array[a.assigned_to] else a.recipients end;
    v_weekly := a.type in ('ThinBench', 'ScheduleLow', 'UnverifiedInRanking');
    if a.r1_at is null then
      continue;                                   -- normal items get R1 in the daily digest
    end if;
    if v_weekly then
      if v_r2n > 0 and a.last_reminder_at + interval '7 days' <= p_now then
        perform private.queue_team_message('REM', p_domain, 'person', t, '{}', 'Weekly reminder: ' || a.title,
            '⏰ Weekly reminder: ' || a.title || coalesce(E'\n' || a.detail, ''),
            'REM:' || a.id || ':' || to_char(p_now, 'YYYYMMDDHH24'), p_now, true, a.id, a.module_week_id)
          from unnest(v_targets) t;
        insert into public.reminder (attention_item_id, recipient, level, sent_at) select a.id, t, 'R2', p_now from unnest(v_targets) t;
        update public.attention_item set last_reminder_at = p_now where id = a.id;
        n := n + 1;
      end if;
      continue;
    end if;
    select exists (select 1 from public.reminder rm where rm.attention_item_id = a.id and rm.level = 'R2') into v_has_r2;
    if (a.severity = 'Urgent' and v_r2u > 0 and a.last_reminder_at + make_interval(hours => v_r2u) <= p_now)
       or (a.severity = 'Normal' and v_r2n > 0 and not v_has_r2 and a.r1_at + make_interval(hours => v_r2n) <= p_now) then
      perform private.queue_team_message('REM', p_domain, 'person', t, '{}',
          case when a.severity = 'Urgent' then '🚨 Reminder: ' else 'Reminder: ' end || a.title,
          case when a.severity = 'Urgent' then '🚨 Still open: ' else '⏰ Still open: ' end || a.title || coalesce(E'\n' || a.detail, '')
            || E'\nTap "I''m on it" in the app to pause reminders.',
          'REM:' || a.id || ':' || to_char(p_now, 'YYYYMMDDHH24'), p_now, a.severity = 'Normal', a.id, a.module_week_id)
        from unnest(v_targets) t;
      insert into public.reminder (attention_item_id, recipient, level, sent_at) select a.id, t, 'R2', p_now from unnest(v_targets) t;
      update public.attention_item set last_reminder_at = p_now where id = a.id;
      n := n + 1;
    end if;
    -- Readiness failures escalate on their own PRD timeline (35 days before), not by this ladder.
    if a.escalated_at is null and a.status = 'Open' and a.type <> 'ReadinessFailed'
       and (case when a.severity = 'Urgent' then v_esu else v_esn end) > 0
       and a.r1_at + make_interval(hours => case when a.severity = 'Urgent' then v_esu else v_esn end) <= p_now then
      v_escal := private.uniq(
        coalesce(case when a.module_id is not null then private.owners_or_leads(a.module_id) end, '{}')
        || private.domain_role_ids(p_domain, 'Lead'));
      perform private.queue_team_message('T13', p_domain, 'alert', null, v_escal,
        'Escalation: ' || a.title,
        '⚠️ Escalation — not acknowledged since ' || private.fmt_ist(a.r1_at) || ': ' || a.title || coalesce(E'\n' || a.detail, ''),
        'T13:' || a.id, p_now, a.severity = 'Normal', a.id, a.module_week_id);
      insert into public.reminder (attention_item_id, recipient, level, sent_at) select a.id, t, 'Escalation', p_now from unnest(v_escal) t;
      update public.attention_item set escalated_at = p_now where id = a.id;
      perform private.log_event('Reminders', 'Escalated: ' || a.title, 'attention_item', a.id, null, null, null,
        p_domain, a.module_id, a.module_week_id);
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;
create or replace function private.step_complete(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare w record; n int := 0;
begin
  update public.class_session c set status = 'Completed'
    from public.module_week mw
   where c.module_week_id = mw.id and mw.domain_id = p_domain and c.status = 'Planned'
     and c.ends_at <= p_now and not c.problem_flag;
  for w in select mw.* from public.module_week mw
            where mw.domain_id = p_domain and mw.status not in ('Completed', 'Cancelled')
              and mw.last_class_end_at <= p_now
              and not exists (select 1 from public.class_session c where c.module_week_id = mw.id and c.status = 'Planned')
            for update skip locked loop
    -- OUT-6: a week that was never filled is over too: it is closed, and so are its tasks.
    update public.booking set status = 'Completed' where module_week_id = w.id and status = 'Active';
    update public.module_week set status = 'Completed', at_risk = false where id = w.id;
    update public.attention_item set status = 'Done', done_at = now(),
           done_note = case when exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Completed')
                            then 'The classes are over' else 'The classes are over (no instructor was confirmed)' end
     where module_week_id = w.id and status <> 'Done';
    update public.request set status = 'Superseded', close_reason = 'Classes completed'
     where module_week_id = w.id and status in ('Queued', 'Sent', 'Reminded');
    perform private.log_event('System',
      case when exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Completed')
           then 'Module week completed' else 'Class week ended without a confirmed instructor' end,
      'module_week', w.id, null, null, null, w.domain_id, w.module_id, w.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
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
   where mw.domain_id = p_domain and mw.status not in ('Cancelled', 'Completed') and mw.owner_checkin_sent_at is null
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
create or replace function private.create_help_request(
  p_mw uuid, p_instructor uuid, p_member uuid, p_source text, p_categories text[], p_details text,
  p_urgency text, p_reply text, p_now timestamptz, p_booking uuid default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  h public.help_request;
  v_routing jsonb;
  v_routed uuid[] := '{}';
  v_owners uuid[];
  v_ops uuid[];
  v_leads uuid[];
  c text;
  v_rule text;
  v_days numeric;
  v_h int;
  v_sev text := 'Normal';
  v_name text;
  v_cats text[] := coalesce(p_categories, '{}');
  v_helper text;
  v_reopen boolean;
begin
  select * into w from public.module_week where id = p_mw;
  if cardinality(v_cats) = 0 then v_cats := array['other']; end if;
  v_name := coalesce((select i.full_name from public.instructor i where i.id = p_instructor),
                     (select t.name from public.team_member t where t.id = p_member), 'Someone');

  -- Duplicates within 1 hour merge into one (PRD 10.6).
  select * into h from public.help_request
   where module_week_id = p_mw and merged_into is null
     and status in ('Open', 'InProgress', 'WaitingOnInstructor')
     and coalesce(requester_instructor_id::text, requester_team_member_id::text) = coalesce(p_instructor::text, p_member::text)
     and raised_at >= p_now - interval '1 hour'
   order by raised_at desc limit 1 for update;
  if h.id is not null then
    v_reopen := h.status = 'WaitingOnInstructor';
    update public.help_request
       set categories = (select array_agg(distinct x) from unnest(categories || v_cats) x),
           details = left(concat_ws(E'\n---\n', nullif(details, ''), nullif(p_details, '')), 1000),
           urgency = case when p_urgency = 'Urgent' or urgency = 'Urgent' then 'Urgent'
                          when p_urgency = 'Within24h' or urgency = 'Within24h' then 'Within24h' else 'NoRush' end,
           status = 'Open'
     where id = h.id returning * into h;
    -- The stricter urgency wins: a new reply target and severity, worked out like a new request.
    v_days := private.days_until(p_mw, p_now);
    v_h := case h.urgency when 'Urgent' then private.setting_int(w.id, 'help_target_urgent_h')
                          when 'Within24h' then private.setting_int(w.id, 'help_target_24h_h')
                          else private.setting_int(w.id, 'help_target_norush_h') end;
    if v_days < 2 then v_h := least(v_h, private.setting_int(w.id, 'help_target_urgent_h'));
    elsif v_days <= 7 then v_h := least(v_h, private.setting_int(w.id, 'help_target_24h_h')); end if;
    v_sev := case when h.urgency = 'Urgent' or v_days < 2 then 'Urgent' else h.severity end;
    update public.help_request
       set severity = v_sev,
           response_target_at = case when v_reopen then p_now + make_interval(hours => v_h)
                                     else least(response_target_at, p_now + make_interval(hours => v_h)) end,
           first_response_at = case when v_reopen then null else first_response_at end,
           half_reminder_at = case when v_reopen then null else half_reminder_at end,
           escalated_at = case when v_reopen then null else escalated_at end
     where id = h.id returning * into h;
    update public.attention_item set status = 'Open', ack_until = null
     where dedupe_key = 'help:' || h.id and status <> 'Done';
    perform private.raise_attention(w.domain_id, 'HelpRequest', v_sev,
      coalesce((select a.title from public.attention_item a where a.dedupe_key = 'help:' || h.id and a.status <> 'Done'),
               'Need help: ' || v_name || ' · ' || private.mw_label(p_mw)),
      null, 'help:' || h.id, h.routed_to, p_now, private.mw_refs(p_mw, jsonb_build_object('help_request_id', h.id)), false, 'T7');
    if v_reopen then
      perform private.queue_team_message('T7', w.domain_id, 'people', null,
        case when h.assigned_to is not null then array[h.assigned_to] else h.routed_to end,
        'Follow up on a help request: ' || private.mw_label(p_mw),
        v_name || ' needs more help with ' || private.mw_label(p_mw) || '.' || coalesce(E'
' || nullif(p_details, ''), ''),
        'HELPFOLLOW:' || h.id || ':' || gen_random_uuid(), p_now, false, null, p_mw, h.id);
    end if;
    perform private.log_event('Help requests', 'Help request merged (same person within 1 hour)', 'help_request', h.id,
      null, jsonb_build_object('categories', v_cats), p_details, w.domain_id, w.module_id, p_mw, null, p_instructor);
    return jsonb_build_object('id', h.id, 'merged', true, 'target_at', h.response_target_at,
      'helper', private.team_names(coalesce(nullif(array[h.assigned_to], array[null]::uuid[]), h.routed_to[1:1])));
  end if;

  v_routing := private.get_setting(w.id, 'help_routing');
  v_owners := private.owners_or_leads(w.module_id);
  v_ops := private.ops_for_week(w.id);
  v_leads := private.domain_role_ids(w.domain_id, 'Lead');
  if p_source = 'Owner' then
    v_routed := v_ops || v_leads;
  else
    foreach c in array v_cats loop
      v_rule := coalesce(v_routing ->> c, 'Both');
      v_routed := v_routed || case v_rule when 'Owner' then v_owners when 'Ops' then v_ops else v_owners || v_ops end;
    end loop;
  end if;
  v_routed := private.uniq(v_routed);
  if cardinality(v_routed) = 0 then v_routed := private.uniq(v_ops || v_leads); end if;

  -- Response target: whichever is shorter, urgency or time to class (PRD 10.5).
  v_days := private.days_until(p_mw, p_now);
  v_h := case p_urgency when 'Urgent' then private.setting_int(w.id, 'help_target_urgent_h')
                        when 'Within24h' then private.setting_int(w.id, 'help_target_24h_h')
                        else private.setting_int(w.id, 'help_target_norush_h') end;
  if v_days < 2 then
    v_h := least(v_h, private.setting_int(w.id, 'help_target_urgent_h'));
  elsif v_days <= 7 then
    v_h := least(v_h, private.setting_int(w.id, 'help_target_24h_h'));
  end if;
  if p_urgency = 'Urgent' or v_days < 2 then v_sev := 'Urgent'; end if;

  insert into public.help_request (domain_id, module_week_id, booking_id, requester_instructor_id, requester_team_member_id,
    source, categories, details, urgency, reply_channel, routed_to, severity, raised_at, response_target_at, is_test)
  values (w.domain_id, p_mw, coalesce(p_booking, (select b.id from public.booking b where b.module_week_id = p_mw and b.status = 'Active')),
    p_instructor, p_member, p_source, v_cats, left(p_details, 1000), coalesce(p_urgency, 'NoRush'), coalesce(p_reply, 'Either'),
    v_routed, v_sev, p_now, p_now + make_interval(hours => v_h),
    private.is_test_domain(w.domain_id))
  returning * into h;

  v_helper := (select t.name from public.team_member t where t.id = v_routed[1]);
  perform private.raise_attention(w.domain_id, 'HelpRequest', v_sev,
    'Need help: ' || v_name || ' — ' || private.mw_label(p_mw),
    (select string_agg(private.help_category_label(x), ', ') from unnest(v_cats) x) || coalesce(E'\n' || p_details, '')
      || E'\nReply by ' || private.fmt_ist(h.response_target_at),
    'help:' || h.id, v_routed, p_now,
    private.mw_refs(p_mw, jsonb_build_object('help_request_id', h.id, 'instructor_id', p_instructor, 'due_at', h.response_target_at)),
    true, 'T7');
  if p_instructor is not null then
    perform private.queue_instructor_message('M13', p_instructor, p_mw, null, p_now, '[]',
      jsonb_build_object('helper', coalesce(v_helper, 'Our team'), 'by', private.fmt_local(h.response_target_at, coalesce(private.week_region(h.module_week_id), 'US'))),
      v_sev = 'Urgent', 'help:' || h.id, h.id,
      case when coalesce(p_reply, 'Either') = 'Email' then 'Email' when p_reply = 'Discord' then 'Discord' end);
  end if;
  perform private.log_event('Help requests', 'Help requested by ' || v_name, 'help_request', h.id, null,
    jsonb_build_object('categories', v_cats, 'urgency', p_urgency, 'routed_to', private.team_names(v_routed)),
    p_details, w.domain_id, w.module_id, p_mw, null, p_instructor, null, h.is_test);
  return jsonb_build_object('id', h.id, 'merged', false, 'target_at', h.response_target_at, 'helper', coalesce(v_helper, 'Our team'));
end;
$$;
create or replace function public.cancel_module_week(p_module_week_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare w public.module_week; b public.booking; v_now timestamptz;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.status in ('Cancelled', 'Completed') then raise exception 'This module week is already %.', lower(w.status); end if;
  v_now := private.domain_now(w.domain_id);
  perform private.withdraw_open_request(w.id, 'Class cancelled', v_now, true);
  select * into b from public.booking where module_week_id = w.id and status = 'Active' for update;
  if b.id is not null then
    perform private.queue_instructor_message('M11', b.instructor_id, w.id, null, v_now, '[]', '{}', false, 'cancel:' || b.id);
    update public.booking set status = 'Cancelled', released_at = v_now, release_reason = 'Class cancelled' where id = b.id;
  end if;
  update public.request set status = 'Superseded', close_reason = 'Class cancelled'
   where module_week_id = w.id and status in ('Queued', 'Sent', 'Reminded');
  update public.class_session set status = 'Cancelled', cancelled_reason = p_reason where module_week_id = w.id and status = 'Planned';
  update public.module_week set status = 'Cancelled', at_risk = false where id = w.id;
  update public.attention_item set status = 'Done', done_at = now(), done_note = 'Module week cancelled'
   where module_week_id = w.id and status <> 'Done';
  update public.help_request set status = 'Closed', resolved_at = v_now
   where module_week_id = w.id and status in ('Open', 'InProgress', 'WaitingOnInstructor');
  perform private.log_event('Team actions', 'Module week cancelled', 'module_week', w.id, null, null, p_reason,
    w.domain_id, w.module_id, w.id);
  perform private.queue_deliver('cancel');
  return jsonb_build_object('ok', true);
end;
$$;
create or replace function private.step_help(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare h record; n int := 0; v_targets uuid[];
begin
  for h in select hr.*, mw.module_id, mw.first_class_at, mw.at_risk
             from public.help_request hr join public.module_week mw on mw.id = hr.module_week_id
            where hr.domain_id = p_domain and hr.merged_into is null
              and hr.status in ('Open', 'InProgress', 'WaitingOnInstructor')
              and mw.status not in ('Cancelled', 'Completed')
            for update of hr skip locked loop
    v_targets := case when h.assigned_to is not null then array[h.assigned_to] else h.routed_to end;
    if h.first_response_at is null and h.half_reminder_at is null and h.status = 'Open'
       and h.raised_at + (h.response_target_at - h.raised_at) / 2 <= p_now then
      perform private.queue_team_message('REM', p_domain, 'person', t, '{}',
          'Reminder: help request — ' || private.mw_label(h.module_week_id),
          '⏰ Half-time reminder: a help request for ' || private.mw_label(h.module_week_id)
            || ' needs a reply by ' || private.fmt_ist(h.response_target_at) || '.',
          'HELPHALF:' || h.id, p_now, h.severity = 'Normal', null, h.module_week_id, h.id)
        from unnest(v_targets) t;
      update public.help_request set half_reminder_at = p_now where id = h.id;
      n := n + 1;
    end if;
    if h.first_response_at is null and h.escalated_at is null and h.response_target_at <= p_now then
      perform private.queue_team_message('T13', p_domain, 'alert', null,
        private.uniq(private.owners_or_leads(h.module_id) || private.domain_role_ids(p_domain, 'Lead')),
        'Escalation: help request past target — ' || private.mw_label(h.module_week_id),
        '⚠️ Escalation: a help request for ' || private.mw_label(h.module_week_id) || ' passed its reply target ('
          || private.fmt_ist(h.response_target_at) || ') with no reply.',
        'T13:help:' || h.id, p_now, false, null, h.module_week_id, h.id);
      update public.help_request set escalated_at = p_now, severity = 'Urgent' where id = h.id;
      update public.attention_item set severity = 'Urgent', escalated_at = p_now
       where dedupe_key = 'help:' || h.id and status <> 'Done';
      n := n + 1;
    end if;
    if h.first_class_at - interval '2 days' <= p_now and h.first_class_at > p_now and not h.at_risk then
      update public.module_week set at_risk = true, at_risk_reason = 'Help pending' where id = h.module_week_id;
      perform private.log_event('System', 'At risk (help pending)', 'module_week', h.module_week_id, null, null, null,
        p_domain, h.module_id, h.module_week_id);
    end if;
  end loop;
  return n;
end;
$$;
create or replace function public.add_one_class(p_module_week_id uuid, p_module_id uuid, p_cohort_id uuid,
  p_date date, p_start time, p_end time, p_class_type text, p_title text default null,
  p_accept_warnings boolean default false, p_reason text default null, p_region text default null, p_fold int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w public.module_week;
  m public.module;
  v_cohort uuid := p_cohort_id;
  v_start timestamptz;
  v_end timestamptz;
  v_warn jsonb;
  v_class uuid;
  v_booking public.booking;
  v_clash boolean := false;
  v_title text;
  v_seq int;
  v jsonb := '{}';
  v_region text;
  v_amb jsonb;
begin
  perform private.require_team();
  if p_module_week_id is not null then
    select * into w from public.module_week where id = p_module_week_id for update;
    if w.status in ('Cancelled', 'Completed') then raise exception 'This class week is already finished or cancelled.' using errcode = '22023'; end if;
    select * into m from public.module where id = w.module_id;
    v_cohort := w.cohort_id;
  else
    select * into m from public.module where id = p_module_id;
    if m.id is null then raise exception 'Choose a module.' using errcode = '22023'; end if;
    if v_cohort is null then raise exception 'Choose a cohort.' using errcode = '22023'; end if;
    if (select domain_id from public.cohort where id = v_cohort) <> m.domain_id then
      raise exception 'The cohort belongs to another domain.' using errcode = '22023';
    end if;
  end if;
  if p_start is null or p_end is null or p_date is null then raise exception 'Choose a date, a start time and an end time.' using errcode = '22023'; end if;
  if p_end = p_start then raise exception 'The class must end after it starts.' using errcode = '22023'; end if;
  if coalesce(trim(p_class_type), '') = '' then raise exception 'Choose a class type.' using errcode = '22023'; end if;
  -- The class's region: chosen for this class, else its cohort's.
  v_region := coalesce(p_region, (select co.region from public.cohort co where co.id = v_cohort), 'US');
  if v_region not in ('US', 'India') then raise exception 'Choose US or India.' using errcode = '22023'; end if;
  v_title := coalesce(nullif(trim(p_title), ''), m.name || ': ' || trim(p_class_type));
  v_amb := private.ambiguous_warning(p_date, p_start, v_region, v_title);
  if v_amb is not null and p_fold is null then
    -- A time that happens twice must be chosen, even when other warnings are accepted.
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'needs_choice', true, 'warnings', jsonb_build_array(v_amb));
  end if;
  v_start := private.local_to_utc(p_date, p_start, v_region, p_fold);
  v_end := private.local_to_utc(p_date + case when p_end <= p_start then 1 else 0 end, p_end, v_region, p_fold);
  v_warn := private.class_warnings(m.domain_id, v_cohort, v_start, v_end, null, v_title, v_region);
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;

  if w.id is null or not w.same_instructor then
    select coalesce(max(seq), 0) + 1 into v_seq from public.module_week where module_id = m.id and cohort_id = v_cohort and week_start_date = p_date;
    insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour, same_instructor)
    values (m.id, v_cohort, p_date, v_seq, private.setting_text(m.id, 'default_outreach_mode'),
            private.setting_text(m.id, 'manual_end_behaviour'), coalesce(w.same_instructor, m.same_instructor_for_module_week))
    returning * into w;
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region)
    values (w.id, trim(p_class_type), v_title, v_start, v_end, v_region) returning id into v_class;
    v := jsonb_build_object('new_class_week', true);
  else
    if private.week_self_overlap(w.id, v_start, v_end) is not null then
      raise exception 'This class overlaps another class of the same class week: %. One instructor teaches the whole week, so choose another time.',
        private.week_self_overlap(w.id, v_start, v_end) using errcode = '23P01';
    end if;
    select * into v_booking from public.booking where module_week_id = w.id and status = 'Active';
    -- The instructor of this class week teaches the new class too: never at the same time as another class.
    if v_booking.id is not null and private.clash_text(v_booking.instructor_id, v_start, v_end, v_region) is not null then
      raise exception '% cannot teach this class: %.', (select full_name from public.instructor where id = v_booking.instructor_id),
        private.clash_text(v_booking.instructor_id, v_start, v_end, v_region) using errcode = '23P01';
    end if;
    insert into public.class_session (module_week_id, class_type, title, starts_at, ends_at, region)
    values (w.id, trim(p_class_type), v_title, v_start, v_end, v_region) returning id into v_class;
    if v_booking.id is not null then
      begin
        insert into public.booking_slot (booking_id, class_id, instructor_id, time_range)
        values (v_booking.id, v_class, v_booking.instructor_id, tstzrange(v_start, v_end, '[)'));
      exception when exclusion_violation then
        v_clash := true;
      end;
    end if;
    v := private.week_times_changed(w.id, private.mw_now(w.id), v_clash);
  end if;
  perform private.log_event('Team actions', 'Class added', 'class_session', v_class, null,
    jsonb_build_object('title', v_title, 'shown', private.fmt_class_range(v_start, v_end, v_region), 'region', v_region), nullif(trim(coalesce(p_reason, '')), ''),
    m.domain_id, m.id, w.id, v_class);
  perform private.log_accepted_warnings(v_warn, p_reason, m.domain_id, m.id, w.id, v_class);
  perform private.queue_deliver('class added');
  return jsonb_build_object('ok', true, 'class_id', v_class, 'module_week_id', w.id, 'warnings', v_warn) || v;
end;
$$;
create or replace function public.cancel_class(p_class_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c public.class_session; w public.module_week; b public.booking; v_now timestamptz;
begin
  perform private.require_team();
  -- SCH-2: lock the class week first, like a confirmation does, so the booking read below is current.
  perform 1 from public.module_week where id = (select module_week_id from public.class_session where id = p_class_id) for update;
  select * into c from public.class_session where id = p_class_id for update;
  if c.status <> 'Planned' then raise exception 'Only planned classes can be cancelled.'; end if;
  if not exists (select 1 from public.class_session x where x.module_week_id = c.module_week_id and x.status = 'Planned' and x.id <> c.id) then
    return public.cancel_module_week(c.module_week_id, p_reason);
  end if;
  select * into w from public.module_week where id = c.module_week_id;
  v_now := private.domain_now(w.domain_id);
  update public.class_session set status = 'Cancelled', cancelled_reason = p_reason where id = p_class_id;
  select * into b from public.booking where module_week_id = w.id and status = 'Active';
  if b.id is not null then
    update public.booking_slot set active = false where booking_id = b.id and class_id = p_class_id;
    perform private.queue_instructor_message('M11', b.instructor_id, w.id, null, v_now, '[]',
      jsonb_build_object('what', c.title, 'classes', '• ' || c.class_type || ': ' || private.fmt_class_range(c.starts_at, c.ends_at, c.region)),
      false, 'cancelclass:' || c.id);
  end if;
  perform private.log_event('Team actions', 'Class cancelled: ' || c.title, 'class_session', c.id, null, null, p_reason,
    w.domain_id, w.module_id, w.id, c.id);
  perform private.queue_deliver('cancel class');
  return jsonb_build_object('ok', true);
end;
$$;
drop function if exists public.change_class_time(uuid, date, time, time, int, text, int);
create or replace function public.change_class_time(p_class_id uuid, p_date date, p_start time, p_end time,
  p_expected_version int default null, p_region text default null, p_fold int default null,
  p_accept_warnings boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  c public.class_session;
  v jsonb;
  v_region text;
  v_start timestamptz;
  v_end timestamptz;
  v_amb jsonb;
  v_booking public.booking;
  v_clash text;
  v_warn jsonb;
  v_week public.module_week;
begin
  perform private.require_team();
  -- SCH-2, SCH-8: lock the class week, then the class, before comparing versions or reading the booking.
  select * into v_week from public.module_week where id = (select module_week_id from public.class_session where id = p_class_id) for update;
  select * into c from public.class_session where id = p_class_id for update;
  if p_expected_version is not null and c.version <> p_expected_version then
    raise exception 'Someone else saved this class after you opened it. Reload the page to see their changes, then try again.' using errcode = '40001';
  end if;
  if c.status <> 'Planned' then raise exception 'Only planned classes can be moved.' using errcode = '22023'; end if;
  v_region := coalesce(p_region, c.region);
  if v_region not in ('US', 'India') then raise exception 'Choose US or India.' using errcode = '22023'; end if;
  v_amb := private.ambiguous_warning(p_date, p_start, v_region, c.title);
  if v_amb is not null and p_fold is null then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'needs_choice', true, 'warnings', jsonb_build_array(v_amb));
  end if;
  if p_end = p_start then raise exception 'The class must end after it starts.' using errcode = '22023'; end if;
  v_start := private.local_to_utc(p_date, p_start, v_region, p_fold);
  v_end := private.local_to_utc(p_date + case when p_end <= p_start then 1 else 0 end, p_end, v_region, p_fold);
  if (c.starts_at, c.ends_at, c.region) = (v_start, v_end, v_region) then
    return jsonb_build_object('unchanged', true);
  end if;
  -- SCH-1: one instructor teaches the whole week, so two of its classes never overlap.
  if v_week.same_instructor and private.week_self_overlap(c.module_week_id, v_start, v_end, c.id) is not null then
    raise exception 'The new time overlaps another class of the same class week: %. Choose another time.',
      private.week_self_overlap(c.module_week_id, v_start, v_end, c.id) using errcode = '23P01';
  end if;
  -- SCH-3: the same warnings as Plan classes and Add class (holidays, early or late hours, the cohort's other classes).
  -- "Short notice" is about planning a new class, not about moving one that is already planned.
  v_warn := coalesce((select jsonb_agg(x) from jsonb_array_elements(
              private.class_warnings(v_week.domain_id, v_week.cohort_id, v_start, v_end, c.module_week_id, c.title, v_region)) x
             where x ->> 'code' <> 'short_notice'), '[]');
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;
  -- A confirmed instructor can never end up with two classes at the same time: block the move and say why.
  select * into v_booking from public.booking where module_week_id = c.module_week_id and status = 'Active';
  if v_booking.id is not null then
    v_clash := private.clash_text(v_booking.instructor_id, v_start, v_end, v_region, c.module_week_id);
    if v_clash is not null then
      raise exception '% cannot teach at the new time: %. Choose another time, or release the instructor first.',
        (select full_name from public.instructor where id = v_booking.instructor_id), v_clash using errcode = '23P01';
    end if;
  end if;
  if c.region <> v_region then
    update public.class_session set region = v_region where id = p_class_id;
  end if;
  v := private.week_times_changed(c.module_week_id, private.mw_now(c.module_week_id), private.move_class(p_class_id, v_start, v_end));
  perform private.log_accepted_warnings(v_warn, p_reason, v_week.domain_id, v_week.module_id, v_week.id, c.id);
  perform private.queue_deliver('time change');
  return v;
end;
$$;
grant execute on function public.change_class_time(uuid, date, time, time, int, text, int, boolean, text) to authenticated, service_role;
revoke execute on function public.change_class_time(uuid, date, time, time, int, text, int, boolean, text) from anon, public;

create or replace function public.shift_classes(p_module_week_id uuid, p_weeks int, p_include_later boolean default true)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  w0 public.module_week;
  w record;
  c record;
  n int := 0;
  v_now timestamptz;
  v_msg text;
  v_clash boolean;
begin
  perform private.require_team();
  if p_weeks = 0 or abs(p_weeks) > 26 then raise exception 'Shift by 1 to 26 weeks.'; end if;
  select * into w0 from public.module_week where id = p_module_week_id;
  v_now := private.domain_now(w0.domain_id);
  -- Refuse (in plain words) a shift that would land on a week the same module already has.
  select m.name || ' already has a week starting ' || to_char(t.week_start_date, 'Mon FMDD, YYYY')
    into v_msg
    from public.module_week mw
    join public.module_week t on t.module_id = mw.module_id and t.cohort_id = mw.cohort_id and t.seq = mw.seq
                             and t.week_start_date = mw.week_start_date + 7 * p_weeks
    join public.module m on m.id = mw.module_id
   where mw.domain_id = w0.domain_id and mw.cohort_id = w0.cohort_id and mw.status not in ('Completed', 'Cancelled')
     and (mw.id = w0.id or (p_include_later and mw.week_start_date > w0.week_start_date))
     and not (t.id = w0.id or (p_include_later and t.week_start_date > w0.week_start_date and t.status not in ('Completed', 'Cancelled')))
   limit 1;
  if v_msg is not null then
    raise exception 'Can''t shift: %. Move or cancel that week first, or shift all later weeks too.', v_msg;
  end if;
  for w in select mw.* from public.module_week mw
            where mw.domain_id = w0.domain_id and mw.cohort_id = w0.cohort_id and mw.status not in ('Completed', 'Cancelled')
              and (mw.id = w0.id or (p_include_later and mw.week_start_date > w0.week_start_date))
            order by case when p_weeks > 0 then mw.week_start_date end desc, case when p_weeks < 0 then mw.week_start_date end asc loop
    update public.module_week set week_start_date = week_start_date + 7 * p_weeks where id = w.id;
    v_clash := false;
    -- Move every class of the week first (latest first when moving forward), then recalculate once,
    -- so the instructor gets one message with the final times.
    for c in select * from public.class_session where module_week_id = w.id and status = 'Planned'
              order by case when p_weeks > 0 then starts_at end desc, case when p_weeks < 0 then starts_at end asc loop
      -- keep the same Pacific wall-clock time across daylight saving changes
      v_clash := private.move_class(c.id,
        private.local_to_utc((c.starts_at at time zone private.region_tz(c.region))::date + 7 * p_weeks, (c.starts_at at time zone private.region_tz(c.region))::time, c.region),
        private.local_to_utc((c.ends_at at time zone private.region_tz(c.region))::date + 7 * p_weeks, (c.ends_at at time zone private.region_tz(c.region))::time, c.region))
        or v_clash;
    end loop;
    if v_clash then
      -- Nothing is saved: the person moving the dates sees who clashes and where.
      raise exception '% cannot teach % at the new dates: %. Release them first, or move fewer weeks.',
        (select i.full_name from public.booking b join public.instructor i on i.id = b.instructor_id
          where b.module_week_id = w.id and b.status = 'Active'),
        private.mw_label(w.id),
        coalesce(private.week_clash((select b.instructor_id from public.booking b where b.module_week_id = w.id and b.status = 'Active'), w.id),
                 'another class at the same time')
        using errcode = '23P01';
    end if;
    perform private.week_times_changed(w.id, v_now, v_clash);
    n := n + 1;
  end loop;
  perform private.log_event('Team actions', 'Shifted ' || n || ' module week(s) by ' || p_weeks || ' week(s)', 'module_week',
    p_module_week_id, null, null, null, w0.domain_id, w0.module_id, w0.id);
  perform private.queue_deliver('shift');
  return jsonb_build_object('ok', true, 'weeks_shifted', n);
end;
$$;
create or replace function public.create_module_weeks(p_domain_id uuid, p_rows jsonb, p_accept_warnings boolean default false,
  p_reason text default null, p_fold int default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  c jsonb;
  m public.module;
  v_mw uuid;
  v_group uuid;
  v_cohort uuid;
  v_ids uuid[] := '{}';
  v_problems text[] := '{}';
  v_warn jsonb := '[]';
  v_start timestamptz;
  v_end timestamptz;
  v_first date;
  v_seq int;
  v_batch jsonb := '[]';
  v_mode text := private.setting_text(p_domain_id, 'default_outreach_mode');
  v_end_b text := private.setting_text(p_domain_id, 'manual_end_behaviour');
  v_region text;
  v_amb jsonb;
begin
  perform private.require_team();
  -- SCH-5: one planner at a time per domain, so two people planning the same weeks cannot both save them.
  perform pg_advisory_xact_lock(hashtext('plan:' || p_domain_id::text));
  -- Checks first: nothing is saved when anything is blocked or warnings need confirming.
  for r in select * from jsonb_array_elements(p_rows) loop
    select * into m from public.module where id = (r ->> 'module_id')::uuid;
    if m.domain_id is distinct from p_domain_id then
      v_problems := v_problems || 'A module does not belong to this domain.'::text;
      continue;
    end if;
    if jsonb_array_length(coalesce(r -> 'classes', '[]')) = 0 then
      v_problems := v_problems || (m.name || ' has no classes in this plan. Add class times on the module page first.');
      continue;
    end if;
    v_cohort := coalesce((r ->> 'cohort_id')::uuid,
                         (select id from public.cohort where domain_id = p_domain_id and lower(name) = lower(coalesce(nullif(trim(r ->> 'cohort'), ''), 'Main cohort'))));
    select min((x ->> 'date')::date) into v_first from jsonb_array_elements(r -> 'classes') x;
    if v_cohort is not null and m.same_instructor_for_module_week and exists (
         select 1 from public.module_week w where w.module_id = m.id and w.cohort_id = v_cohort and w.week_start_date = v_first
                                              and w.status <> 'Cancelled') then
      v_problems := v_problems || ('Already planned: ' || m.name || ' starting ' || to_char(v_first, 'Dy, Mon FMDD, YYYY')
        || ' in ' || (select name from public.cohort where id = v_cohort) || '.');
    end if;
    for c in select * from jsonb_array_elements(r -> 'classes') loop
      v_region := coalesce(c ->> 'region', r ->> 'region', (select co.region from public.cohort co where co.id = v_cohort), 'US');
      v_start := private.local_to_utc((c ->> 'date')::date, (c ->> 'start_time')::time, v_region,
                                      coalesce((c ->> 'fold')::int, p_fold, 1));
      v_end := private.local_to_utc((c ->> 'date')::date + case when (c ->> 'end_time')::time <= (c ->> 'start_time')::time then 1 else 0 end,
                                    (c ->> 'end_time')::time, v_region, coalesce((c ->> 'fold')::int, p_fold, 1));
      -- SCH-5: a class of this module and cohort already planned at the same moment.
      if v_cohort is not null and exists (
           select 1 from public.class_session cs join public.module_week mw on mw.id = cs.module_week_id
            where mw.module_id = m.id and mw.cohort_id = v_cohort and cs.status <> 'Cancelled' and cs.starts_at = v_start) then
        v_problems := v_problems || ('Already planned: ' || coalesce(c ->> 'title', m.name) || ' on '
          || private.fmt_class_range(v_start, v_end, v_region) || '.');
      end if;
      -- SCH-1: classes of one class week (one instructor) never overlap each other.
      if m.same_instructor_for_module_week and exists (
           select 1 from jsonb_array_elements(r -> 'classes') o
            where o <> c
              and tstzrange(private.local_to_utc((o ->> 'date')::date, (o ->> 'start_time')::time, v_region, coalesce((o ->> 'fold')::int, p_fold, 1)),
                            private.local_to_utc((o ->> 'date')::date + case when (o ->> 'end_time')::time <= (o ->> 'start_time')::time then 1 else 0 end,
                                                 (o ->> 'end_time')::time, v_region, coalesce((o ->> 'fold')::int, p_fold, 1)), '[)')
                  && tstzrange(v_start, v_end, '[)')) then
        v_problems := v_problems || (coalesce(c ->> 'title', 'A class') || ' on ' || private.fmt_class_range(v_start, v_end, v_region)
          || ' overlaps another class of the same class week. One instructor teaches the whole week, so change one of the times.');
      end if;
      if (c ->> 'end_time')::time = (c ->> 'start_time')::time then
        v_problems := v_problems || (coalesce(c ->> 'title', 'A class') || ' must end after it starts.');
      end if;
      v_warn := v_warn || private.class_warnings(p_domain_id, v_cohort, v_start, v_end, null, c ->> 'title', v_region);
      v_amb := private.ambiguous_warning((c ->> 'date')::date, (c ->> 'start_time')::time, v_region, c ->> 'title');
      if v_amb is not null and coalesce((c ->> 'fold')::int, p_fold) is null then v_warn := v_warn || jsonb_build_array(v_amb); end if;
      -- Overlaps inside this plan (same cohort).
      if exists (select 1 from jsonb_array_elements(v_batch) b
                  where (b ->> 'cohort') = coalesce(v_cohort::text, lower(coalesce(r ->> 'cohort', '')))
                    and tstzrange((b ->> 's')::timestamptz, (b ->> 'e')::timestamptz, '[)') && tstzrange(v_start, v_end, '[)')) then
        v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'cohort_overlap',
          'text', coalesce(c ->> 'title', 'A class') || ' on ' || private.fmt_class_range(v_start, v_end, v_region) || ' overlaps another class in this plan for the same cohort.'));
      end if;
      v_batch := v_batch || jsonb_build_object('cohort', coalesce(v_cohort::text, lower(coalesce(r ->> 'cohort', ''))), 's', v_start, 'e', v_end);
    end loop;
  end loop;
  if cardinality(v_problems) > 0 then
    raise exception '%', array_to_string(v_problems, E'\n') using errcode = '23505';
  end if;
  if jsonb_array_length(v_warn) > 0 and not p_accept_warnings then
    return jsonb_build_object('ok', false, 'needs_confirmation', true, 'warnings', v_warn);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    select * into m from public.module where id = (r ->> 'module_id')::uuid;
    v_cohort := coalesce((r ->> 'cohort_id')::uuid, private.cohort_by_name(p_domain_id, r ->> 'cohort'));
    -- A cohort created by this plan gets the region chosen for it.
    if r ? 'region' and not exists (select 1 from public.module_week x where x.cohort_id = v_cohort) then
      update public.cohort set region = r ->> 'region' where id = v_cohort;
    end if;
    v_mw := null;
    v_group := null;
    for c in select * from jsonb_array_elements(r -> 'classes') x order by (x ->> 'date')::date, (x ->> 'start_time')::time loop
      v_region := coalesce(c ->> 'region', r ->> 'region', (select co.region from public.cohort co where co.id = v_cohort), 'US');
      v_start := private.local_to_utc((c ->> 'date')::date, (c ->> 'start_time')::time, v_region,
                                      coalesce((c ->> 'fold')::int, p_fold, 1));
      v_end := private.local_to_utc((c ->> 'date')::date + case when (c ->> 'end_time')::time <= (c ->> 'start_time')::time then 1 else 0 end,
                                    (c ->> 'end_time')::time, v_region, coalesce((c ->> 'fold')::int, p_fold, 1));
      if v_mw is null or not m.same_instructor_for_module_week then
        select coalesce(max(seq), 0) + 1 into v_seq from public.module_week
         where module_id = m.id and cohort_id = v_cohort and week_start_date = (c ->> 'date')::date;
        insert into public.module_week (module_id, cohort_id, week_start_date, seq, outreach_mode, manual_end_behaviour,
                                        same_instructor, split_group)
        values (m.id, v_cohort, (c ->> 'date')::date, v_seq,
                private.setting_text(coalesce(v_cohort, p_domain_id), 'default_outreach_mode'),
                private.setting_text(coalesce(v_cohort, p_domain_id), 'manual_end_behaviour'),
                m.same_instructor_for_module_week, v_group)
        returning id into v_mw;
        if not m.same_instructor_for_module_week then
          v_group := coalesce(v_group, v_mw);
          update public.module_week set split_group = v_group where id = v_mw;
        end if;
        v_ids := v_ids || v_mw;
      end if;
      insert into public.class_session (module_week_id, pattern_item_id, class_type, title, starts_at, ends_at, region)
      values (v_mw, nullif(c ->> 'pattern_item_id', '')::uuid, coalesce(nullif(c ->> 'class_type', ''), 'Other'),
              coalesce(nullif(c ->> 'title', ''), 'Class'), v_start, v_end, v_region);
    end loop;
  end loop;
  perform private.log_accepted_warnings(v_warn, p_reason, p_domain_id);
  perform private.log_event('Team actions', 'Planned ' || cardinality(v_ids) || ' class week(s)', 'domain', p_domain_id,
    null, jsonb_build_object('module_week_ids', to_jsonb(v_ids)), nullif(trim(coalesce(p_reason, '')), ''), p_domain_id);
  return jsonb_build_object('ok', true, 'created', cardinality(v_ids), 'module_week_ids', to_jsonb(v_ids), 'warnings', v_warn);
end;
$$;
create or replace function public.submit_help_request(p_token text, p_categories text[], p_details text, p_urgency text, p_reply_channel text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  lnk public.response_link;
  r public.request;
  w public.module_week;
  v_now timestamptz;
  v_res jsonb;
  v_name text;
begin
  perform private.require_team();
  select * into lnk from public.response_link where token = p_token;
  if lnk.token is null or lnk.answer not in ('NeedHelp', 'OwnerNeedHelp') then
    return jsonb_build_object('result', 'invalid', 'message', 'This link isn''t valid.');
  end if;
  select * into r from public.request where id = lnk.request_id;
  select * into w from public.module_week where id = r.module_week_id;
  if w.status in ('Cancelled', 'Completed') then
    return jsonb_build_object('result', 'closed', 'message', 'This class is no longer scheduled.');
  end if;
  if p_urgency not in ('NoRush', 'Within24h', 'Urgent') or p_reply_channel not in ('Discord', 'Email', 'Either') then
    return jsonb_build_object('result', 'invalid', 'message', 'Please choose how soon you need this and how we should reply.');
  end if;
  v_now := private.domain_now(w.domain_id);
  if v_now <> now() then perform private.set_sim_now(v_now); end if;
  if r.instructor_id is not null then
    select i.full_name into v_name from public.instructor i where i.id = r.instructor_id;
    perform private.set_actor('Instructor', r.instructor_id, v_name);
    v_res := private.create_help_request(w.id, r.instructor_id, null, 'Instructor', p_categories, p_details,
      p_urgency, p_reply_channel, v_now, r.booking_id);
    if r.kind = 'CheckIn' and r.status in ('Sent', 'Reminded') then
      update public.request set status = 'Accepted', answer = 'NeedHelp', answered_at = v_now where id = r.id;
      perform private.resolve_attention('checkin_noreply:' || r.id, 'Instructor asked for help');
    end if;
    update public.instructor set last_response_at = v_now where id = r.instructor_id;
  else
    select t.name into v_name from public.team_member t where t.id = r.team_member_id;
    perform private.set_actor('TeamMember', null, v_name);
    v_res := private.create_help_request(w.id, null, r.team_member_id, 'Owner', p_categories, p_details,
      p_urgency, p_reply_channel, v_now);
  end if;
  return jsonb_build_object('result', 'help_created', 'help_request_id', v_res ->> 'id', 'merged', v_res -> 'merged',
    'message', 'Thanks! ' || (v_res ->> 'helper') || ' will reply by ' || private.fmt_local((v_res ->> 'target_at')::timestamptz, private.week_region(w.id)) || '.');
end;
$$;

-- ------------------------------------------------------------------ SEC-1: the Workspace check uses Google's own data
-- The hd claim and the provider come from auth.identities (written by Supabase Auth from Google),
-- not from user_metadata, which a signed in user can change.
create or replace function private.jwt_hd()
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(i.identity_data ->> 'hd', i.identity_data -> 'custom_claims' ->> 'hd')
    from auth.identities i
   where i.user_id = (select auth.uid()) and i.provider = 'google'
   order by i.last_sign_in_at desc nulls last limit 1;
$$;

/** How this session signed in: 'google' only for a Google sign in of a user with a Google identity. */
create or replace function private.jwt_provider()
returns text language sql stable security definer set search_path = ''
as $$
  select case
    when (select auth.jwt()) ? 'amr' then
      case when exists (select 1 from jsonb_array_elements((select auth.jwt()) -> 'amr') a where a ->> 'method' = 'oauth')
                and exists (select 1 from auth.identities i where i.user_id = (select auth.uid()) and i.provider = 'google')
           then 'google' else coalesce((select auth.jwt()) -> 'amr' -> 0 ->> 'method', 'unknown') end
    when exists (select 1 from auth.identities i where i.user_id = (select auth.uid()) and i.provider = 'google') then 'google'
    else (select auth.jwt()) -> 'app_metadata' ->> 'provider' end;
$$;

-- ------------------------------------------------------------------ SEC-6: an environment that was never set fails closed
alter table public.app_config add column if not exists environment_set_at timestamptz;
alter table public.app_config alter column environment set default 'Sandbox';
-- A database still on the old default (never configured) is treated as Sandbox: Google sign in only,
-- the Sandbox allow lists, and no data reset until someone configures it. Local development sets
-- Development in supabase/seed.sql; hosted projects run `npm run configure:<env> -w scripts`.
update public.app_config set environment = 'Sandbox' where id = 1 and environment = 'Development' and environment_set_at is null;

create or replace function private.sign_in_problem(p_email text, p_provider text, p_hd text)
returns text language sql stable security definer set search_path = ''
as $$
  select case
    when coalesce(c.company_email_domain, '') = '' then
      'Sign in is not set up yet. Ask the admin to set the company email domain.'
    when lower(split_part(coalesce(p_email, ''), '@', 2)) <> lower(c.company_email_domain) then
      'Only company Google accounts can use SME Scheduling.'
    when c.environment <> 'Development' and coalesce(p_provider, '') <> 'google' then
      'Please sign in with your company Google account.'
    when c.environment <> 'Development' and lower(coalesce(p_hd, '')) <> lower(c.company_email_domain) then
      'Only company Google accounts can use SME Scheduling.'
    when exists (select 1 from public.team_member t where t.access_removed_at is not null
                   and (lower(t.email) = lower(p_email) or t.auth_user_id = (select auth.uid()))) then
      'Your access to SME Scheduling was removed. Ask your team lead if you think this is a mistake.'
  end
  from public.app_config c where c.id = 1;
$$;

-- ------------------------------------------------------------------ SEC-2: removed access stays removed
create or replace function private.team_member_removed_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.access_removed_at is not null and current_setting('app.reset_sandbox', true) is distinct from 'on' then
      raise exception 'People whose access was removed stay on the Team page, so they cannot sign in again with this address. Give their access back first if you want to change them.'
        using errcode = '42501';
    end if;
    return old;
  end if;
  if old.access_removed_at is not null and new.access_removed_at is not null
     and (lower(new.email) is distinct from lower(old.email) or new.auth_user_id is distinct from old.auth_user_id) then
    raise exception 'The email of someone whose access was removed cannot be changed. Give their access back first.' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists team_member_removed_guard on public.team_member;
create trigger team_member_removed_guard before update or delete on public.team_member
  for each row execute function private.team_member_removed_guard();

create or replace function public.set_member_access(p_team_member_id uuid, p_has_access boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare t public.team_member; v_me uuid := private.current_team_member_id();
begin
  perform private.require_team();
  select * into t from public.team_member where id = p_team_member_id for update;
  if t.id is null then raise exception 'Team member not found.' using errcode = '22023'; end if;
  if not p_has_access and t.id = v_me then
    raise exception 'You cannot remove your own access.' using errcode = '22023';
  end if;
  if p_has_access = (t.access_removed_at is null) then return; end if;
  perform set_config('app.suppress_setup_log', 'on', true);
  update public.team_member
     set access_removed_at = case when p_has_access then null else now() end,
         access_removed_by = case when p_has_access then null else v_me end,
         active = p_has_access,
         version = version
   where id = t.id;
  perform set_config('app.suppress_setup_log', 'off', true);
  -- Removing access also signs the person out everywhere (their refresh tokens go with the sessions).
  if not p_has_access and t.auth_user_id is not null then
    begin
      delete from auth.sessions where user_id = t.auth_user_id;
    exception when others then
      perform private.log_event('System', 'Could not end the sessions of ' || t.name, 'team_member', t.id, null, null, sqlerrm);
    end;
  end if;
  perform private.log_event('Setup changes', case when p_has_access then 'Access given back' else 'Access removed' end,
    'team_member', t.id, jsonb_build_object('name', t.name, 'has_access', not p_has_access),
    jsonb_build_object('name', t.name, 'has_access', p_has_access), nullif(trim(coalesce(p_reason, '')), ''));
end;
$$;

-- ------------------------------------------------------------------ SEC-3: answer links never readable by the team
-- Messages keep a placeholder instead of each answer link's secret. claim_outbound_messages (the
-- automation only) puts the secret back when it hands a message to n8n.
create index if not exists response_link_token_md5 on public.response_link (md5(token));

create or replace function private.with_tokens(p text)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare m text[]; v text := p;
begin
  if p is null or position('{{t:' in p) = 0 then return p; end if;
  for m in select regexp_matches(p, '\{\{t:([0-9a-f]{32})\}\}', 'g') loop
    v := replace(v, '{{t:' || m[1] || '}}',
                 coalesce((select l.token from public.response_link l where md5(l.token) = m[1] limit 1), 'expired'));
  end loop;
  return v;
end;
$$;
revoke execute on function private.with_tokens(text) from public;

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
      || '?t={{t:' || md5(v_token) || '}}';
end;
$$;

-- Messages written before this change: swap each secret for its placeholder.
do $$
declare l record;
begin
  for l in select token from public.response_link loop
    update public.message
       set body_text = replace(body_text, '?t=' || l.token, '?t={{t:' || md5(l.token) || '}}'),
           body_html = replace(body_html, '?t=' || l.token, '?t={{t:' || md5(l.token) || '}}'),
           buttons = replace(buttons::text, '?t=' || l.token, '?t={{t:' || md5(l.token) || '}}')::jsonb
     where position(l.token in coalesce(body_text, '') || coalesce(body_html, '') || coalesce(buttons::text, '')) > 0;
  end loop;
end $$;

-- ------------------------------------------------------------------ SEC-4: links are part of the setup, not of the app
alter table public.app_config drop constraint if exists app_config_links_check;
alter table public.app_config add constraint app_config_links_check check (
  (response_base_url is null or response_base_url ~ '^https://[^/\s]+' or response_base_url ~ '^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)')
  and (app_base_url is null or app_base_url ~ '^https://[^/\s]+' or app_base_url ~ '^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)')) not valid;

create or replace function public.set_app_config(p_config jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare c public.app_config;
begin
  perform private.require_team();
  select * into c from public.app_config where id = 1;
  if (p_config ->> 'version')::int is distinct from c.version then
    raise exception 'This changed — reload. Someone else saved the system settings after you opened them.' using errcode = '40001';
  end if;
  if p_config ? 'company_email_domain' and lower(trim(p_config ->> 'company_email_domain')) <> c.company_email_domain then
    raise exception 'The company email domain can only be changed by an admin in the database (see docs/SETUP.md).';
  end if;
  if (p_config ? 'response_base_url' and nullif(trim(p_config ->> 'response_base_url'), '') is distinct from c.response_base_url)
     or (p_config ? 'app_base_url' and nullif(trim(p_config ->> 'app_base_url'), '') is distinct from c.app_base_url) then
    raise exception 'The answer link address and the app address are set when the app is set up (npm run configure, see docs/SETUP_GUIDE.md), so nobody can point instructors somewhere else from the app.'
      using errcode = '42501';
  end if;
  update public.app_config set
    discord_guild_id = nullif(trim(coalesce(p_config ->> 'discord_guild_id', discord_guild_id)), ''),
    response_base_url = nullif(trim(coalesce(p_config ->> 'response_base_url', response_base_url)), ''),
    app_base_url = nullif(trim(coalesce(p_config ->> 'app_base_url', app_base_url)), ''),
    admin_discord_channel_id = nullif(trim(coalesce(p_config ->> 'admin_discord_channel_id', admin_discord_channel_id)), ''),
    scheduling_email = nullif(trim(coalesce(p_config ->> 'scheduling_email', scheduling_email)), ''),
    scheduling_sender_name = coalesce(nullif(trim(p_config ->> 'scheduling_sender_name'), ''), scheduling_sender_name)
  where id = 1;
end;
$$;
drop function if exists public.configure_environment(text, text, text[], text[]);
create or replace function public.configure_environment(p_environment text, p_allowed_email_domain text,
  p_sandbox_discord_servers text[] default null, p_sandbox_email_domains text[] default null,
  p_response_base_url text default null, p_app_base_url text default null)
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
         response_base_url = coalesce(nullif(trim(p_response_base_url), ''), response_base_url),
         app_base_url = coalesce(nullif(trim(p_app_base_url), ''), app_base_url),
         environment_set_at = now(),
         sandbox_allowed_email_domains = coalesce(array(select lower(trim(x)) from unnest(p_sandbox_email_domains) x where trim(x) <> ''),
                                                  sandbox_allowed_email_domains)
   where id = 1;
  perform private.log_event('System', 'Environment set to ' || p_environment, 'app_config', null, null,
    jsonb_build_object('environment', p_environment, 'allowed_email_domain', lower(trim(p_allowed_email_domain)),
      'sandbox_allowed_discord_servers', to_jsonb(coalesce(p_sandbox_discord_servers, '{}')),
      'sandbox_allowed_email_domains', to_jsonb(coalesce(p_sandbox_email_domains, '{}'))));
end;
$$;
revoke execute on function public.configure_environment(text, text, text[], text[], text, text) from anon, authenticated, public;
grant execute on function public.configure_environment(text, text, text[], text[], text, text) to service_role;

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
  -- SEC-6: only a database that was set up as Sandbox (or local development) on purpose.
  if (select environment_set_at from public.app_config where id = 1) is null then
    raise exception 'This database was never set up with npm run configure, so its data cannot be reset.' using errcode = '42501';
  end if;
  perform set_config('app.reset_sandbox', 'on', true);
  if p_confirm is distinct from 'RESET' then
    raise exception 'Type RESET to confirm.' using errcode = '22023';
  end if;
  perform private.log_event('System', 'Sandbox data reset started');
  -- Run any checks still waiting in this transaction (instructor order) before clearing tables.
  set constraints all immediate;
  -- Keep holidays and settings that apply to every domain (truncating domains would remove them).
  create temp table reset_keep_holiday on commit drop as select date, name, region from public.holiday where domain_id is null;
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
  -- The made up Sandbox people are found by their Sandbox email too: saving one on the Team page
  -- clears "needs real details", and the reset must still replace them.
  delete from public.team_member
   where is_placeholder or split_part(lower(email), '@', 1) in ('sandbox.owner', 'sandbox.operations', 'sandbox.escalation');
  insert into public.holiday (date, name, region) select date, name, region from reset_keep_holiday on conflict do nothing;
  insert into public.setting (scope, key, value) select 'Global', key, value from reset_keep_setting;
  update public.system_state set outreach_enabled = true where id = 1;
  v := private.load_sandbox_seed(p_test_email, p_test_discord_user_id, p_test_channel_id);
  set constraints all deferred;
  return v;
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
  if c.environment = 'Production' and m.audience = 'Instructor' and coalesce(i.is_test, false) then
    return 'Production never messages test instructors.';
  end if;
  if m.channel = 'Discord' and m.discord_channel_id is not null and m.discord_dm_user_id is not null then
    return 'A Discord message goes either to a channel or to one person, not both.';
  end if;
  if c.environment = 'Sandbox' then
    if m.channel = 'Email' then
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
        -- Only to an account the app knows: a test instructor or a team member, never a real instructor.
        if exists (select 1 from public.instructor x where x.discord_user_id = m.discord_dm_user_id and not x.is_test)
           or not (exists (select 1 from public.instructor x where x.discord_user_id = m.discord_dm_user_id and x.is_test)
                   or exists (select 1 from public.team_member t where t.discord_user_id = m.discord_dm_user_id)) then
          return 'Sandbox only sends direct messages to test instructors and team members.';
        end if;
        return null;
      end if;
      -- The channel must be one the bot listed, in an allowed server (no guessing from the domain).
      v_server := (select ch.server_id from public.discord_channel ch where ch.id = m.discord_channel_id);
      if v_server is null then
        return 'Sandbox only posts to channels the bot has listed. Press Check on Settings, Connections first.';
      end if;
      if not (v_server = any (c.sandbox_allowed_discord_servers)) then
        return 'Sandbox only posts to allowed Discord servers. Server ' || v_server || ' is not on the list.';
      end if;
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists message_environment_guard on public.message;
create trigger message_environment_guard
  before insert or update of status, to_address, discord_channel_id, discord_dm_user_id, mention_user_ids on public.message
  for each row execute function private.message_environment_guard();

