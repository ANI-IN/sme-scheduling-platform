-- Release Milestone 3: sign in and access.
begin;
\ir ../helpers/helpers.psql
select plan(22);

select tests.company();

create or replace function tests.login_with(p_claims jsonb)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', (jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated') || p_claims)::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  execute 'set local role authenticated';
end $$;

create or replace function tests.google_user(p_email text, p_hd text default null)
returns jsonb language sql as $$
  select jsonb_build_object('user', jsonb_build_object('email', p_email, 'app_metadata', jsonb_build_object('provider', 'google'),
    'user_metadata', case when p_hd is null then '{}'::jsonb else jsonb_build_object('custom_claims', jsonb_build_object('hd', p_hd)) end));
$$;

-- =============================================================== sign in hook (Development)
select is(public.hook_before_user_created(tests.google_user('new.person@example.com', 'example.com')), '{}'::jsonb,
  'a company Google account may sign in');
select ok(public.hook_before_user_created(tests.google_user('someone@gmail.com')) ? 'error', 'an account from another domain is refused');
select ok(exists (select 1 from public.history_event where action = 'Sign in refused' and note like '%someone@gmail.com%'),
  'a refused sign in is recorded in Activity history');

-- =============================================================== Production: Google with the hosted domain only
update public.app_config set environment = 'Production' where id = 1;
select ok(public.hook_before_user_created('{"user": {"email": "dev@example.com", "app_metadata": {"provider": "email"}}}') ? 'error',
  'in Production the development email link cannot be used');
select ok(public.hook_before_user_created(tests.google_user('x@example.com')) ? 'error',
  'in Production a Google account without the company hosted domain is refused');
select is(public.hook_before_user_created(tests.google_user('x@example.com', 'example.com')), '{}'::jsonb,
  'in Production a company Google Workspace account is accepted');
select tests.login_with('{"email": "ops@example.com", "app_metadata": {"provider": "email"}}');
select ok(not private.is_team_user(), 'in Production an email link session gets no access, even with a company address');
select tests.as_postgres();
select tests.login_with('{"email": "ops@example.com", "app_metadata": {"provider": "google"}, "user_metadata": {"custom_claims": {"hd": "example.com"}}}');
select ok(private.is_team_user(), 'and a company Google session does');
select tests.as_postgres();
update public.app_config set environment = 'Development' where id = 1;

-- =============================================================== first sign in creates the team member
select tests.login_with('{"email": "new.person@example.com", "user_metadata": {"full_name": "New Person"}}');
select is(public.my_account(true) -> 'member' ->> 'name', 'New Person', 'the first sign in creates the team member from the Google name');
select is((public.my_account() ->> 'needs_discord')::boolean, true, 'and asks once for their Discord user ID');
select throws_ok($$ select public.update_my_profile('123') $$, '22023', null, 'a Discord user ID must be 17 to 20 digits');
select public.update_my_profile('120000000000000002');
select is((public.my_account() ->> 'needs_discord')::boolean, false, 'once added, the question is not asked again');
select ok(exists (select 1 from public.history_event where action = 'Signed in' and actor_label = 'New Person'), 'sign ins are recorded');
select tests.as_postgres();
select tests.login_with('{"email": "later.person@example.com"}');
select public.my_account(true);
select public.update_my_profile(null, true);
select is((public.my_account() ->> 'needs_discord')::boolean, false, 'choosing "Later" also stops the question');
select tests.as_postgres();

-- =============================================================== remove access
select tests.make_team_member('Admin Person') as admin \gset
select tests.login_as('admin.person@example.com');
select public.set_member_access((select id from public.team_member where email = 'new.person@example.com'), false, 'Left the company');
select ok(exists (select 1 from public.history_event where action = 'Access removed' and note = 'Left the company'),
  'removing access is recorded with the reason');
select throws_ok(format('select public.set_member_access(%L, false)', :'admin'), '22023', null, 'nobody can remove their own access');
select tests.as_postgres();
select tests.login_with('{"email": "new.person@example.com"}');
select is((public.my_account(true) ->> 'allowed')::boolean, false, 'a removed person cannot use the app');
select is((select count(*)::int from public.domain), 0, 'and sees no data');
select tests.as_postgres();
select ok(public.hook_before_user_created(tests.google_user('new.person@example.com', 'example.com')) ? 'error',
  'and cannot sign up again');
select is((select active from public.team_member where email = 'new.person@example.com'), false, 'and is no longer tagged or reminded');

-- =============================================================== setup
select ok(not has_function_privilege('authenticated', 'public.configure_environment(text, text)', 'EXECUTE'),
  'only the setup script can change the environment and the allowed domain');
update public.app_config set company_email_domain = '' where id = 1;
select is(public.hook_before_user_created(tests.google_user('a@example.com', 'example.com')) -> 'error' ->> 'message',
  'Sign in is not set up yet. Ask the admin to set the company email domain.', 'without an allowed domain nobody can sign in');

select * from finish();
rollback;
