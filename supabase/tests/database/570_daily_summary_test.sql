-- Release 3: the daily system summary (T15) in plain words: failed messages and their top reasons, n8n runs this
-- month against 10,000, the database size against 500 MB, and a warning line when either passes 80 percent.
begin;
\ir ../helpers/helpers.psql
select plan(18);

select tests.company();
update public.app_config set admin_discord_channel_id = tests.rand_discord() where id = 1;

-- Failed messages: two for one reason, one with no reason, and one too old to count.
insert into public.message (audience, template_id, channel, status, last_error, updated_at)
values ('Team', 'T9', 'Discord', 'Failed', 'Discord said Missing Access', now()),
       ('Team', 'T9', 'Discord', 'Failed', 'Discord said   Missing Access', now()),
       ('Team', 'T9', 'Email', 'Failed', null, now()),
       ('Team', 'T9', 'Email', 'Failed', 'An old failure', now() - interval '3 days');
insert into public.n8n_usage (month, workflow, runs, last_at)
values (date_trunc('month', now() at time zone 'UTC')::date, 'WF4', 8500, now())
on conflict (month, workflow) do update set runs = 8500;

select public.daily_jobs(now()) as r \gset
select body_text as t, subject as subj from public.message where template_id = 'T15' \gset

select is((select count(*)::int from public.message where template_id = 'T15'), 1, '1. one daily system summary to the admin channel');
select is(:'subj'::text, 'Daily system summary', '2. its subject is in plain words');
select ok(:'t' like 'Daily system summary%', '3. it starts with its name');
select ok(:'t' like '%Messages that failed in the last 24 hours: 3%', '4. failed messages in the last 24 hours, not older ones');
select ok(:'t' like '%Top reasons: Discord said Missing Access (2); No reason recorded (1)%',
  '5. the top reasons, most common first, with how many');
select ok(:'t' like '%n8n runs this month: 8,500 of 10,000 (85%)%', '6. n8n runs this month against the 10,000 limit');
select ok(:'t' like '%Warning: n8n runs this month have passed 80% of the 10,000 limit.%', '7. a warning above 80 percent of n8n runs');
select ok(:'t' ~ 'Database size: [0-9,]+\.[0-9] MB of 500 MB \([0-9]+%\)', '8. the database size against the 500 MB free limit');
select ok(:'t' not like '%the database has passed 80%', '9. no database warning while it is small');
select ok(:'t' !~ '[—–]' and :'t' !~ '\me\.g\.' and :'t' not like '%heartbeat%' and :'t' not like '%TEST MODE%',
  '10. no dashes, no e.g. and no old internal words');
select is((:'r'::jsonb ->> 'n8n_runs_month')::int, 8500, '11. the result has the n8n runs');
select ok((:'r'::jsonb ->> 'database_bytes')::bigint > 0
          and (:'r'::jsonb ->> 'database_limit_bytes')::bigint = 524288000, '12. the result has the database size and its limit');
select is((:'r'::jsonb ->> 'failed_24h')::int, 3, '13. the result keeps the failed count');

-- The 80 percent rules, with any numbers.
select ok(private.daily_summary_usage(7999, 400 * 1048576 - 1) not like '%Warning%', '14. no warning just under 80 percent');
select ok(private.daily_summary_usage(8000, 0) like '%Warning: n8n runs%'
          and private.daily_summary_usage(8000, 0) not like '%Warning: the database%', '15. n8n warning from 8,000 runs');
select ok(private.daily_summary_usage(100, 450 * 1048576) like '%Database size: 450.0 MB of 500 MB (90%)%'
          and private.daily_summary_usage(100, 450 * 1048576) like '%Warning: the database has passed 80% of the 500 MB free limit.%'
          and private.daily_summary_usage(100, 450 * 1048576) not like '%Warning: n8n%', '16. database warning from 400 MB');

-- Still only the automation runs it, and a day has one summary.
select public.daily_jobs(now());
select is((select count(*)::int from public.message where template_id = 'T15'), 1, '17. one summary a day');
select tests.login_google('dsum@example.com');
select throws_ok($$ select public.daily_jobs() $$, '42501', null, '18. only the automation');
select tests.as_postgres();

select * from finish();
rollback;
