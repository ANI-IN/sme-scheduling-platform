-- Owner's night batch of 24 November 2026 (decision 336), found reading every message as an instructor gets it:
-- with both time zones, "Can you teach X? (Sun, Jan 31 · 9:00 AM PST (Sun, Jan 31 · 10:30 PM IST))" had brackets inside
-- brackets, in the subject and in three reminders. The subject now shows the class's own time only; elsewhere both
-- times read "9:00 AM PST / 10:30 PM IST", with the other date only when it differs. Class lines keep their brackets.
/** "Sun, Jan 24 · 9:00 AM PST / 10:30 PM IST": the class's own time zone, then the other one, with its date only when
    it differs ("Sun, Jan 24 · 6:00 PM PST / Mon, Jan 25 · 7:30 AM IST"). No brackets, so it reads well inside them. */
create or replace function private.fmt_local_both(p_ts timestamptz, p_region text)
returns text language sql immutable set search_path = ''
as $$
  select private.fmt_local(p_ts, p_region) || ' / ' ||
         case when (p_ts at time zone private.region_tz(p_region))::date
                   = (p_ts at time zone private.region_tz(case when p_region = 'India' then 'US' else 'India' end))::date
              then to_char(p_ts at time zone private.region_tz(case when p_region = 'India' then 'US' else 'India' end), 'FMHH12:MI AM')
                   || ' ' || private.tz_abbrev(p_ts, case when p_region = 'India' then 'US' else 'India' end)
              else private.fmt_local(p_ts, case when p_region = 'India' then 'US' else 'India' end) end;
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
        'module', m.name, 'domain', d.name, 'classes', private.class_lines_both(p_mw),
        'first_class', private.fmt_local_both(v_first, private.week_region(p_mw)),
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
  -- The welcome message has a domain but no class week.
  if p_mw is null and nullif(p_extra ->> 'domain_id', '') is not null then
    v_dom := (p_extra ->> 'domain_id')::uuid;
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
  if not v_vars ? 'module' then v_vars := v_vars || jsonb_build_object('module', 'SME Scheduling',
    'domain', coalesce((select d.name from public.domain d where d.id = v_dom), ''), 'classes', '',
    'first_class', '', 'weekday', '', 'contact', '', 'help', '', 'materials', ''); end if;
  if v_dom is not null then
    select * into v_custom from public.message_template where domain_id = v_dom and template_id = p_template;
  end if;
  -- Decision 336: the subject is short, so its first class time is in the class's own time zone only.
  v_subject := private.fill_template(coalesce(v_custom.subject, v_def ->> 'subject'),
    v_vars || case when v_first is not null
                then jsonb_build_object('first_class', private.fmt_local(v_first, private.week_region(p_mw))) else '{}'::jsonb end);
  v_body := private.fill_template(coalesce(v_custom.body, v_def ->> 'body'), v_vars);
  -- The message adds its own greeting ("Hi Maya 👋" on Discord, "Hi Maya," by email), so a greeting the
  -- template starts with is dropped instead of showing twice.
  v_body := regexp_replace(v_body, '^\s*(hi|hello|dear)\s[^\n]{0,60},[ \t]*\n+', '', 'i');
  return jsonb_build_object('subject', private.plain_message_text(v_subject), 'body', private.plain_message_text(v_body),
    'first_name', private.first_name(v_name), 'name', v_name);
end;
$$;
