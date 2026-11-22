-- Release 3, B2 (decision 311): SEC 9, only real bounces of emails the app sent count.
begin;
\ir ../helpers/helpers.psql
select plan(7);

select tests.scenario('TB', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
update public.message set status = 'Sent', sent_at = now(), external_id = 'tb-thread-1'
 where id = (select id from public.message where module_week_id = :'mw' and channel = 'Email' and lower(to_address) = 'tb.instr1@example.org'
              order by created_at limit 1);

-- Forged: anyone can mail the inbox with "Undeliverable" and an instructor's address.
select is(public.record_bounce('tb.instr1@example.org', 'fake-1', 'Undeliverable') ->> 'trusted', 'false',
  '1. a "bounce" with no thread is ignored');
select is(public.record_bounce('tb.instr1@example.org', 'fake-2', 'Undeliverable', 'some-other-thread', true) ->> 'trusted', 'false',
  '2. a bounce in a thread the app did not start is ignored, even if it looks like a delivery report');
select is(public.record_bounce('tb.instr2@example.org', 'fake-3', 'Undeliverable', 'tb-thread-1', true) ->> 'trusted', 'false',
  '3. a bounce for another address than the email in that thread is ignored');
select ok((select email_bounced_at is null from public.instructor where id = :'i1')
          and tests.open_items(:'dom', 'MessageFailed') = 0, '4. nothing was changed and no task was raised');
select is((select count(*)::int from public.history_event where action like 'Bounce ignored: %'), 3,
  '5. each ignored one is in Activity history, in plain words');

-- Real: in the thread of the email the app sent to that address.
select is(public.record_bounce('tb.instr1@example.org', 'real-1', 'Mailbox not found', 'tb-thread-1', true) ->> 'trusted', 'true',
  '6. a real bounce of an email the app sent counts');
select ok((select email_bounced_at is not null from public.instructor where id = :'i1')
          and tests.open_items(:'dom', 'MessageFailed') = 1, '7. the address is marked and one task is raised');

select * from finish();
rollback;
