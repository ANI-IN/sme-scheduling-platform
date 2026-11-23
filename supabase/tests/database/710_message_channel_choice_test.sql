-- Decision 339: a welcome goes to its own domain's channel; a message for no domain to the checked channel.
begin;
\ir ../helpers/helpers.psql
select plan(3);
select tests.scenario('MA', 'Live', '2027-01-31', 1) as a \gset
select tests.scenario('MB', 'Live', '2027-01-31', 1) as b \gset
select (:'a'::jsonb ->> 'domain') as da, (:'b'::jsonb ->> 'domain') as db, (:'a'::jsonb ->> 'i1') as i1 \gset
-- The instructor's old channel in domain A (created first), and their new, checked channel in domain B.
insert into public.discord_channel (id, server_id, name, bot_can_post) values ('999000000000071001', '999000000000000001', 'ma-new', true)
on conflict (id) do nothing;
insert into public.instructor_channel (instructor_id, domain_id, channel_id, channel_name, ready_at, created_at)
values (:'i1', :'db', '999000000000071001', 'ma-new', now(), now() + interval '1 minute');
select private.send_welcome(:'i1', :'db', 'Discord');
select is((select discord_channel_id from public.message where instructor_id = :'i1' and template_id = 'M22' and channel = 'Discord'),
  '999000000000071001', '1. the welcome of domain B goes to their channel in domain B, not an older one elsewhere');
select is((select count(*)::int from public.message where instructor_id = :'i1' and template_id = 'M22' and channel = 'Discord'),
  1, '2. once');
select public.contact_instructor(:'i1', 'Hello');
select is((select discord_channel_id from public.message where instructor_id = :'i1' and template_id = 'M23' and channel = 'Discord'),
  '999000000000071001', '3. a message for no domain goes to their checked channel');
select * from finish();
rollback;
