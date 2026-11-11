-- Demo fixes, part 3 (docs/DEMO_SCRIPT.md, decision 269): the system never shares materials.
-- The answer pages, every instructor message, the template defaults and their previews no longer show
-- materials; the templates say how to get help before class instead ({help}), and the setup check no
-- longer asks for materials. The module_resource table stays, unused. Instructors who need materials ask
-- with Need help, "Class materials or content", which goes to the module owner.

create or replace function private.materials_line(p_mw uuid)
returns text language sql stable set search_path = ''
as $$ select ''::text; $$;

create or replace function private.page_materials(p_mw uuid)
returns text language sql stable set search_path = ''
as $$ select ''::text; $$;

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
    v := v || jsonb_build_object('code', 'module_inactive', 'text', 'The module is not active', 'blocking', true);
  end if;
  if cardinality(private.module_owner_ids(m.id)) = 0 then
    v := v || jsonb_build_object('code', 'no_owner', 'text', 'No owner set for the module', 'blocking', true);
  end if;
  if not exists (select 1 from private.build_line(p_mw) l where l.reason is null) then
    v := v || jsonb_build_object('code', 'no_instructor',
      'text', 'Nobody in line is active, verified, available and free at that time', 'blocking', true);
  end if;
  return v;
end;
$$;

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
      'required', jsonb_build_array('module', 'classes')));
$$;

create or replace function private.template_variables()
returns text[] language sql immutable set search_path = ''
as $$ select array['first_name', 'name', 'module', 'domain', 'classes', 'first_class', 'weekday', 'deadline', 'reply_by',
                   'help', 'contact', 'days', 'what', 'helper', 'by', 'text', 'from']; $$;

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
             'first_class', private.fmt_local(w.first_class_at, private.week_region(w.id)), 'weekday', to_char(w.first_class_at at time zone private.region_tz(private.week_region(w.id)), 'FMDay'),
             'contact', private.team_names(private.owners_or_leads(m.id)),
             'help', E'\n\nNeed anything before class? Press Need help below or reply to this message, and '
               || coalesce(nullif(private.team_names(private.owners_or_leads(m.id)), ''), 'the team') || ' will help you.')
      into v_vars
      from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id where w.id = v_mw;
  else
    v_vars := jsonb_build_object('module', 'Concurrency', 'domain', coalesce((select name from public.domain where id = p_domain_id), 'Backend'),
      'classes', E'• Live class: Sun, Jan 31, 9:00 AM to 1:00 PM PST\n• Assignment review: Thu, Feb 4, 6:00 PM to 8:00 PM PST',
      'first_class', 'Sun Jan 31, 9:00 AM PST', 'weekday', 'Sunday', 'contact', 'Your module owner',
      'help', E'\n\nNeed anything before class? Press Need help below or reply to this message, and your module owner will help you.');
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
