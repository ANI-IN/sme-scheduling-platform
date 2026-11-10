-- Release Milestone 5: database support for the page by page improvements.
-- Plain wording in every message and confirm page, editable message templates per domain, holidays
-- per domain, extra checklist items per class, "Start asking now", copying settings between domains,
-- saving many settings at once, the Home setup checklist, the Modules overview, and a practice class
-- run that tests every stage and cleans up after itself.

-- -------------------------------------------------------------------------------------
-- Plain wording: no dashes in anything an instructor or the team reads
-- -------------------------------------------------------------------------------------
-- " — " starts a new sentence, a dash between numbers or times means "to", any other dash becomes a comma.
create or replace function private.plain_message_text(p text)
returns text language plpgsql immutable set search_path = ''
as $$
declare v text := p; m text[];
begin
  if v is null then return null; end if;
  v := regexp_replace(v, '(\d)\s*[–—]\s*(\d)', '\1 to \2', 'g');
  v := regexp_replace(v, '(AM|PM)\s*[–—]\s*', '\1 to ', 'g');
  loop
    m := regexp_match(v, '\s+[—–]\s+(\S)');
    exit when m is null;
    v := regexp_replace(v, '\s+[—–]\s+(\S)', '. ' || upper(m[1]));
  end loop;
  v := replace(replace(v, '—', ', '), '–', ' to ');
  v := replace(v, '..', '.');
  v := replace(v, '?.', '?');
  v := replace(v, '!.', '!');
  return v;
end;
$$;

create or replace function private.message_plain_words()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.subject := private.plain_message_text(new.subject);
  new.body_text := private.plain_message_text(new.body_text);
  new.body_html := private.plain_message_text(new.body_html);
  return new;
end;
$$;
create trigger message_plain_words before insert or update of subject, body_text, body_html on public.message
  for each row execute function private.message_plain_words();


create or replace function private.page(p_title text, p_body text)
returns text language sql immutable set search_path = ''
as $$
  select '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    || '<meta name="viewport" content="width=device-width,initial-scale=1">'
    || '<meta name="robots" content="noindex,nofollow">'
    || '<title>' || private.html_escape(private.plain_message_text(p_title)) || ' · SME Scheduling</title>'
    || '<style>'
    || 'body{margin:0;background:#f6f8fa;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#1f2328;font-size:16px;line-height:1.5}'
    || '.card{max-width:560px;margin:24px auto;background:#fff;border:1px solid #d1d9e0;border-radius:12px;padding:24px 20px}'
    || 'h1{font-size:22px;margin:0 0 12px}.muted{color:#59636e;font-size:14px}'
    || 'ul{padding-left:20px}li{margin:4px 0}'
    || 'button,.btn{display:block;width:100%;box-sizing:border-box;margin:12px 0 0;padding:14px;border:0;border-radius:8px;'
    || 'background:#1f6feb;color:#fff;font-size:17px;font-weight:600;text-align:center;text-decoration:none;cursor:pointer}'
    || '.danger{background:#cf222e}.secondary{background:#eef1f4;color:#1f2328}'
    || 'fieldset{border:1px solid #d1d9e0;border-radius:8px;margin:14px 0;padding:10px 12px}legend{font-weight:600;padding:0 4px}'
    || 'label{display:block;margin:6px 0}textarea{width:100%;box-sizing:border-box;min-height:90px;font:inherit;padding:8px;border:1px solid #d1d9e0;border-radius:6px}'
    || 'details{margin-top:16px}summary{cursor:pointer;font-weight:600;color:#1f6feb}'
    || '</style></head><body><div class="card">' || private.plain_message_text(p_body)
    || '<p class="muted" style="margin-top:24px">SME Scheduling</p></div></body></html>';
$$;


-- -------------------------------------------------------------------------------------
-- Message templates (to instructors), editable per domain
-- -------------------------------------------------------------------------------------
create table public.message_template (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete cascade,
  template_id text not null,
  subject text not null check (length(trim(subject)) > 0),
  body text not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (domain_id, template_id)
);
create trigger message_template_touch before update on public.message_template for each row execute function private.touch_row();
create trigger message_template_created_by before insert on public.message_template for each row execute function private.set_created_by();
create trigger message_template_history after insert or update or delete on public.message_template
  for each row execute function private.log_setup_change();
