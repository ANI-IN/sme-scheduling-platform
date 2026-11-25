-- Decision 348, review findings of 25 November 2026 (docs/REVIEW_REPORT.md), message delivery (see also 800, 810).
-- R4: a report for a message that is no longer being sent (or waiting for a check) changes nothing.
-- R6: retries wait about 1, 5 and 15 minutes (or Discord's retry_after) and do not call n8n; the brakes start well
--     before 10,000 runs.
begin;
\ir ../helpers/helpers.psql
select plan(19);

select tests.scenario('DL', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'ops') as ops \gset
delete from public.message;
update public.message set status = 'Cancelled' where status in ('Pending', 'Sending', 'Scheduled', 'CheckNeeded');

create or replace function tests.msg(p_key text, p_status text default 'Pending', p_channel text default 'Discord',
  p_template text default 'T_DL', p_request uuid default null)
returns uuid language sql as $$
  insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, to_address, body_text, request_id)
  values ('Team', p_template, p_channel, p_status, p_key, 'DL', case when p_channel = 'Email' then 'dl@example.com' end, 'DL', p_request)
  returning id;
$$;

-- =============================================================== R4
select tests.msg('dl-1') as m1 \gset
select count(*) from public.claim_outbound_messages(100);
select claimed_at as c1 from public.message where id = :'m1' \gset
select public.report_message_result(:'m1', true, 'ext-1');
select is(public.report_message_result(:'m1', false, null, 'late 500') ->> 'status', 'Ignored', '1. a late failure for a sent message is ignored');
select is((select status from public.message where id = :'m1'), 'Sent', '2. it stays Sent');
select tests.msg('dl-2', 'Failed') as m2 \gset
select public.report_message_result(:'m2', false, null, 'late 500');
select is((select status from public.message where id = :'m2'), 'Failed', '3. a failed message is never put back in the queue');
select tests.msg('dl-3') as m3 \gset
select count(*) from public.claim_outbound_messages(100);
select claimed_at as c3 from public.message where id = :'m3' \gset
select is(public.report_message_result(:'m3', false, null, 'stale run', false, null, :'c3'::timestamptz - interval '3 minutes') ->> 'status',
  'Ignored', '4. a report from an earlier claim is ignored');
select is(public.report_message_result(:'m3', true, 'ext-3', null, false, null, :'c3'::timestamptz) ->> 'status', 'Sent',
  '5. the run that claimed it reports it');

-- =============================================================== R6, retries
-- Record the calls to n8n instead of making them (this transaction is rolled back).
delete from public.action_queue;
create temp table pokes (reason text);
grant all on pokes to public;
create or replace function private.poke_soon(p_reason text) returns void language plpgsql volatile security definer set search_path = ''
as $$ begin insert into pg_temp.pokes values (p_reason); end $$;
select tests.msg('dl-4') as m4 \gset
select count(*) > 0 from public.claim_outbound_messages(100);
delete from pokes;
select is(public.report_message_result(:'m4', false, null, 'Discord 500') ->> 'status', 'Retry', '6. a first failure is retried');
select is((select count(*)::int from pokes), 0, '7. without calling n8n at once');
select ok((select retry_at between now() + interval '50 seconds' and now() + interval '70 seconds' from public.message where id = :'m4'),
  '8. after about a minute');
select ok(not exists (select 1 from public.claim_outbound_messages(100) where id = :'m4'), '9. not before');
select is(private.clock_work(), null, '10. and the clock does not call for it yet');
update public.message set retry_at = now() - interval '1 second' where id = :'m4';
select is(private.clock_work(), 'messages to send', '11. once due, the clock calls');
select ok(exists (select 1 from public.claim_outbound_messages(100) where id = :'m4'), '12. and it is taken again');
select public.report_message_result(:'m4', false, null, 'Discord 500');
select ok((select retry_at between now() + interval '290 seconds' and now() + interval '310 seconds' from public.message where id = :'m4'),
  '13. the second retry waits about 5 minutes');
update public.message set retry_at = now() - interval '1 second' where id = :'m4';
select count(*) from public.claim_outbound_messages(100);
select public.report_message_result(:'m4', false, null, 'Discord 500');
select ok((select retry_at between now() + interval '890 seconds' and now() + interval '910 seconds' from public.message where id = :'m4'),
  '14. the third about 15 minutes');
update public.message set retry_at = now() - interval '1 second' where id = :'m4';
select count(*) from public.claim_outbound_messages(100);
select is(public.report_message_result(:'m4', false, null, 'Discord 500') ->> 'status', 'Failed', '15. then it is Failed, with its task');
select tests.msg('dl-5') as m5 \gset
select count(*) from public.claim_outbound_messages(100);
select public.report_message_result(:'m5', false, null, 'Discord 429', false, 600);
select ok((select retry_at >= now() + interval '595 seconds' from public.message where id = :'m5'), '16. Discord''s retry_after is kept');
update public.message set status = 'Cancelled' where id = :'m5';

-- =============================================================== R6, the brakes
select is(array[private.clock_reply_interval(4999), private.clock_reply_interval(5000), private.clock_reply_interval(6500), private.clock_reply_interval(8000)],
  array[interval '10 minutes', interval '30 minutes', interval '60 minutes', null], '17. reply reading slows from 5,000 runs and stops at 8,000');
select is(array[private.poke_gap(4999), private.poke_gap(5000), private.poke_gap(6500), private.poke_gap(8000)],
  array[interval '5 seconds', interval '1 minute', interval '5 minutes', null], '18. immediate calls are batched from 5,000 and stop at 8,000');
select is(array[private.clock_gap(6499), private.clock_gap(6500), private.clock_gap(8000)],
  array[interval '1 minute', interval '5 minutes', interval '10 minutes'], '19. the clock calls less often from 6,500');

select * from finish();
rollback;
