-- Decision 345, findings of the live journey of 24 November 2026.
-- 38: in a Testing domain, a typed reply from the testing mailbox is matched to the test instructor by its email thread.
-- 39: going back to Draft also withdraws open time change requests, and sends nothing.
begin;
\ir ../helpers/helpers.psql
select plan(11);

-- =============================================================== 38. replies by email thread in a Testing domain
select tests.scenario('TR', 'Test', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
-- The request email reached the testing mailbox; n8n reported its Gmail id, which is also its thread's id.
update public.message set status = 'Sent', sent_at = now(), external_id = 'gmail-thread-tr'
 where module_week_id = :'mw' and template_id = 'M1' and channel = 'Email';
select is((select to_address from public.message where external_id = 'gmail-thread-tr'), 'test-inbox@example.com',
  '1. set up: in testing the request email went to the testing mailbox');

select is(public.record_inbound_message('Email', 'Testing Inbox <test-inbox@example.com>', 'Re: Can you teach?',
  'Could the review start at 6:30 PM?', 'gmail-reply-tr-1', null, null, 'gmail-thread-tr') ->> 'matched', 'true',
  '2. a reply from the testing mailbox in that thread is matched');
select is((select instructor_id from public.message where unique_key = 'in:Email:gmail-reply-tr-1'), :'i1'::uuid,
  '3. to the test instructor the request was for');
select ok(exists (select 1 from public.attention_item where type = 'TypedReply' and title like 'Typed reply from TR Instr1%'),
  '4. the task names the instructor, not an unknown sender');

select is(public.record_inbound_message('Email', 'someone@example.com', 'Re: Can you teach?', 'Hello',
  'gmail-reply-tr-2', null, null, 'gmail-thread-tr') ->> 'matched', 'false',
  '5. someone else replying in that thread is not matched by the thread');
select is(public.record_inbound_message('Email', 'test-inbox@example.com', 'Hello', 'A new email',
  'gmail-reply-tr-3', null, null, 'gmail-thread-unknown') ->> 'matched', 'false',
  '6. the testing mailbox in a thread the app did not start is not matched');

-- A domain in use: its emails are not test emails, so the thread is never used there.
select tests.scenario('TL', 'Live', '2027-01-31', 1) as k \gset
select (:'k'::jsonb ->> 'domain') as dom2, (:'k'::jsonb ->> 'mw') as mw2 \gset
select tests.tick(:'dom2', '2027-01-01 18:00+00');
update public.message set status = 'Sent', sent_at = now(), external_id = 'gmail-thread-tl'
 where module_week_id = :'mw2' and template_id = 'M1' and channel = 'Email';
select is(public.record_inbound_message('Email', 'test-inbox@example.com', 'Re: Can you teach?', 'Yes',
  'gmail-reply-tl-1', null, null, 'gmail-thread-tl') ->> 'matched', 'false',
  '7. outside testing the thread does not stand in for the sender');

-- =============================================================== 39. back to Draft withdraws time change requests
select tests.scenario('TD', 'Live', '2027-01-31', 1) as m \gset
select (:'m'::jsonb ->> 'domain') as dom3, (:'m'::jsonb ->> 'mw') as mw3, (:'m'::jsonb ->> 'i1') as d1,
       (:'m'::jsonb ->> 'ops') as ops3 \gset
select email as ops3_email from public.team_member where id = :'ops3' \gset
select tests.at('2027-01-05 18:00+00');
select tests.login_member(:'ops3_email');
select public.assign_manually(:'mw3', :'d1');
select c.id as cls from public.class_session c where c.module_week_id = :'mw3' and c.status = 'Planned' order by c.starts_at limit 1 \gset
select public.change_class_time(:'cls',
  ((select starts_at from public.class_session where id = :'cls') at time zone 'America/Los_Angeles')::date,
  ((select starts_at from public.class_session where id = :'cls') at time zone 'America/Los_Angeles')::time + interval '1 hour',
  ((select ends_at from public.class_session where id = :'cls') at time zone 'America/Los_Angeles')::time + interval '1 hour');
select tests.as_postgres();
select is((select count(*)::int from public.request where module_week_id = :'mw3' and kind = 'TimeChange'
            and status in ('Queued', 'Sent', 'Reminded')), 1, '8. set up: a time change request is open');
select count(*)::int as before_msgs from public.message where domain_id = :'dom3' and status in ('Scheduled', 'Pending', 'Sending', 'Sent') \gset
select tests.login_member(:'ops3_email');
select public.set_domain_status(:'dom3', 'Draft');
select tests.as_postgres();
select is((select status || ' / ' || close_reason from public.request where module_week_id = :'mw3' and kind = 'TimeChange'),
  'Withdrawn / Domain set to Draft', '9. back to Draft withdraws it');
select is((select count(*)::int from public.message where domain_id = :'dom3' and audience = 'Instructor'
            and status in ('Scheduled', 'Pending', 'Sending')), 0, '10. nothing is left waiting for the instructor');
select ok((select count(*)::int from public.message where domain_id = :'dom3' and status in ('Scheduled', 'Pending', 'Sending', 'Sent'))
          <= :before_msgs, '11. and nothing new is sent to anyone');

select * from finish();
rollback;