alter table public.message_template enable row level security;
revoke all on public.message_template from anon, authenticated;
grant all on public.message_template to service_role;
grant select on public.message_template to authenticated;
create policy message_template_team_read on public.message_template for select to authenticated using (private.is_team_user());

-- Default texts. Variables in braces are filled in when the message is sent. Buttons (Yes, No, All
-- set, Need help…) are added to every message automatically.
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
      'body', E'Thank you, {first_name}. You are confirmed for {module} 🎉\n\n{classes}{materials}\n\nYour contact: {contact}',
      'required', jsonb_build_array('module', 'classes')),
    'M5', jsonb_build_object('name', 'Class time change', 'subject', '{module} moved: does this still work?',
      'body', E'{module} moved to new times:\n\n{classes}\n\nDoes this still work?{reply_by}',
      'required', jsonb_build_array('module', 'classes')),
    'M6', jsonb_build_object('name', 'Reminder before class', 'subject', '{module} is in {days} days: all set?',
      'body', E'{module} is {days} days away ({first_class}). Anything you need?\n\n{classes}{materials}',
      'required', jsonb_build_array('module', 'classes')),
    'M7', jsonb_build_object('name', 'Final reminder before class', 'subject', '{module} is on {weekday}',
      'body', E'{module} is on {first_class}.\n\n{classes}{materials}\n\nAll set?',
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
      'body', 'This is a test from SME Scheduling. Please tap the button to confirm you received it.', 'required', '[]'::jsonb));
$$;

create or replace function private.template_variables()
returns text[] language sql immutable set search_path = ''
as $$ select array['first_name', 'name', 'module', 'domain', 'classes', 'first_class', 'weekday', 'deadline', 'reply_by',
                   'materials', 'contact', 'days', 'what', 'helper', 'by', 'text', 'from']; $$;

create or replace function private.fill_template(p_text text, p_vars jsonb)
returns text language plpgsql immutable set search_path = ''
as $$
declare v text := p_text; k text;
begin
  for k in select jsonb_object_keys(p_vars) loop
    v := replace(v, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return v;
end;
$$;

-- Unknown variables and missing required details, as a list of plain sentences.
create or replace function private.template_problems(p_template text, p_subject text, p_body text)
returns text[] language plpgsql immutable set search_path = ''
as $$
declare
  v_def jsonb := private.template_defaults() -> p_template;
  v_out text[] := '{}';
  r text;
  m text[];
begin
  if v_def is null then return array['Unknown message.']; end if;
  if coalesce(trim(p_subject), '') = '' then v_out := v_out || 'Write a subject.'::text; end if;
  if coalesce(trim(p_body), '') = '' then v_out := v_out || 'Write the message.'::text; end if;
  for m in select regexp_matches(coalesce(p_subject, '') || ' ' || coalesce(p_body, ''), '\{([^}]*)\}', 'g') loop
    if not (m[1] = any (private.template_variables())) then
      v_out := v_out || ('{' || m[1] || '} is not a known detail.');
    end if;
  end loop;
  for r in select jsonb_array_elements_text(v_def -> 'required') loop
    if position('{' || r || '}' in coalesce(p_body, '')) = 0 then
      v_out := v_out || ('The message must include {' || r || '}' || case r
        when 'classes' then ' (the class, date and time).' when 'deadline' then ' (when to reply by).' else '.' end);
    end if;
  end loop;
  return v_out;
end;
$$;

-- Builds the subject and text of an instructor message from the domain's template (or the default).
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
        'first_class', private.fmt_pt(v_first),
        'weekday', to_char(v_first at time zone 'America/Los_Angeles', 'FMDay'),
        'contact', private.team_names(private.owners_or_leads(m.id)),
        'materials', case when coalesce(v_materials, '') <> '' then E'\n\nMaterials:\n' || v_materials else '' end)
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
  return jsonb_build_object('subject', private.plain_message_text(v_subject), 'body', private.plain_message_text(v_body),
    'first_name', private.first_name(v_name), 'name', v_name);
end;
$$;

