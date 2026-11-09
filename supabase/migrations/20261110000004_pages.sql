-- =====================================================================================
-- Milestone 2c — Confirm pages and help form (PRD §11.2, §10.3), rendered by the database and
-- served unchanged by n8n WF2. GET shows a page and records nothing; only the POST records.
-- =====================================================================================

create or replace function private.page(p_title text, p_body text)
returns text language sql immutable set search_path = ''
as $$
  select '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    || '<meta name="viewport" content="width=device-width,initial-scale=1">'
    || '<meta name="robots" content="noindex,nofollow">'
    || '<title>' || private.html_escape(p_title) || ' · SME Scheduling</title>'
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
    || '</style></head><body><div class="card">' || p_body
    || '<p class="muted" style="margin-top:24px">SME Scheduling</p></div></body></html>';
$$;

create or replace function private.page_message(p_title text, p_text text, p_extra text default '')
returns text language sql immutable set search_path = ''
as $$ select private.page(p_title, '<h1>' || private.html_escape(p_title) || '</h1><p>' || private.html_escape(p_text) || '</p>' || coalesce(p_extra, '')); $$;

create or replace function private.page_details(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select '<p><strong>' || private.html_escape(m.name) || '</strong>'
      || coalesce(' · ' || private.html_escape(nullif(w.cohort, '')), '') || ' · ' || private.html_escape(d.name) || '</p><ul>'
      || coalesce((select string_agg('<li>' || private.html_escape(c.class_type) || ': ' || private.html_escape(private.fmt_pt_range(c.starts_at, c.ends_at)) || '</li>', '' order by c.starts_at)
                     from public.class_session c where c.module_week_id = w.id and c.status <> 'Cancelled'), '')
      || '</ul>'
    from public.module_week w join public.module m on m.id = w.module_id join public.domain d on d.id = w.domain_id
   where w.id = p_mw;
$$;

create or replace function private.page_materials(p_mw uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce('<ul>' || string_agg('<li><a href="' || private.html_escape(r.url) || '">' || private.html_escape(r.title) || '</a></li>', '' order by r.sort_order, r.title) || '</ul>', '')
    from public.module_week w join public.module_resource r on r.module_id = w.module_id
   where w.id = p_mw;
$$;

create or replace function private.page_form(p_token text, p_button text, p_class text default '', p_fields text default '')
returns text language sql stable security definer set search_path = ''
as $$
  select '<form method="post" action="' || private.html_escape(coalesce((select c.response_base_url from public.app_config c where c.id = 1), '')) || '">'
      || '<input type="hidden" name="t" value="' || private.html_escape(p_token) || '">'
      || coalesce(p_fields, '')
      || '<button type="submit" class="' || p_class || '">' || private.html_escape(p_button) || '</button></form>';
$$;

create or replace function private.help_form_fields()
returns text language sql immutable set search_path = ''
as $$
  select '<fieldset><legend>What do you need help with?</legend>'
    || (select string_agg('<label><input type="checkbox" name="cat_' || c || '" value="1"> ' || private.html_escape(private.help_category_label(c)) || '</label>', '' order by o)
          from unnest(array['materials', 'zoom', 'platform', 'assignment', 'students', 'schedule', 'payment', 'other']) with ordinality as x(c, o))
    || '<p class="muted">To cancel, use the "Can''t make it" button instead.</p></fieldset>'
    || '<label for="details"><strong>Details</strong> (optional)</label><textarea id="details" name="details" maxlength="1000"></textarea>'
    || '<fieldset><legend>How soon do you need this?</legend>'
    || '<label><input type="radio" name="urgency" value="NoRush" checked> Before the class, no rush</label>'
    || '<label><input type="radio" name="urgency" value="Within24h"> Within 24 hours</label>'
    || '<label><input type="radio" name="urgency" value="Urgent"> Urgent</label></fieldset>'
    || '<fieldset><legend>How should we reply?</legend>'
    || '<label><input type="radio" name="reply_channel" value="Discord"> Discord channel</label>'
    || '<label><input type="radio" name="reply_channel" value="Email"> Email</label>'
    || '<label><input type="radio" name="reply_channel" value="Either" checked> Either</label></fieldset>';
$$;

-- GET: show the confirm page (records nothing except that the link was opened).
create or replace function public.response_page(p_token text)
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
           '<p><strong>Here are your materials' || coalesce(' for ' || private.html_escape((select m.name from public.module m where m.id = w.module_id)), '') || ':</strong></p>'
           || coalesce(nullif(private.page_materials(w.id), ''), '<p class="muted">No materials have been added yet.</p>')
           || '<details><summary>I still need help</summary>'
         else '<details open><summary>Tell ops what you need</summary>' end
      || private.page_form(p_token, 'Send help request', '', private.help_form_fields()) || '</details>' || v_who);
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
    || case when lnk.answer = 'Yes' and r.deadline_at is not null then '<p class="muted">Please answer by ' || private.html_escape(private.fmt_pt(r.deadline_at)) || '.</p>' else '' end
    || private.page_form(p_token, private.answer_label(lnk.answer), case when lnk.answer in ('No', 'DoesntWork') then 'danger' else '' end)
    || v_who);
