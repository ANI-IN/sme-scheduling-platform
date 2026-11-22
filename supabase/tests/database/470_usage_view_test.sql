-- Release 3, M13 (decision 307): the Usage view, for admins.
begin;
\ir ../helpers/helpers.psql
select plan(5);

select tests.company();
select tests.login_google('uva@example.com'); select tests.as_postgres();
select tests.login_google('uvb@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id, discord_prompt_dismissed_at)
select initcap(split_part(u.email, '@', 1)), u.email, u.id, now() from auth.users u where u.email in ('uva@example.com', 'uvb@example.com')
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id;
select public.set_admin((select id from public.team_member where email = 'uva@example.com'), true);
insert into public.n8n_usage (month, workflow, runs, last_at)
values (date_trunc('month', now() at time zone 'UTC')::date, 'WF4', 7, now())
on conflict (month, workflow) do update set runs = public.n8n_usage.runs + 7;

select public.usage_summary() as u \gset
select ok((:'u'::jsonb ->> 'database_bytes')::bigint > 0 and (:'u'::jsonb ->> 'database_limit_bytes')::bigint = 524288000,
  '1. the database size, against the free plan''s 500 MB');
select ok((:'u'::jsonb ->> 'n8n_runs_month')::int >= 7 and exists (
            select 1 from jsonb_array_elements(:'u'::jsonb -> 'n8n_by_workflow') x where x ->> 'workflow' = 'WF4' and (x ->> 'runs')::int >= 7),
  '2. n8n runs this month, by workflow');
select is((:'u'::jsonb ->> 'email_cap')::int, (select daily_email_cap from public.app_config where id = 1), '3. the email cap and what is left');

select tests.login_google('uvb@example.com');
select throws_ok($$ select public.usage_summary() $$, '42501', 'Only an admin can see usage.', '4. only admins see usage');
select tests.as_postgres();
select tests.login_google('uva@example.com');
select lives_ok($$ select public.usage_summary() $$, '5. an admin sees it');

select * from finish();
rollback;
