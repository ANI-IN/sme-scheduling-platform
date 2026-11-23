-- Owner's night batch of 24 November 2026 (decision 337): Contact instructor. Someone on the team writes to one
-- instructor from their record; it goes to the instructor's own channel and by email (the beta rules apply as for
-- every message), with the template "Message from the team" (M23), and Activity history keeps who wrote what.
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
      'required', jsonb_build_array('module', 'classes')),
    'M17', jsonb_build_object('name', 'Classes moved for a break', 'subject', 'Your classes moved: do they still work?',
      'body', E'{text}

{classes}

Do these still work? Answer for each class week with the buttons.{reply_by}',
      'required', jsonb_build_array('classes')),
    'M18', jsonb_build_object('name', 'Proposed time received', 'subject', '{module}: we got your proposed time',
      'body', 'Thanks for proposing another time for {module}. The team checks it with the cohort and replies to you soon. Until then, nothing changes.',
      'required', jsonb_build_array('module')),
    'M19', jsonb_build_object('name', 'Proposed time accepted', 'subject', '{module}: your proposed time is accepted',
      'body', E'Good news: {module} moved to the time you proposed, and you stay confirmed.\n\n{classes}{help}',
      'required', jsonb_build_array('module', 'classes')),
    'M20', jsonb_build_object('name', 'Proposed time not possible', 'subject', '{module}: we kept the original time',
      'body', E'Thanks for proposing another time for {module}. We could not move the class, so the time stays:\n\n{classes}{text}\n\nPlease answer with the buttons below.{reply_by}',
      'required', jsonb_build_array('module', 'classes')),
    'M22', jsonb_build_object('name', 'Welcome', 'subject', 'Welcome to SME Scheduling',
      'body', E'You are set up to receive class requests from SME Scheduling.\n\nWhen we ask you to teach, answer with the buttons in the message.',
      'required', '[]'::jsonb),
    'M23', jsonb_build_object('name', 'Message from the team', 'subject', 'A message from {from}',
      'body', E'{text}

From {from}', 'required', jsonb_build_array('text')));
$$;

create or replace function public.contact_instructor(p_instructor_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  i public.instructor;
  v_from text := coalesce((select t.name from public.team_member t where t.id = private.current_team_member_id()), 'SME Scheduling');
  v_n int;
begin
  perform private.require_team();
  if coalesce(trim(p_text), '') = '' then raise exception 'Write a message first.' using errcode = '22023'; end if;
  if length(p_text) > 2000 then raise exception 'Keep the message under 2,000 characters.' using errcode = '22023'; end if;
  select * into i from public.instructor where id = p_instructor_id;
  if i.id is null then raise exception 'Instructor not found.' using errcode = '22023'; end if;
  if i.status = 'Archived' then raise exception '% is archived, so nothing is sent to them.', i.full_name using errcode = '22023'; end if;
  v_n := private.queue_instructor_message('M23', i.id, null, null, now(), '[]',
    jsonb_build_object('text', trim(p_text), 'from', v_from), false, 'contact:' || gen_random_uuid());
  perform private.log_event('Team actions', 'Message sent to ' || i.full_name, 'instructor', i.id, null,
    jsonb_build_object('text', trim(p_text), 'messages', v_n), null, null, null, null, null, i.id);
  perform private.queue_deliver('contact');
  return jsonb_build_object('ok', true, 'messages', v_n);
end;
$$;
revoke execute on function public.contact_instructor(uuid, text) from public, anon;
grant execute on function public.contact_instructor(uuid, text) to authenticated, service_role;
