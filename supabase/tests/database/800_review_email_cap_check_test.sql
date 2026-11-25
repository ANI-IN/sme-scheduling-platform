-- Decision 348: R30, the claim takes no more emails than the daily limit allows; R43, "no longer needed" waits
-- while the request it answers is waiting for a check.
begin;
\ir ../helpers/helpers.psql
select plan(7);

select tests.scenario('DL', 'Live', '2027-01-31', 3) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'ops') as ops \gset
delete from public.message;

create or replace function tests.msg(p_key text, p_status text default 'Pending', p_channel text default 'Discord',
  p_template text default 'T_DL', p_request uuid default null)
returns uuid language sql as $$
  insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, to_address, body_text, request_id)
  values ('Team', p_template, p_channel, p_status, p_key, 'DL', case when p_channel = 'Email' then 'dl@example.com' end, 'DL', p_request)
  returning id;
$$;

-- =============================================================== R30, the daily email limit
update public.message set status = 'Cancelled' where status in ('Pending', 'Sending', 'Scheduled', 'CheckNeeded');
update public.app_config set daily_email_cap = 2 where id = 1;
select tests.msg('dl-e' || g, 'Pending', 'Email') from generate_series(1, 5) g;
select tests.msg('dl-d', 'Pending', 'Discord');
select is((select count(*)::int from public.claim_outbound_messages(100) where channel = 'Email'), 2, '20. only as many emails as the limit leaves');
select is((select status from public.message where unique_key = 'dl-d'), 'Sending', '21. Discord messages are not held');
select is((select count(*)::int from public.claim_outbound_messages(100) where channel = 'Email'), 0, '22. and no more after that');
update public.app_config set daily_email_cap = 400 where id = 1;
update public.message set status = 'Cancelled' where status in ('Pending', 'Sending', 'Scheduled', 'CheckNeeded');

-- =============================================================== R43, "no longer needed" waits for the check
select tests.tick(:'dom', '2027-01-01 18:00+00');
select id as req from public.request where module_week_id = :'mw' and instructor_id = :'i1' and kind = 'Outreach' \gset
update public.message set status = 'CheckNeeded', claimed_at = now() - interval '20 minutes' where request_id = :'req' and template_id = 'M1' and channel = 'Discord';
update public.message set status = 'Cancelled' where request_id = :'req' and template_id = 'M1' and channel = 'Email';
update public.request set status = 'Withdrawn', close_reason = 'Sooner class' where id = :'req';
insert into public.message (domain_id, audience, template_id, channel, status, unique_key, instructor_id, module_week_id, request_id, recipient_label, body_text, discord_channel_id)
select :'dom', 'Instructor', 'M12', 'Discord', 'Pending', 'dl-m12', :'i1', :'mw', :'req', 'DL', 'No longer needed',
       (select discord_channel_id from public.message where request_id = :'req' and channel = 'Discord' and template_id = 'M1');
select ok(not exists (select 1 from public.claim_outbound_messages(100) where template_id = 'M12'),
  '23. "no longer needed" waits while the ask waits for a check');
select id as lost from public.message where request_id = :'req' and template_id = 'M1' and channel = 'Discord' \gset
select email as ops_email from public.team_member where id = :'ops' \gset
select tests.login_member(:'ops_email');
select lives_ok(format($$ select public.resolve_message_check(%L, false) $$, :'lost'), '24. answering "send again" for a closed request works');
select tests.as_postgres();
select is((select status from public.message where unique_key = 'dl-m12'), 'Cancelled', '25. it never arrived, so no "no longer needed"');
select is((select count(*)::int from public.message where request_id = :'req' and template_id = 'M1'), 2, '26. and no new copy of the old ask');

select * from finish();
rollback;
