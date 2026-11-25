-- Decision 348: R5, a request's answer window starts when it is sent; one that cannot be sent raises a task and
-- nobody else is asked; time paused does not use up the window.
begin;
\ir ../helpers/helpers.psql
select plan(16);

select tests.company();

-- =============================================================== R5, the window starts when the ask is sent
select tests.scenario('DW', 'Live', '2027-03-07', 2) as w \gset
select (:'w'::jsonb ->> 'domain') as wd, (:'w'::jsonb ->> 'mw') as wmw, (:'w'::jsonb ->> 'i1') as w1 \gset
select tests.tick(:'wd', '2027-02-07 18:00+00');
select id as wreq, sent_at as sent0, deadline_at as dead0 from public.request where module_week_id = :'wmw' and kind = 'Outreach' \gset
-- The ask waits (never sent) past its deadline.
update public.message set created_at = now() - interval '1 hour' where request_id = :'wreq';
select tests.tick(:'wd', (:'dead0'::timestamptz + interval '1 day')::text::timestamptz);
select is((select status from public.request where id = :'wreq'), 'Sent', '27. an ask that never went out is not "No reply"');
select ok(not exists (select 1 from public.message where request_id = :'wreq' and template_id in ('M2', 'M3')),
  '28. no reminder and no "closed" message for it');
-- It goes out a day after the deadline: the window starts then.
select tests.at((:'dead0'::timestamptz + interval '1 day')::text::timestamptz);
update public.message set status = 'Sending', claimed_at = now(), attempts = 1 where request_id = :'wreq' and template_id = 'M1';
select public.report_message_result(id, true, 'sent-' || channel) from public.message where request_id = :'wreq' and template_id = 'M1';
select ok((select deadline_at = :'dead0'::timestamptz + (:'dead0'::timestamptz + interval '1 day' - :'sent0'::timestamptz) from public.request where id = :'wreq'),
  '29. the deadline moves by the time the ask waited');
select ok((select sent_at = :'dead0'::timestamptz + interval '1 day' from public.request where id = :'wreq'), '30. and counts from the send');
select set_config('app.test_now', '', true);

-- Blocked: the beta rule stops every copy of the next ask.
select tests.scenario('DB', 'Live', '2027-03-14', 2) as b \gset
select (:'b'::jsonb ->> 'domain') as bd, (:'b'::jsonb ->> 'mw') as bmw \gset
update public.app_config set message_recipients = 'Test instructors and signed in colleagues' where id = 1;
select tests.tick(:'bd', '2027-02-14 18:00+00');
select id as breq, deadline_at as bdead from public.request where module_week_id = :'bmw' and kind = 'Outreach' \gset
select is((select count(*)::int from public.message where request_id = :'breq' and template_id = 'M1' and not blocked), 0, '31. set up: every copy of the ask is blocked');
select is((select count(*)::int from public.attention_item where dedupe_key = 'asknotsent:' || :'breq' and status <> 'Done'), 1,
  '32. one task says the request was not sent');
select tests.tick(:'bd', (:'bdead'::timestamptz + interval '2 days')::text::timestamptz);
select is((select status from public.request where id = :'breq'), 'Sent', '33. and the week does not move on by itself');
select is((select count(*)::int from public.attention_item where dedupe_key = 'asknotsent:' || :'breq'), 1, '34. still one task');
update public.app_config set message_recipients = 'Anyone' where id = 1;
select set_config('app.test_now', '', true);

-- Pause all: five hours paused do not count.
select tests.scenario('DP', 'Live', '2027-03-21', 2) as p \gset
select (:'p'::jsonb ->> 'domain') as pd, (:'p'::jsonb ->> 'mw') as pmw \gset
update public.discord_server set status = 'Ready' where id = '999000000000000001';
update public.domain set discord_server_id = '999000000000000001', discord_status = 'Ready' where id = :'pd';
select tests.tick(:'pd', '2027-02-21 18:00+00');
select id as preq, deadline_at as pdead from public.request where module_week_id = :'pmw' and kind = 'Outreach' \gset
update public.message set status = 'Sent', sent_at = now() where request_id = :'preq';

insert into public.team_member (name, email, is_admin) values ('DP Admin', 'dp.admin@example.com', true);
select tests.login_member('dp.admin@example.com');
select public.set_kill_switch(false);
select tests.as_postgres();
update public.system_state set kill_switch_changed_at = now() - interval '5 hours' where id = 1;
select tests.login_member('dp.admin@example.com');
select public.set_kill_switch(true);
select tests.as_postgres();
select ok((select deadline_at between :'pdead'::timestamptz + interval '4 hours 59 minutes' and :'pdead'::timestamptz + interval '5 hours 1 minute'
             from public.request where id = :'preq'), '35. after Pause all the deadline is five hours later');
