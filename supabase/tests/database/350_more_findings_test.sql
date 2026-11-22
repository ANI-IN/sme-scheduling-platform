-- Release 3, M4b part 2 (decisions 283 and 289): N5 and the database part of SEC 9.
begin;
\ir ../helpers/helpers.psql
select plan(6);

-- 1 to 2: N5, "no longer needed" still goes out when the ask may have arrived.
select tests.scenario('NF', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
-- The automation took the ask and never reported back; after 15 minutes it is marked failed (DIS 13).
update public.message set status = 'Failed', claimed_at = now() - interval '20 minutes', last_error = 'never reported'
 where module_week_id = :'mw' and template_id = 'M1' and direction = 'Outbound';
select set_config('app.actor_kind', 'System', false);
select private.withdraw_open_request(:'mw', 'Test', now(), true);
select private.cancel_stale_messages();
select ok(exists (select 1 from public.message where module_week_id = :'mw' and template_id = 'M12' and status <> 'Cancelled'),
  '1. an ask the automation took may have arrived, so "no longer needed" still goes out');

select tests.scenario('NG', 'Live', '2027-01-31', 2) as k \gset
select (:'k'::jsonb ->> 'domain') as dom2, (:'k'::jsonb ->> 'mw') as mw2 \gset
select tests.tick(:'dom2', '2027-01-01 18:00+00');
-- This ask never left: nothing took it.
update public.message set status = 'Cancelled', claimed_at = null, last_error = 'never went out'
 where module_week_id = :'mw2' and template_id = 'M1' and direction = 'Outbound';
select private.withdraw_open_request(:'mw2', 'Test', now(), true);
select private.cancel_stale_messages();
select ok(not exists (select 1 from public.message where module_week_id = :'mw2' and template_id = 'M12' and status <> 'Cancelled'),
  '2. "no longer needed" for an ask that never went out is still dropped');

-- 3 to 6: SEC 9, masked links from outside text show where they go in team messages on Discord.
insert into public.message (direction, audience, channel, template_id, unique_key, status, body_text)
values ('Outbound', 'Team', 'Discord', 'T9', 'sec9-team', 'Pending',
        'Help details: [Open the app](https://evil.example/x) and [docs](<http://a.example>)');
select is((select body_text from public.message where unique_key = 'sec9-team'),
  'Help details: Open the app (https://evil.example/x) and docs (http://a.example)',
  '3. a masked link in a team message on Discord shows its address');
update public.message set body_text = 'Again: [Click](https://evil.example/y)' where unique_key = 'sec9-team';
select is((select body_text from public.message where unique_key = 'sec9-team'), 'Again: Click (https://evil.example/y)',
  '4. also when the text is changed');
insert into public.message (direction, audience, channel, template_id, unique_key, status, body_text)
values ('Outbound', 'Team', 'Email', 'T9', 'sec9-email', 'Pending', 'See [docs](https://a.example)');
select is((select body_text from public.message where unique_key = 'sec9-email'), 'See [docs](https://a.example)',
  '5. emails are not changed');
select is(private.plain_discord_links('[not a web link](ftp://x) and [a]b'), '[not a web link](ftp://x) and [a]b',
  '6. text that is not a web link is left alone');

select * from finish();
rollback;