-- For the Message templates page: every template with its current text and whether it is changed.
create or replace function public.message_templates(p_domain_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('template_id', k, 'name', v ->> 'name',
           'subject', coalesce(t.subject, v ->> 'subject'), 'body', coalesce(t.body, v ->> 'body'),
           'default_subject', v ->> 'subject', 'default_body', v ->> 'body', 'required', v -> 'required',
           'changed', t.id is not null, 'version', t.version, 'updated_at', t.updated_at, 'updated_by', t.updated_by)
         order by (substr(k, 2))::int), '[]')
    from jsonb_each(private.template_defaults()) x(k, v)
    left join public.message_template t on t.domain_id = p_domain_id and t.template_id = k
   where private.is_team_user() or private.is_service();
$$;

create or replace function public.save_message_template(p_domain_id uuid, p_template_id text, p_subject text, p_body text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_problems text[];
begin
  perform private.require_team();
  v_problems := private.template_problems(p_template_id, p_subject, p_body);
  if cardinality(v_problems) > 0 then
    raise exception '%', array_to_string(v_problems, ' ') using errcode = '22023';
  end if;
  insert into public.message_template (domain_id, template_id, subject, body)
  values (p_domain_id, p_template_id, trim(p_subject), trim(p_body))
  on conflict (domain_id, template_id) do update set subject = excluded.subject, body = excluded.body;
end;
$$;

create or replace function public.reset_message_template(p_domain_id uuid, p_template_id text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  delete from public.message_template where domain_id = p_domain_id and template_id = p_template_id;
end;
$$;

-- Live preview with a real upcoming class week of the domain when there is one, else sample details.
create or replace function public.preview_message_template(p_domain_id uuid, p_template_id text, p_subject text, p_body text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_mw uuid;
  v_vars jsonb;
begin
  perform private.require_team();
  select w.id into v_mw from public.module_week w
   where w.domain_id = p_domain_id and w.status not in ('Cancelled', 'Completed') and w.first_class_at is not null
   order by (w.first_class_at > now()) desc, w.first_class_at limit 1;
  if v_mw is not null then
    select jsonb_build_object('module', m.name, 'domain', d.name, 'classes', private.class_lines(w.id),
             'first_class', private.fmt_pt(w.first_class_at), 'weekday', to_char(w.first_class_at at time zone 'America/Los_Angeles', 'FMDay'),
             'contact', private.team_names(private.owners_or_leads(m.id)),
             'materials', coalesce(nullif(E'\n\nMaterials:\n' || nullif(private.materials_line(w.id), ''), E'\n\nMaterials:\n'), ''))
      into v_vars
      from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id where w.id = v_mw;
  else
    v_vars := jsonb_build_object('module', 'Concurrency', 'domain', coalesce((select name from public.domain where id = p_domain_id), 'Backend'),
      'classes', E'• Live class: Sun, Jan 31, 9:00 AM to 1:00 PM PST\n• Assignment review: Thu, Feb 4, 6:00 PM to 8:00 PM PST',
      'first_class', 'Sun Jan 31, 9:00 AM PST', 'weekday', 'Sunday', 'contact', 'Your module owner', 'materials', '');
  end if;
  v_vars := v_vars || jsonb_build_object('first_name', 'Alex', 'name', 'Alex Example', 'deadline', 'Tue Jan 5, 9:00 AM PST',
    'reply_by', E'\nPlease reply by Tue Jan 5, 9:00 AM PST.', 'days', '10', 'what', v_vars ->> 'module',
    'helper', 'Your module owner', 'by', 'Wed Jan 6, 5:00 PM PST', 'text', 'Here is the Zoom link you asked for.', 'from', 'The operations team');
  return jsonb_build_object(
    'subject', private.plain_message_text(private.fill_template(p_subject, v_vars)),
    'body', private.plain_message_text(private.fill_template(p_body, v_vars)),
    'problems', to_jsonb(private.template_problems(p_template_id, p_subject, p_body)));
end;
$$;

-- Sends the preview to the domain's alert channel (the testing channel while testing).
create or replace function public.send_template_test(p_domain_id uuid, p_template_id text, p_subject text, p_body text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v jsonb := public.preview_message_template(p_domain_id, p_template_id, p_subject, p_body);
begin
  perform private.queue_team_message('T0', p_domain_id, 'alert', null, array[private.current_team_member_id()],
    'Message test: ' || (v ->> 'subject'), 'Message test (what an instructor would see):' || E'\n\n' || (v ->> 'subject') || E'\n\n' || (v ->> 'body'),
    'T0:template:' || p_domain_id || ':' || p_template_id || ':' || extract(epoch from now())::bigint, now());
  perform private.log_event('Team actions', 'Message test sent', 'message_template', null, null,
    jsonb_build_object('template', p_template_id), null, p_domain_id);
  perform private.queue_deliver('template test');
end;
$$;

-- -------------------------------------------------------------------------------------
-- Holidays per domain (none set = every domain)
-- -------------------------------------------------------------------------------------
alter table public.holiday add column domain_id uuid references public.domain (id) on delete cascade;
alter table public.holiday drop constraint holiday_date_key;
create unique index holiday_date_uq on public.holiday (coalesce(domain_id, '00000000-0000-0000-0000-000000000000'::uuid), date);

create or replace function private.holiday_on(p_domain uuid, p_date date)
returns text language sql stable security definer set search_path = ''
as $$
  select string_agg(h.name, ', ' order by h.name) from public.holiday h
   where h.date = p_date and (h.domain_id is null or h.domain_id = p_domain);
$$;


create or replace function private.class_warnings(p_domain uuid, p_cohort uuid, p_start timestamptz, p_end timestamptz,
  p_exclude_week uuid default null, p_label text default null)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with t as (
    select (p_start at time zone 'America/Los_Angeles') as s, (p_end at time zone 'America/Los_Angeles') as e,
           coalesce(p_label || ' on ', '') || private.fmt_pt_range(p_start, p_end) as what)
  select coalesce(jsonb_agg(x.w), '[]') from (
    select jsonb_build_object('code', 'holiday', 'text', t.what || ' is on a holiday (' || h.name || ').') as w
      from t join public.holiday h on h.date = t.s::date and (h.domain_id is null or h.domain_id = p_domain)
    union all
    select jsonb_build_object('code', 'unusual_hours', 'text', t.what || ' is outside 6 AM to 10 PM Pacific.')
      from t where t.s::time < '06:00' or t.e::time > '22:00' or t.e::date > t.s::date
    union all
    select jsonb_build_object('code', 'cohort_overlap', 'text',
             t.what || ' overlaps ' || c.title || ' (' || private.fmt_pt_range(c.starts_at, c.ends_at) || ') in the same cohort.')
      from t, public.class_session c join public.module_week w on w.id = c.module_week_id
     where p_cohort is not null and w.cohort_id = p_cohort and c.status = 'Planned'
       and (p_exclude_week is null or w.id <> p_exclude_week)
       and tstzrange(c.starts_at, c.ends_at, '[)') && tstzrange(p_start, p_end, '[)')
    union all
    select jsonb_build_object('code', 'short_notice', 'text',
             t.what || ' is only ' || greatest(0, floor(extract(epoch from (p_start - private.domain_now(p_domain))) / 86400))::int
             || ' days away, so instructors are asked straight away with short reply times.')
      from t where p_start - private.domain_now(p_domain) < make_interval(days => private.setting_int(p_domain, 'outreach_days'))
                and p_start > private.domain_now(p_domain)
  ) x;
$$;

create or replace function public.generate_classes(p_domain_id uuid, p_start_module_id uuid, p_week_starts date[], p_cohort text default '')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_mods uuid[];
  v_start int;
  v_out jsonb := '[]';
  i int;
  v_mod uuid;
  m public.module;
  v_d date;
  v_cohort uuid;
  v_min int;
  v_classes jsonb;
  v_warn jsonb;
  p record;
  v_s timestamptz;
  v_e timestamptz;
begin
  perform private.require_team();
  select array_agg(id order by rotation_order, name) into v_mods from public.module where domain_id = p_domain_id and status = 'Active';
  if v_mods is null then raise exception 'This domain has no active modules yet.'; end if;
  v_start := coalesce(array_position(v_mods, p_start_module_id), 1);
  select id into v_cohort from public.cohort where domain_id = p_domain_id and lower(name) = lower(coalesce(nullif(trim(p_cohort), ''), 'Main cohort'));
  for i in 1 .. coalesce(cardinality(p_week_starts), 0) loop
    v_d := p_week_starts[i];
    v_mod := v_mods[((v_start - 1 + i - 1) % cardinality(v_mods)) + 1];
    select * into m from public.module where id = v_mod;
    select min(day_offset) into v_min from private.pattern_for(v_mod, v_cohort);
    v_classes := '[]';
    v_warn := '[]';
    for p in select * from private.pattern_for(v_mod, v_cohort) loop
      v_s := private.pt_to_utc(v_d + (p.day_offset - v_min), p.start_time_pt);
      v_e := v_s + make_interval(mins => p.duration_minutes);
      v_classes := v_classes || jsonb_build_object(
        'pattern_item_id', p.id, 'class_type', p.class_type,
        'title', replace(replace(p.title_template, '{module}', m.name), '{class_type}', p.class_type),
        'date', v_d + (p.day_offset - v_min), 'start_time', to_char(p.start_time_pt, 'HH24:MI'),
        'end_time', to_char(p.start_time_pt + make_interval(mins => p.duration_minutes), 'HH24:MI'),
        'starts_at', v_s, 'ends_at', v_e, 'shown', private.fmt_pt_range(v_s, v_e),
        'holiday', private.holiday_on(p_domain_id, v_d + (p.day_offset - v_min)));
      v_warn := v_warn || private.class_warnings(p_domain_id, v_cohort, v_s, v_e, null,
        replace(replace(p.title_template, '{module}', m.name), '{class_type}', p.class_type));
    end loop;
    v_out := v_out || jsonb_build_object('week_start_date', v_d, 'module_id', v_mod, 'module_name', m.name,
      'cohort', coalesce(nullif(trim(p_cohort), ''), 'Main cohort'), 'same_instructor', m.same_instructor_for_module_week,
      'classes', v_classes, 'warnings', v_warn,
      'problem', case when jsonb_array_length(v_classes) = 0
                      then m.name || ' has no class times yet. Add them on the module page before planning.' end,
      'duplicate', v_cohort is not null and exists (select 1 from public.module_week w where w.module_id = v_mod and w.cohort_id = v_cohort
                                                      and w.week_start_date = v_d and w.status <> 'Cancelled'),
      'holidays', (select coalesce(jsonb_agg(h.name), '[]') from public.holiday h where h.date between v_d and v_d + 6
                                  and (h.domain_id is null or h.domain_id = p_domain_id)));
  end loop;
  return v_out;
end;
$$;


-- -------------------------------------------------------------------------------------
-- Checklist: extra items for one class
-- -------------------------------------------------------------------------------------
alter table public.checklist_item add column added_manually boolean not null default false;

create or replace function public.add_checklist_item(p_class_id uuid, p_label text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare c public.class_session; w public.module_week; v uuid;
begin
  perform private.require_team();
  if coalesce(trim(p_label), '') = '' then raise exception 'Write what needs doing.' using errcode = '22023'; end if;
  select * into c from public.class_session where id = p_class_id;
  select * into w from public.module_week where id = c.module_week_id;
  insert into public.checklist_item (class_id, booking_id, label, due_at, added_manually)
  values (c.id, (select b.id from public.booking b where b.module_week_id = w.id and b.status = 'Active'), trim(p_label),
          w.first_class_at - make_interval(days => private.setting_int(w.id, 'checklist_due_days')), true)
  returning id into v;
  perform private.log_event('Team actions', 'Task added: ' || trim(p_label), 'checklist_item', v, null, null, null,
    w.domain_id, w.module_id, w.id, c.id);
  return v;
exception when unique_violation then
  raise exception 'This class already has that task.' using errcode = '23505';
end;
$$;

create or replace function public.remove_checklist_item(p_item_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare ci public.checklist_item; w public.module_week;
begin
  perform private.require_team();
  select * into ci from public.checklist_item where id = p_item_id;
  if not ci.added_manually then raise exception 'Only tasks added for this class can be removed.' using errcode = '22023'; end if;
  select mw.* into w from public.class_session c join public.module_week mw on mw.id = c.module_week_id where c.id = ci.class_id;
  delete from public.checklist_item where id = p_item_id;
  perform private.log_event('Team actions', 'Task removed: ' || ci.label, 'checklist_item', ci.id, null, null, null,
    w.domain_id, w.module_id, w.id, ci.class_id);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Start asking now (before the usual start date)
-- -------------------------------------------------------------------------------------
create or replace function public.start_asking_now(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare w public.module_week; v_probs jsonb; v_req uuid;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.id is null then raise exception 'Class week not found.' using errcode = '22023'; end if;
  if w.status in ('Cancelled', 'Completed') then raise exception 'This class week is finished or cancelled.' using errcode = '22023'; end if;
  if exists (select 1 from public.booking b where b.module_week_id = w.id and b.status = 'Active') then
    raise exception 'Someone is already confirmed for this class week.' using errcode = '22023';
  end if;
  if exists (select 1 from public.request r where r.module_week_id = w.id and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')) then
    raise exception 'Someone is already being asked for this class week.' using errcode = '22023';
  end if;
  if (select status from public.domain where id = w.domain_id) not in ('Test', 'Live') then
    raise exception 'Turn on testing or go live first. Draft domains send nothing.' using errcode = '22023';
  end if;
  v_probs := private.readiness_problems(w.id);
  if exists (select 1 from jsonb_array_elements(v_probs) p where (p ->> 'blocking')::boolean) then
    raise exception 'The setup check needs fixing first: %',
      (select string_agg(p ->> 'text', '; ') from jsonb_array_elements(v_probs) p where (p ->> 'blocking')::boolean) using errcode = '22023';
  end if;
  update public.module_week set paused = false, readiness_problems = v_probs, readiness_checked_at = private.mw_now(w.id),
         status = case when status in ('Planned', 'NotReady') then 'Ready' else status end
   where id = w.id;
  v_req := private.ask_next(w.id, private.mw_now(w.id));
  perform private.log_event('Team actions', 'Started asking now', 'module_week', w.id, null, null, null,
    w.domain_id, w.module_id, w.id);
  perform private.queue_deliver('start asking now');
  return jsonb_build_object('ok', v_req is not null, 'asked', private.next_name(w.id));
end;
$$;

-- -------------------------------------------------------------------------------------
-- Copy settings from another domain (when creating a domain)
-- -------------------------------------------------------------------------------------
create or replace function public.copy_domain_settings(p_from_domain_id uuid, p_to_domain_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare n_set int; n_types int; n_tpl int;
begin
  perform private.require_team();
  perform set_config('app.settings_batch', 'on', true);
  insert into public.setting (scope, domain_id, key, value)
  select 'Domain', p_to_domain_id, s.key, s.value from public.setting s where s.scope = 'Domain' and s.domain_id = p_from_domain_id
  on conflict (key, scope, coalesce(module_week_id, module_id, cohort_id, domain_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set value = excluded.value;
  get diagnostics n_set = row_count;
  perform set_config('app.settings_batch', 'off', true);
  perform private.check_setting_rules(p_to_domain_id);
  insert into public.class_type (domain_id, name, sort_order)
  select p_to_domain_id, t.name, t.sort_order from public.class_type t where t.domain_id = p_from_domain_id
  on conflict do nothing;
  get diagnostics n_types = row_count;
  insert into public.message_template (domain_id, template_id, subject, body)
  select p_to_domain_id, t.template_id, t.subject, t.body from public.message_template t where t.domain_id = p_from_domain_id
  on conflict (domain_id, template_id) do update set subject = excluded.subject, body = excluded.body;
  get diagnostics n_tpl = row_count;
  perform private.log_event('Setup changes', 'Settings copied from ' || (select name from public.domain where id = p_from_domain_id),
    'domain', p_to_domain_id, null, jsonb_build_object('settings', n_set, 'class_types', n_types, 'templates', n_tpl), null, p_to_domain_id);
  return jsonb_build_object('settings', n_set, 'class_types', n_types, 'templates', n_tpl);
end;
$$;

-- -------------------------------------------------------------------------------------
-- Saving many settings at once (one "Save changes" bar, presets)
-- -------------------------------------------------------------------------------------
-- Rules between settings, checked with the effective values of a layer.
create or replace function private.check_setting_rules(p_id uuid)
returns void language plpgsql stable security definer set search_path = ''
as $$
declare v_out int := private.setting_int(p_id, 'outreach_days'); v_read int := private.setting_int(p_id, 'readiness_days');
begin
  if v_read < v_out + 5 then
    raise exception 'The setup check must be at least 5 days before instructors are first asked. Asking starts % days before the class, so the setup check must be at least % days before.',
      v_out, v_out + 5 using errcode = '22023';
  end if;
  if private.time_window_minutes(private.setting_text(p_id, 'instructor_quiet_start'), private.setting_text(p_id, 'instructor_quiet_end')) > 720 then
    raise exception 'Quiet hours for instructors can be at most 12 hours long.' using errcode = '22023';
  end if;
  if private.time_window_minutes(private.setting_text(p_id, 'team_quiet_start'), private.setting_text(p_id, 'team_quiet_end')) > 840 then
    raise exception 'Quiet hours for the team can be at most 14 hours long.' using errcode = '22023';
  end if;
end;
$$;

-- p_values: {key: value, ...}; a null value resets that key to the level above.
create or replace function public.set_settings_at(p_scope text, p_scope_id uuid, p_values jsonb, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare k text; v jsonb;
begin
  perform private.require_team();
  perform set_config('app.settings_batch', 'on', true);
  for k, v in select * from jsonb_each(p_values) loop
    if v = 'null'::jsonb then
      perform public.reset_setting_at(p_scope, p_scope_id, k);
    else
      perform public.set_setting_at(p_scope, p_scope_id, k, v, p_reason);
    end if;
  end loop;
  perform set_config('app.settings_batch', 'off', true);
  perform private.check_setting_rules(case when p_scope = 'Global' then null else p_scope_id end);
end;
$$;


create or replace function private.validate_setting()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  d public.setting_definition;
  v jsonb := new.value;
  e jsonb;
  n int;
  v_out int;
  v_read int;
  v_dom uuid := coalesce(new.module_week_id, new.module_id, new.cohort_id, new.domain_id);
begin
  select * into d from public.setting_definition where key = new.key;
  if d.value_type = 'int' then
    if jsonb_typeof(v) <> 'number' or (v #>> '{}') !~ '^-?\d+$' then
      raise exception '"%" must be a whole number.', d.label using errcode = '22023';
    end if;
    n := (v #>> '{}')::int;
    if (d.min_value is not null and n < d.min_value) or (d.max_value is not null and n > d.max_value) then
      raise exception '"%" must be between % and %.', d.label, d.min_value, d.max_value using errcode = '22023';
    end if;
  elsif d.value_type = 'bool' then
    if jsonb_typeof(v) <> 'boolean' then
      raise exception '"%" must be on or off.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'enum' then
    if jsonb_typeof(v) <> 'string' or not (d.allowed @> jsonb_build_array(v)) then
      raise exception '"%" must be one of: %.', d.label, d.allowed using errcode = '22023';
    end if;
  elsif d.value_type = 'time' then
    if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^([01]\d|2[0-3]):[0-5]\d$' then
      raise exception '"%" must be a time like 09:00.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'int_list' then
    if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then
      raise exception '"%" needs at least one value.', d.label using errcode = '22023';
    end if;
    for e in select * from jsonb_array_elements(v) loop
      if jsonb_typeof(e) <> 'number' or (e #>> '{}')::numeric not between d.min_value and d.max_value then
        raise exception '"%": every value must be between % and %.', d.label, d.min_value, d.max_value using errcode = '22023';
      end if;
    end loop;
  elsif d.value_type = 'text_list' then
    if jsonb_typeof(v) <> 'array' then
      raise exception '"%" must be a list.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'json' then
    if jsonb_typeof(v) <> 'object' then
      raise exception '"%" must be an object.', d.label using errcode = '22023';
    end if;
    if d.allowed is not null then
      for e in select value from jsonb_each(v) loop
        if not (d.allowed @> jsonb_build_array(e)) then
          raise exception '"%": each value must be one of %.', d.label, d.allowed using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  -- Cross-field rules (evaluated with this new value in place). Saving many settings at once checks
  -- them after all values are in place instead (private.check_setting_rules).
  if current_setting('app.settings_batch', true) = 'on' then
    return new;
  end if;
  if new.key in ('outreach_days', 'readiness_days') then
    v_out := case when new.key = 'outreach_days' then (v #>> '{}')::int else private.setting_int(v_dom, 'outreach_days') end;
    v_read := case when new.key = 'readiness_days' then (v #>> '{}')::int else private.setting_int(v_dom, 'readiness_days') end;
    if v_read < v_out + 5 then
      raise exception 'The setup check must be at least 5 days before instructors are first asked. Asking starts % days before the class, so the setup check must be at least % days before.',
        v_out, v_out + 5 using errcode = '22023';
    end if;
  end if;
  if new.key in ('instructor_quiet_start', 'instructor_quiet_end') then
    if private.time_window_minutes(
         case when new.key = 'instructor_quiet_start' then v #>> '{}' else private.setting_text(v_dom, 'instructor_quiet_start') end,
         case when new.key = 'instructor_quiet_end' then v #>> '{}' else private.setting_text(v_dom, 'instructor_quiet_end') end) > 720 then
      raise exception 'Quiet hours for instructors can be at most 12 hours long.' using errcode = '22023';
    end if;
  end if;
  if new.key in ('team_quiet_start', 'team_quiet_end') then
    if private.time_window_minutes(
         case when new.key = 'team_quiet_start' then v #>> '{}' else private.setting_text(v_dom, 'team_quiet_start') end,
         case when new.key = 'team_quiet_end' then v #>> '{}' else private.setting_text(v_dom, 'team_quiet_end') end) > 840 then
      raise exception 'Quiet hours for the team can be at most 14 hours long.' using errcode = '22023';
    end if;
  end if;
  if new.key = 'instructor_channels' and (v #>> '{}') not in ('Both', 'DiscordOnly', 'EmailOnly') then
    raise exception 'Choose at least one channel.' using errcode = '22023';
  end if;
  return new;
end;
$$;


-- -------------------------------------------------------------------------------------
-- Home: setup checklist for a domain that is not ready yet
-- -------------------------------------------------------------------------------------
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
    jsonb_build_object('key', 'instructors', 'label', 'Set the instructor order of every module', 'link', '/setup/modules',
      'done', exists (select 1 from mods) and not exists (select 1 from mods m where not exists (select 1 from public.module_ranking k where k.module_id = m.id and k.cohort_id is null))),
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

-- Modules page: owners, operations team and instructor counts in one request.
create or replace function public.module_overview(p_domain_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_object_agg(m.id, jsonb_build_object(
    'owners', private.team_names(private.module_owner_ids(m.id)),
    'operations', private.team_names(private.ops_for_module(m.id)),
    'operations_is_default', not exists (select 1 from public.module_operations o where o.module_id = m.id and o.cohort_id is null),
    'active_instructors', (select count(*) from public.module_ranking k join public.instructor i on i.id = k.instructor_id
                            where k.module_id = m.id and k.cohort_id is null and i.status = 'Active' and not i.is_test),
    'needed', private.setting_int(m.id, 'min_active_instructors'),
    'class_times', (select count(*) from public.class_pattern_item p where p.module_id = m.id and p.cohort_id is null))), '{}')
    from public.module m where m.domain_id = p_domain_id
     and (private.is_team_user() or private.is_service());
$$;



-- -------------------------------------------------------------------------------------
-- Practice class: every stage on the practice clock, then everything is rolled back
-- -------------------------------------------------------------------------------------
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
    v_steps := v_steps || jsonb_build_object('step', 'Setup check passes', 'passed', v_status = 'Ready', 'detail', 'Class week is ' || v_status);

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

do $$
declare f text;
begin
  foreach f in array array['public.message_templates(uuid)', 'public.save_message_template(uuid, text, text, text)',
    'public.reset_message_template(uuid, text)', 'public.preview_message_template(uuid, text, text, text)',
    'public.send_template_test(uuid, text, text, text)', 'public.add_checklist_item(uuid, text)',
    'public.remove_checklist_item(uuid)', 'public.start_asking_now(uuid)', 'public.copy_domain_settings(uuid, uuid)',
    'public.set_settings_at(text, uuid, jsonb, text)', 'public.domain_setup_status(uuid)', 'public.module_overview(uuid)',
    'public.run_practice_class(uuid)'] loop
    execute format('revoke execute on function %s from anon, public', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

