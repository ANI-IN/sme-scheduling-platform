-- Release 3, M2 (decisions 276, 277 and 286): admins, admin only settings and the beta allow list.
begin;
\ir ../helpers/helpers.psql
select plan(41);

select tests.company();
select tests.scenario('AD', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'i1') as i1 \gset

-- Three people who have signed in: Ana (admin), Ben (normal user), Cat (normal user); Dan never signed in.
select tests.login_google('ana@example.com'); select tests.as_postgres();
select tests.login_google('ben@example.com'); select tests.as_postgres();
select tests.login_google('cat@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id, discord_prompt_dismissed_at)
select initcap(split_part(u.email, '@', 1)), u.email, u.id, now() from auth.users u
 where u.email in ('ana@example.com', 'ben@example.com', 'cat@example.com')
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id;
insert into public.team_member (name, email) values ('Dan', 'dan@example.com') on conflict do nothing;
select id as ana from public.team_member where email = 'ana@example.com' \gset
select id as ben from public.team_member where email = 'ben@example.com' \gset
select id as cat from public.team_member where email = 'cat@example.com' \gset
select id as dan from public.team_member where email = 'dan@example.com' \gset

-- 1 to 2: the first admin is made by the setup command (the service).
select lives_ok(format('select public.set_admin(%L, true)', :'ana'), '1. the service can make the first admin');
select ok(exists (select 1 from public.history_event where action = 'Admin rights given'), '2. giving admin rights is logged');

-- 3 to 16: a normal user is refused by every admin only change.
select tests.login_google('ben@example.com');
select ok(not private.is_admin(), '3. Ben is a normal user');
select throws_ok($$ select public.set_app_config('{}') $$, '42501', 'Only an admin can change this.', '4. app links and alert channel: admins only');
select throws_ok($$ select public.set_kill_switch(false) $$, '42501', 'Only an admin can change this.', '5. Pause all messages: admins only');
select throws_ok(format('select public.set_member_access(%L, false)', :'cat'), '42501', 'Only an admin can change this.', '6. removing access: admins only');
select throws_ok(format('select public.send_test_alert(%L)', :'cat'), '42501', 'Only an admin can change this.', '7. the admin channel test: admins only');
select throws_ok($$ select public.check_discord('servers') $$, '42501', 'Only an admin can change this.', '8. refreshing the Discord server list: admins only');
select throws_ok($$ select public.check_discord_server('900000000000000101') $$, '42501', 'Only an admin can change this.', '9. checking a Discord server: admins only');
select throws_ok($$ select public.set_settings_at('Global', null, '{}') $$, '42501', 'Only an admin can change this.', '10. settings for every domain: admins only');
select throws_ok($$ select public.set_archived('discord_server', '900000000000000101', true) $$, '42501', 'Only an admin can change this.', '11. archiving a Discord server: admins only');
select throws_ok($$ select public.reset_sandbox_data('RESET') $$, '42501', 'Only an admin can change this.', '12. Reset Sandbox data: admins only');
select throws_ok(format('select public.set_admin(%L, true)', :'cat'), '42501', 'Only an admin can change this.', '13. making an admin: admins only');
select throws_ok($$ select public.beta_list_add('new@example.com') $$, '42501', 'Only an admin can change this.', '14. adding to the beta list: admins only');
select throws_ok($$ select public.beta_list_remove('cat@example.com') $$, '42501', 'Only an admin can change this.', '15. removing from the beta list: admins only');
select throws_ok($$ select public.set_sign_in_mode('Beta list') $$, '42501', 'Only an admin can change this.', '16. who may sign in: admins only');

-- 17 to 19: a normal user keeps everything for their own domain.
select lives_ok(format('select public.set_settings_at(''Domain'', %L, ''{}'')', :'dom'), '17. a normal user still changes their domain''s settings');
select lives_ok(format('select public.check_discord(''instructor'', %L)', :'i1'), '18. and checks an instructor''s Discord username');
select is((select count(*)::int from public.beta_access), 0, '19. a normal user cannot read the beta list');
select tests.as_postgres();

-- 20 to 27: admin rights.
select tests.login_google('ana@example.com');
select ok(private.is_admin(), '20. Ana is an admin');
select throws_ok(format('select public.set_admin(%L, true)', :'dan'), '22023', null, '21. only someone who has signed in can be an admin');
select throws_ok(format('select public.set_admin(%L, false)', :'ana'), '22023',
  'There must always be at least one admin. Make someone else an admin first.', '22. the last admin cannot remove themselves');
select throws_ok(format('select public.set_member_access(%L, false)', :'ana'), '22023', null, '23. nor lose their access');
select lives_ok(format('select public.set_admin(%L, true)', :'ben'), '24. an admin makes another signed in person an admin');
select tests.as_postgres();
select tests.login_google('ben@example.com');
select ok(private.is_admin(), '25. every admin can do everything: Ben can now');
select lives_ok(format('select public.set_admin(%L, false)', :'ana'), '26. any admin can remove admin rights while another admin is left');
select throws_ok(format('select public.set_admin(%L, false)', :'ben'), '22023', null, '27. the last admin cannot be removed');
select tests.as_postgres();
select is((select count(*)::int from public.history_event where action in ('Admin rights given', 'Admin rights removed')), 3,
  '28. every admin change is in Activity history');

-- 29 to 40: the beta list and who may sign in (Ben is the admin now).
select tests.login_google('ben@example.com');
select throws_ok($$ select public.beta_list_add('friend@gmail.com') $$, '22023', null, '29. only company accounts can be on the beta list');
select throws_ok($$ select public.set_sign_in_mode('Beta list') $$, '22023', null, '30. the beta list mode needs every admin on the list first');
select lives_ok($$ select public.beta_list_add('ben@example.com', 'Admin') $$, '31. an admin adds themselves');
select lives_ok($$ select public.beta_list_add('Cat@Example.com') $$, '32. and a colleague (case does not matter)');
select ok(exists (select 1 from public.beta_access where email = 'cat@example.com'), '33. the list keeps the address in lower case');
select lives_ok($$ select public.set_sign_in_mode('Beta list') $$, '34. then switches sign in to the beta list');
select ok(exists (select 1 from public.history_event where action = 'Who may sign in: people on the beta list'), '35. which is logged');
select tests.as_postgres();
select is(private.sign_in_problem('ana@example.com', 'google', 'example.com'),
  'SME Scheduling is in a closed beta. Ask an admin to add you to the beta list.', '36. a company account not on the list is refused');
select is(private.sign_in_problem('cat@example.com', 'google', 'example.com'), null, '37. a listed account gets in');
select ok(public.hook_before_user_created('{"user": {"email": "eve@example.com", "app_metadata": {"provider": "google"}, "user_metadata": {"custom_claims": {"hd": "example.com"}}}}') ? 'error',
  '38. a new account not on the list cannot even be created');
select tests.login_google('ben@example.com');
select throws_ok($$ select public.beta_list_remove('ben@example.com') $$, '22023', null, '39. an admin cannot be taken off the list');
select lives_ok($$ select public.beta_list_remove('cat@example.com') $$, '40. a colleague can');
select tests.as_postgres();
select tests.login_google('cat@example.com');
select ok(not private.is_team_user(), '41. and is locked out at once, without waiting for the next sign in');
select tests.as_postgres();

select * from finish();
rollback;
