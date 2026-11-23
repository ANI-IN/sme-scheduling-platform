-- Release 3: findings from the live run on Production (migration 20261123000029_live_findings.sql).
begin;
\ir ../helpers/helpers.psql
select plan(28);

-- =============================================================== 1. no dashes in the words the database writes
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'private') and p.proname <> 'plain_message_text'
              and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ '[—–]'),
  null, '1. no function writes a dash (only the one that removes them has one)');

select tests.scenario('LF', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');

-- =============================================================== 4a. the answer pages do not repeat their heading
select public.submit_response_page(tests.token(:'mw', :'i1', 'Yes'), '{}') as yes_page \gset
select ok(:'yes_page' like '%<h1>You&#39;re confirmed 🎉</h1><p>Thank you! We&#39;ve sent the details to you.</p>%',
  '2. the confirmed page starts with new words under its heading');
select ok(public.submit_response_page(tests.token(:'mw', :'i1', 'Yes'), '{}')
            like '%<h1>Already recorded</h1><p>We already have your answer. Thank you!</p>%',
  '3. so does the page for a second tap');

-- =============================================================== 4b. every box and choice has its own label
select public.response_page(tests.token(:'mw', :'i1', 'NeedHelp')) as help_page \gset
select ok(:'help_page' like '%<input type="checkbox" id="cat_materials" name="cat_materials" value="1"> <label for="cat_materials" style="display:inline">%'
          and :'help_page' like '%<label for="details" style="font-weight:600">Details (optional)</label><textarea id="details"%'
          and :'help_page' like '%<input type="radio" id="urgency_NoRush" name="urgency" value="NoRush" checked> <label for="urgency_NoRush"%'
          and :'help_page' like '%<input type="radio" id="reply_Either" name="reply_channel" value="Either" checked> <label for="reply_Either"%',
  '4. the Need help page labels each checkbox, choice and the details box by its words');
select ok(:'help_page' not like '%<label><input%', '5. no control sits inside its label any more');

-- =============================================================== 1 and 4a. a help request, then the instructor is released
select tests.at('2027-01-21 18:00+00');
select public.submit_help_request(tests.token(:'mw', :'i1', 'NeedHelp'), array['materials'], 'Slides please', 'NoRush', 'Either') as h \gset
select (:'h'::jsonb ->> 'help_request_id') as hid \gset
select ok(:'h'::jsonb ->> 'message' like 'Concurrency LF Owner will reply by %', '6. the help page names who replies, without a second "Thanks!"');
select is((select title from public.attention_item where dedupe_key = 'help:' || :'hid'),
  'Need help from LF Instr1: ' || private.mw_label(:'mw'), '7. the task title has a colon, not a dash');
-- As on Production: the team took the task.
update public.help_request set status = 'InProgress' where id = :'hid';
update public.attention_item set status = 'Acknowledged' where dedupe_key = 'help:' || :'hid';
select ok((select count(*) from public.message where help_request_id = :'hid' and template_id = 'M13' and status = 'Pending') > 0,
  '8. the help receipt is waiting to go');

-- =============================================================== 2 and 3. Can't make it
select is(tests.click(:'mw', :'i1', 'CantMakeIt'), 'cancelled', '9. the instructor releases the class');
select is((select status || ': ' || resolution_note from public.help_request where id = :'hid'),
  'Closed: Closed: the instructor no longer teaches this class week', '10. their help request closes with a note');
select is((select status || ': ' || done_note from public.attention_item where dedupe_key = 'help:' || :'hid'),
  'Done: Closed: the instructor no longer teaches this class week', '11. and its task is done');
select ok(exists (select 1 from public.history_event where entity_id = :'hid' and action = 'Help request from LF Instr1 closed'
                   and note = 'Closed: the instructor no longer teaches this class week'),
  '12. in Activity history');
select is((select string_agg(distinct status || ': ' || last_error, ', ') from public.message
            where help_request_id = :'hid' and template_id = 'M13'),
  'Cancelled: Not sent: the instructor no longer teaches this class week', '13. the help receipt that had not gone out is withdrawn');
select ok((select count(*) from public.message where module_week_id = :'mw' and instructor_id = :'i1' and template_id = 'M10'
             and status = 'Pending') > 0, '14. the release note still goes');
select ok(not exists (select 1 from public.module_week w join public.help_request h on h.module_week_id = w.id
                       where w.id = :'mw' and h.status in ('Open', 'InProgress', 'WaitingOnInstructor')),
  '15. the class week no longer shows "Help request open"');

-- =============================================================== 2 and 3. the class week is cancelled
select is(tests.click(:'mw', :'i2', 'Yes'), 'confirmed', '16. the next instructor says yes');
select public.submit_help_request(tests.token(:'mw', :'i2', 'NeedHelp'), array['zoom'], 'Zoom link', 'NoRush', 'Either') ->> 'help_request_id' as hid2 \gset
insert into public.message (domain_id, audience, template_id, channel, status, not_before, instructor_id, module_week_id, subject, body_text)
values (:'dom', 'Instructor', 'M20', 'Discord', 'Scheduled', '2027-01-22 03:00+00', :'i2', :'mw', 'Your proposed time', 'The time stays.')
returning id as m20 \gset
insert into public.message (domain_id, audience, template_id, channel, status, module_week_id, subject, body_text)
values (:'dom', 'Team', 'T5', 'Discord', 'Pending', :'mw', 'At risk', 'A team message about the class week')
returning id as t5 \gset
select public.cancel_module_week(:'mw', 'Room closed');
select is((select status || ': ' || last_error from public.message where id = :'m20'),
  'Cancelled: Not sent: the class week was cancelled', '17. a waiting proposal decision for the cancelled week is withdrawn');
select ok((select count(*) from public.message where module_week_id = :'mw' and instructor_id = :'i2' and template_id = 'M11'
             and status = 'Pending') > 0, '18. the class cancelled notice still goes');
select is((select status from public.message where id = :'t5'), 'Pending', '19. team messages are not touched');
select is((select string_agg(distinct status, ',') from public.message where module_week_id = :'mw' and instructor_id = :'i2'
            and status in ('Scheduled', 'Pending') and template_id not in ('M11', 'M12')), null,
  '20. nothing else waits to go to the instructor about the cancelled week');
select is((select status || ': ' || resolution_note from public.help_request where id = :'hid2'),
  'Closed: Closed: the class week was cancelled', '21. the help request closes with a note');
select is((select status || ': ' || done_note from public.attention_item where dedupe_key = 'help:' || :'hid2'),
  'Done: Closed: the class week was cancelled', '22. and its task is done');
select ok(exists (select 1 from public.history_event where entity_id = :'hid2' and action = 'Help request from LF Instr2 closed'),
  '23. in Activity history');
select ok(exists (select 1 from public.history_event where module_week_id = :'mw' and note = 'Not sent: the class week was cancelled'),
  '24. the withdrawn messages are in Activity history too');

-- =============================================================== 4b and 4c. Propose another time
select tests.scenario('LP', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'mw') as pw, (:'j'::jsonb ->> 'i1') as p1 \gset
insert into public.request (module_week_id, instructor_id, kind, status, time_version, sent_at, deadline_at)
values (:'pw', :'p1', 'Outreach', 'Sent', (select time_version from public.module_week where id = :'pw'), now(), now() + interval '1 day')
returning id as q \gset
select private.link_for(:'q', 'ProposeTime') is not null as has_link \gset
select public.response_page_text(tests.token(:'pw', :'p1', 'ProposeTime')) as prop \gset
select ok(:'prop' like '%<label for="d_1">Date</label><input type="date" id="d_1" name="d_1"%'
          and :'prop' like '%<label for="s_1">Starts</label><input type="time" id="s_1" name="s_1"%'
          and :'prop' like '%<label for="e_1">Ends</label><input type="time" id="e_1" name="e_1"%'
          and :'prop' like '%<label for="note" style="font-weight:600">Note for the team (optional)</label>%',
  '25. each date and time box is labelled by its own words');
select ok(:'prop' not like '%<label>Date <input%', '26. no box sits inside its label any more');
select ok(:'prop' like '%aria-describedby="d_1_text"%<p class="muted" id="d_1_text" aria-live="polite" style="margin:4px 0 8px">'
            || (select to_char(min(starts_at) at time zone 'America/Los_Angeles', 'FMDy, FMMon FMDD, YYYY')
                  from public.class_session where module_week_id = :'pw') || '</p>%',
  '27. each date also shows as "Sun, Jan 31, 2027"');
select ok(:'prop' like '%<script>%toLocaleDateString(''en-US''%</script>%' and :'prop' not like '%<script src%',
  '28. and changes with the box, with a small script on the page itself');

select * from finish();
rollback;