end;
$$;

-- POST: record the answer (or help request) and show the result page.
create or replace function public.submit_response_page(p_token text, p_form jsonb default '{}')
returns text language plpgsql security definer set search_path = ''
as $$
declare
  lnk public.response_link;
  r public.request;
  v_res jsonb;
  v_cats text[];
  v_extra text := '';
  v_title text;
begin
  perform private.require_team();
  select * into lnk from public.response_link where token = p_token;
  if lnk.token is null then
    return private.page_message('Link not valid', 'This link isn''t valid.');
  end if;
  select * into r from public.request where id = lnk.request_id;
  if lnk.answer in ('NeedHelp', 'OwnerNeedHelp') then
    select coalesce(array_agg(substr(k, 5)), '{}') into v_cats
      from jsonb_object_keys(coalesce(p_form, '{}')) k
     where k like 'cat\_%' and coalesce(p_form ->> k, '') <> '';
    v_res := public.submit_help_request(p_token, v_cats, nullif(trim(coalesce(p_form ->> 'details', '')), ''),
      coalesce(p_form ->> 'urgency', 'NoRush'), coalesce(p_form ->> 'reply_channel', 'Either'));
    return private.page_message(case when v_res ->> 'result' = 'help_created' then 'Thanks!' else 'Sorry' end, v_res ->> 'message');
  end if;

  v_res := public.record_response(p_token, null);
  v_title := case v_res ->> 'result'
    when 'confirmed' then 'You''re confirmed 🎉'
    when 'declined' then 'Thanks for letting us know'
    when 'all_set' then 'Great — thanks!'
    when 'cancelled' then 'Thanks for letting us know'
    when 'released' then 'Thanks for letting us know'
    when 'still_works' then 'Thanks!'
    when 'verified' then 'Verified ✓'
    when 'owner_ok' then 'Thanks!'
    when 'already_recorded' then 'Already recorded'
    when 'closed' then 'Request closed'
    when 'not_booked' then 'Thank you!'
    else 'Sorry' end;
  if v_res ->> 'result' = 'confirmed' and r.module_week_id is not null then
    v_extra := private.page_details(r.module_week_id)
      || coalesce(nullif('<p><strong>Materials</strong></p>' || private.page_materials(r.module_week_id), '<p><strong>Materials</strong></p>'), '');
  elsif v_res ->> 'result' = 'all_set' then
    v_extra := '<p>Need anything else?</p><a class="btn secondary" href="' || private.html_escape(private.link_for(r.id, 'NeedHelp')) || '">🙋 Need help</a>';
  end if;
  return private.page_message(v_title, v_res ->> 'message', v_extra);
end;
$$;

grant execute on function public.response_page(text) to service_role;
grant execute on function public.submit_response_page(text, jsonb) to service_role;
