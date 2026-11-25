-- Decision 349, review findings of 25 November 2026 (see also 830 and 840).
-- R8: a Discord reply belongs to the instructor whose channel it was posted in.
-- R19: automatic replies raise no task; unknown senders share one task a day.
begin;
\ir ../helpers/helpers.psql
select plan(7);

select tests.scenario('RA', 'Live', '2027-01-31', 1) as a \gset
select tests.scenario('RB', 'Live', '2027-01-31', 1) as b \gset
select (:'a'::jsonb ->> 'domain') as da, (:'b'::jsonb ->> 'domain') as db, (:'a'::jsonb ->> 'i1') as ia,
       (:'b'::jsonb ->> 'i1') as ib, (:'a'::jsonb ->> 'mw') as mwa, (:'b'::jsonb ->> 'mw') as mwb,
       (:'a'::jsonb ->> 'ops') as ops \gset
select email as ops_email from public.team_member where id = :'ops' \gset
update public.instructor set discord_user_id = '700000000000000801' where id = :'ia';
update public.instructor set discord_user_id = '700000000000000803' where id = :'ib';
select channel_id as cha from public.instructor_channel where instructor_id = :'ia' and domain_id = :'da' \gset
select channel_id as chb from public.instructor_channel where instructor_id = :'ib' and domain_id = :'db' \gset
select tests.tick(:'da', '2027-01-01 18:00+00');
select tests.tick(:'db', '2027-01-01 18:00+00');
select set_config('app.test_now', '', true);
-- Then the same person is a test instructor in both domains, with one Discord account.
update public.instructor set is_test = true where id in (:'ia', :'ib');
update public.instructor set discord_user_id = '700000000000000801' where id = :'ib';

-- =============================================================== R8
select public.record_inbound_message('Discord', '700000000000000801', null, 'Can we start later?', 'd-1', null, null, null, :'cha');
select is((select instructor_id from public.message where unique_key = 'in:Discord:d-1'), :'ia'::uuid,
  '1. a reply in domain A''s channel belongs to the instructor of that channel');
select public.record_inbound_message('Discord', '700000000000000801', null, 'And this week?', 'd-2', null, null, null, :'chb');
select is((select instructor_id from public.message where unique_key = 'in:Discord:d-2'), :'ib'::uuid,
  '2. in domain B''s channel, to B''s instructor');
select is((select domain_id from public.message where unique_key = 'in:Discord:d-2'), :'db'::uuid, '3. and that domain''s task');

-- =============================================================== R19
select is(public.record_inbound_message('Email', 'away@example.org', 'Out of office', 'I am away', 'auto-1', null, null, null, null, true) ->> 'automatic',
  'true', '16. an automatic reply is recorded as automatic');
select is((select count(*)::int from public.attention_item where title like '%away@example.org%' or dedupe_key like 'typed:unknown:%'), 0,
  '17. and raises no task');
select public.record_inbound_message('Email', 'spam1@example.net', 'Offer', 'Buy', 'spam-1');
select public.record_inbound_message('Email', 'spam2@example.net', 'Offer', 'Buy', 'spam-2');
select is((select count(*)::int from public.attention_item where dedupe_key like 'typed:unknown:%'), 1,
  '18. two unknown senders on one day share one task');
select ok((select detail like '%spam1@example.net%' and detail like '%spam2@example.net%' from public.attention_item
            where dedupe_key like 'typed:unknown:%'), '19. which names both');

select * from finish();
rollback;
