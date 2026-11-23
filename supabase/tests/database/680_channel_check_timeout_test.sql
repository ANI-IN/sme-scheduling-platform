-- Decision 335: an instructor channel check whose Discord work never came back does not stay "Checking".
begin;
\ir ../helpers/helpers.psql
select plan(3);
select tests.scenario('CT', 'Live', '2027-01-31', 1) as a \gset
select (:'a'::jsonb ->> 'domain') as dom, (:'a'::jsonb ->> 'i1') as i1 \gset
insert into public.action_queue (action, payload, status, created_at) values ('discord_channel', '{}'::jsonb, 'Processing', now() - interval '10 minutes')
returning id as act \gset
insert into public.channel_check (instructor_id, domain_id, channel_id, channel_name, action_id)
values (:'i1', :'dom', '999000000000068001', 'ct-one', :'act') returning id as chk \gset
select private.expire_stuck_checks(now());
select is((select status from public.action_queue where id = :'act'), 'Failed', '1. the Discord work that never came back fails');
select is((select status from public.channel_check where id = :'chk'), 'Problem', '2. and the channel check ends');
select ok((select problems[1] like 'The Discord check did not finish%Choose the channel again%' from public.channel_check where id = :'chk'),
  '3. saying what to do');
select * from finish();
rollback;
