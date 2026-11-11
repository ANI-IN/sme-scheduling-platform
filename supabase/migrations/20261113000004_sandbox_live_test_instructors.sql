-- Demo readiness (docs/DEMO_SCRIPT.md, decision 267): in the Sandbox a Live domain may ask test instructors.
-- Before, a Live domain never asked test instructors, and the Sandbox never contacts anyone else, so a Live
-- domain in the Sandbox could not ask anybody. Production is unchanged: Live never asks test instructors there,
-- and the send guard still blocks any message to a test instructor in Production and to a real instructor in
-- the Sandbox.
-- Also two things the demo showed: "Start asking now" named the person after the one it asked, and every
-- instructor message greeted twice ("Hi Maya 👋 Hi Maya,").

create or replace function private.eligibility(p_instructor uuid, p_mw uuid)
returns text language plpgsql stable security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_domain uuid;
  v_status text;
  v_reason text;
begin
  select * into i from public.instructor where id = p_instructor;
  select w.domain_id, d.status into v_domain, v_status
    from public.module_week w join public.domain d on d.id = w.domain_id where w.id = p_mw;
  if i.id is null then return 'Unknown instructor'; end if;
  if i.status = 'Inactive' then return 'Inactive'; end if;
  if i.status = 'Archived' then return 'Archived'; end if;
  if v_status = 'Live' and i.is_test
     and (select c.environment from public.app_config c where c.id = 1) <> 'Sandbox' then return 'Test instructor (not allowed in Live domains)'; end if;
  if v_status = 'Live' and i.verified_at is null then return 'Not verified'; end if;
  if i.discord_user_id is null and i.email_bounced_at is not null then return 'No working contact details'; end if;

  select 'Unavailable ' || to_char(u.from_date, 'Mon FMDD') || ' to ' || to_char(u.to_date, 'Mon FMDD')
    into v_reason
    from public.instructor_unavailability u
   where u.instructor_id = p_instructor
     and exists (select 1 from public.class_session c
                  where c.module_week_id = p_mw and c.status <> 'Cancelled'
                    and (c.starts_at at time zone private.region_tz(c.region))::date between u.from_date and u.to_date)
   order by u.from_date limit 1;
  if v_reason is not null then return v_reason; end if;

  -- Clashes are checked on the real time (UTC), across every cohort, domain and region.
  return private.week_clash(p_instructor, p_mw);
end;
$$;

create or replace function private.step_health(p_domain uuid, p_now timestamptz)
returns int language plpgsql security definer set search_path = ''
as $$
declare
  m record;
  i record;
  v_min int;
  v_weeks int := private.setting_int(p_domain, 'schedule_low_weeks');
  v_last date;
  v_cnt int;
  v_live boolean := (select d.status = 'Live' from public.domain d where d.id = p_domain);
  n int := 0;
begin
  for m in select * from public.module where domain_id = p_domain and status = 'Active' loop
    v_min := private.setting_int(m.id, 'min_active_instructors');
    select count(*) into v_cnt from public.module_ranking k join public.instructor ins on ins.id = k.instructor_id
     where k.module_id = m.id and ins.status = 'Active' and (not v_live or not ins.is_test or (select c.environment from public.app_config c where c.id = 1) = 'Sandbox');
    if v_cnt < v_min then
      perform private.raise_attention(p_domain, 'ThinBench', 'Normal',
        'Thin bench: ' || m.name || ' has ' || v_cnt || ' active instructor' || case when v_cnt = 1 then '' else 's' end || ' (minimum ' || v_min || ')',
        'Add instructors to the ranking.', 'thinbench:' || m.id, private.owners_or_leads(m.id), p_now,
        jsonb_build_object('module_id', m.id));
      n := n + 1;
    else
      perform private.resolve_attention('thinbench:' || m.id, 'Enough active instructors');
    end if;
  end loop;

  for i in select distinct ins.id, ins.full_name, ins.verified_at, min(k.created_at) over (partition by ins.id) as ranked_at
             from public.module_ranking k join public.module mo on mo.id = k.module_id
             join public.instructor ins on ins.id = k.instructor_id
            where mo.domain_id = p_domain and ins.status = 'Active' loop
    if i.verified_at is null and i.ranked_at + interval '2 days' <= greatest(p_now, now()) then
      perform private.raise_attention(p_domain, 'UnverifiedInRanking', 'Normal',
        'Not verified: ' || i.full_name, 'They are in a ranking but haven''t confirmed the test message. Send a test message from Instructors.',
        'unverified:' || p_domain || ':' || i.id, private.domain_role_ids(p_domain, 'Ops'), p_now,
        jsonb_build_object('instructor_id', i.id));
    elsif i.verified_at is not null then
      perform private.resolve_attention('unverified:' || p_domain || ':' || i.id, 'Verified');
    end if;
  end loop;

  select max(mw.week_start_date) into v_last from public.module_week mw where mw.domain_id = p_domain and mw.status <> 'Cancelled';
  if v_last is null or v_last < (p_now at time zone 'America/Los_Angeles')::date + v_weeks * 7 then
    perform private.raise_attention(p_domain, 'ScheduleLow', 'Normal',
      'Schedule running low: classes planned only until ' || coalesce(to_char(v_last, 'Mon FMDD, YYYY'), 'nothing planned'),
      'Plan at least ' || v_weeks || ' weeks ahead (Schedule → Plan classes).', 'schedulelow:' || p_domain,
      private.uniq(private.domain_role_ids(p_domain, 'Ops') || private.domain_role_ids(p_domain, 'Lead')), p_now);
  else
    perform private.resolve_attention('schedulelow:' || p_domain, 'Enough weeks planned');
  end if;
  return n;
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
  -- The message adds its own greeting ("Hi Maya 👋" on Discord, "Hi Maya," by email), so a greeting the
  -- template starts with is dropped instead of showing twice.
  v_body := regexp_replace(v_body, '^\s*(hi|hello|dear)\s[^\n]{0,60},[ \t]*\n+', '', 'i');
  return jsonb_build_object('subject', private.plain_message_text(v_subject), 'body', private.plain_message_text(v_body),
    'first_name', private.first_name(v_name), 'name', v_name);
end;
$$;

create or replace function public.start_asking_now(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_asked text;
  w public.module_week; v_probs jsonb; v_req uuid;
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
  -- Who is asked now (after asking, the line moves on to the next person).
  v_asked := private.next_name(w.id);
  v_req := private.ask_next(w.id, private.mw_now(w.id));
  perform private.log_event('Team actions', 'Started asking now', 'module_week', w.id, null, null, null,
    w.domain_id, w.module_id, w.id);
  perform private.queue_deliver('start asking now');
  return jsonb_build_object('ok', v_req is not null, 'asked', v_asked);
end;
$$;
