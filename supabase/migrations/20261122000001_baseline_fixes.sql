-- Release 3, M0: two fixes on the answer pages (docs/PLAN_RELEASE_3.md, decisions 269 and 284).
--
-- 1. The Need help page no longer offers materials. Decision 269 removed materials from every message, but this
--    page was still built by the first version of the function (20261110000004, renamed in 20261110000008 and never
--    rewritten), so it said "Here are your materials" and "No materials have been added yet.". It now opens the
--    help form at once, like the messages' help line.
-- 2. "Please answer by" is shown in the class's own time zone (India time for India classes), with the same
--    formatter the messages use (private.fmt_local), instead of always US Pacific.
--
-- Everything else in the page is unchanged. Rollback: supabase/rollback/20261122000001_baseline_fixes.sql.

create or replace function public.response_page_text(p_token text)
returns text language plpgsql security definer set search_path = ''
as $$
declare
  lnk public.response_link;
  r public.request;
  w public.module_week;
  v_name text;
  v_who text;
  v_open boolean;
  v_booking_active boolean;
  v_details text := '';
begin
  perform private.require_team();
  select * into lnk from public.response_link where token = p_token;
  if lnk.token is null then
    return private.page_message('Link not valid', 'This link isn''t valid. If you need anything, reply in your Discord channel or by email.');
  end if;
  update public.response_link set opened_at = coalesce(opened_at, now()) where token = p_token;
  select * into r from public.request where id = lnk.request_id;
  select * into w from public.module_week where id = r.module_week_id;
  v_name := coalesce((select i.full_name from public.instructor i where i.id = r.instructor_id),
                     (select t.name from public.team_member t where t.id = r.team_member_id));
  v_who := '<p class="muted">Confirming as <strong>' || private.html_escape(v_name) || '</strong></p>';
  if w.id is not null then v_details := private.page_details(w.id); end if;
  v_open := r.status in ('Sent', 'Reminded', 'Queued');
  v_booking_active := exists (select 1 from public.booking b where b.status = 'Active'
                               and (b.id = r.booking_id or b.request_id = r.id));

  if lnk.used_at is not null then
    return private.page_message('Already recorded', 'Already recorded — thank you!', v_details);
  end if;
  if w.status in ('Cancelled') then
    return private.page_message('No longer needed', 'This class is no longer scheduled, so nothing is needed from you.', v_details);
  end if;

  if lnk.answer in ('NeedHelp', 'OwnerNeedHelp') then
    return private.page('Need help',
      '<h1>Need help?</h1>' || v_details
      || case when lnk.answer = 'NeedHelp' then
           '<p>Tell us what you need, and we''ll help you before class.</p><div>'
         else '<details open><summary>Tell ops what you need</summary>' end
      || private.page_form(p_token, 'Send help request', '', private.help_form_fields())
      || case when lnk.answer = 'NeedHelp' then '</div>' else '</details>' end || v_who);
  end if;

  if lnk.answer = 'CantMakeIt' then
    if not v_booking_active then
      return private.page_message('Nothing to change', 'This booking is no longer active, so nothing is needed.', v_details);
    end if;
    return private.page('Can''t make it',
      '<h1>Can''t make it?</h1>' || v_details
      || '<p>This will release your class and we''ll find someone else. Are you sure?</p>'
      || private.page_form(p_token, 'Yes, release my class', 'danger')
      || '<p class="muted">Need something instead? Use the Need help button in our message.</p>' || v_who);
  end if;

  if not v_open then
    if lnk.answer = 'Yes' and r.kind = 'Outreach' and r.status <> 'Accepted' then
      return private.page('Request closed',
        '<h1>This request has closed</h1>' || v_details
        || '<p>We''ve already moved on for this class. If you can still teach, tap below and we''ll let the team know — they''ll be in touch if the slot is still free.</p>'
        || private.page_form(p_token, 'Tell the team I can still teach', 'secondary') || v_who);
    end if;
    return private.page_message(case when r.status = 'Accepted' then 'Already recorded' else 'Request closed' end,
      case when r.status = 'Accepted' then 'Already recorded — thank you!' else 'This request has closed, so nothing is needed from you. Thank you!' end,
      v_details);
  end if;

  return private.page('Please confirm',
    '<h1>' || case lnk.answer
        when 'Yes' then 'Confirm you can teach'
        when 'No' then 'Confirm you can''t teach'
        when 'AllSet' then 'All set?'
        when 'StillWorks' then 'Does the new time work?'
        when 'DoesntWork' then 'The new time doesn''t work?'
        when 'GotIt' then 'Confirm you got our test message'
        when 'OwnerAllGood' then 'All good?'
        else 'Please confirm' end || '</h1>'
    || v_details
    || case when lnk.answer = 'Yes' and r.deadline_at is not null then
         '<p class="muted">Please answer by ' || private.html_escape(private.fmt_local(r.deadline_at, private.week_region(w.id))) || '.</p>'
       else '' end
    || private.page_form(p_token, private.answer_label(lnk.answer), case when lnk.answer in ('No', 'DoesntWork') then 'danger' else '' end)
    || v_who);
end;
$$;

revoke execute on function public.response_page_text(text) from authenticated, anon, public;
grant execute on function public.response_page_text(text) to service_role;