-- A paused domain, three hours.
select deadline_at as pdead2 from public.request where id = :'preq' \gset
select tests.login_member('dp.admin@example.com');
select public.set_domain_status(:'pd', 'Paused');
select tests.as_postgres();
update public.domain set paused_at = now() - interval '3 hours' where id = :'pd';
select tests.login_member('dp.admin@example.com');
select public.set_domain_status(:'pd', 'Live');
select tests.as_postgres();
select ok((select deadline_at between :'pdead2'::timestamptz + interval '2 hours 59 minutes' and :'pdead2'::timestamptz + interval '3 hours 1 minute'
             from public.request where id = :'preq'), '36. a paused domain: three hours later');
-- A paused class week, two hours.
select deadline_at as pdead3 from public.request where id = :'preq' \gset
select tests.login_member('dp.admin@example.com');
select public.pause_outreach(:'pmw', true);
select tests.as_postgres();
update public.module_week set paused_at = now() - interval '2 hours' where id = :'pmw';
select tests.login_member('dp.admin@example.com');
select public.pause_outreach(:'pmw', false);
select tests.as_postgres();
select ok((select deadline_at between :'pdead3'::timestamptz + interval '1 hour 59 minutes' and :'pdead3'::timestamptz + interval '2 hours 1 minute'
             from public.request where id = :'preq'), '37. a paused class week: two hours later');
-- The deadline never passes the class.
select first_class_at as pfirst from public.module_week where id = :'pmw' \gset
select tests.login_member('dp.admin@example.com');
select public.pause_outreach(:'pmw', true);
select tests.as_postgres();
update public.module_week set paused_at = now() - interval '900 days' where id = :'pmw';
select tests.login_member('dp.admin@example.com');
select public.pause_outreach(:'pmw', false);
select tests.as_postgres();
select is((select deadline_at from public.request where id = :'preq'), :'pfirst'::timestamptz, '38. never later than the first class');

-- A request with no messages at all (made by hand) still expires as before.
select tests.scenario('DN', 'Live', '2027-03-28', 2) as n \gset
select (:'n'::jsonb ->> 'domain') as nd, (:'n'::jsonb ->> 'mw') as nmw \gset
select tests.tick(:'nd', '2027-02-28 18:00+00');
select id as nreq, deadline_at as ndead from public.request where module_week_id = :'nmw' and kind = 'Outreach' \gset
delete from public.message where request_id = :'nreq';
select tests.tick(:'nd', (:'ndead'::timestamptz + interval '1 day')::text::timestamptz);
select is((select status from public.request where id = :'nreq'), 'Expired', '39. with nothing held, no reply still moves on');
-- A just queued ask (waiting a moment for n8n) expires as before when its time is up.
select tests.scenario('DQ', 'Live', '2027-04-04', 2) as q \gset
select (:'q'::jsonb ->> 'domain') as qd, (:'q'::jsonb ->> 'mw') as qmw \gset
select tests.tick(:'qd', '2027-03-07 18:00+00');
select id as qreq, deadline_at as qdead from public.request where module_week_id = :'qmw' and kind = 'Outreach' \gset
select tests.tick(:'qd', (:'qdead'::timestamptz + interval '1 day')::text::timestamptz);
select is((select status from public.request where id = :'qreq'), 'Expired', '40. a fresh ask still follows its deadline');
-- Answered by the guard: sending again after the fix closes the task.
select tests.scenario('DR', 'Live', '2027-04-11', 1) as r \gset
select (:'r'::jsonb ->> 'domain') as rd, (:'r'::jsonb ->> 'mw') as rmw \gset
update public.app_config set message_recipients = 'Test instructors and signed in colleagues' where id = 1;
select tests.tick(:'rd', '2027-03-14 18:00+00');
select id as rreq from public.request where module_week_id = :'rmw' and kind = 'Outreach' \gset
update public.app_config set message_recipients = 'Anyone' where id = 1;
select id as blocked_copy from public.message where request_id = :'rreq' and template_id = 'M1' and channel = 'Email' \gset
select tests.login_member('dp.admin@example.com');
select (public.resend_message(:'blocked_copy') ->> 'message_id') as copy \gset
select tests.as_postgres();
update public.message set status = 'Sending', claimed_at = now(), attempts = 1 where id = :'copy';
select public.report_message_result(:'copy', true, 'sent-again');
select is((select status from public.attention_item where dedupe_key = 'asknotsent:' || :'rreq'), 'Done', '41. sending it closes the task');
select set_config('app.test_now', '', true);
select is((select count(*)::int from public.request where status = 'Expired' and close_reason = 'No reply' and id in (:'wreq', :'breq', :'preq', :'rreq')), 0,
  '42. none of the held requests was ever marked no reply');

select * from finish();
rollback;
