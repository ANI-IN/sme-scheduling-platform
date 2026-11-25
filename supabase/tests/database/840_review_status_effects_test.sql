-- Decision 349: R9, the app can say what a domain status change will do before it happens.
begin;
\ir ../helpers/helpers.psql
select plan(3);

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

-- =============================================================== R9
select tests.login_member(:'ops_email');
select is((public.domain_status_effects(:'db', 'Draft') ->> 'open_requests')::int, 1, '22. Draft would withdraw one open request');
select ok((public.domain_status_effects(:'db', 'Draft') ->> 'waiting_messages')::int >= 0, '23. and says how many waiting messages it cancels');
select is((public.domain_status_effects(:'db', 'Test') ->> 'open_requests')::int, 0, '24. Testing withdraws none');

select * from finish();
rollback;
