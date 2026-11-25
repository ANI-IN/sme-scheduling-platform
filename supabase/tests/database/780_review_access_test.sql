-- Decision 347, review findings of 25 November 2026 (docs/REVIEW_REPORT.md), access rules.
-- R3: during the beta only an admin changes Test instructor, an instructor's emails or a Discord account; the beta
--     checks need a real signed in account and look at the address the message goes to.
-- R7: deleting a domain, cohort, module or team member needs an admin, never the last admin; no direct deletes and
--     no direct domain status changes.
-- R12: Contact instructor follows the Draft rule and the Discord server approval of a domain.
-- R31: resetting a setting for every domain needs an admin.
-- R33: no write access the app does not use.
begin;
\ir ../helpers/helpers.psql
select plan(45);

select tests.company();
select tests.scenario('RV', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'module') as modu, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'i2') as i2, (:'j'::jsonb ->> 'ops') as ops \gset
select email as ops_email from public.team_member where id = :'ops' \gset
update public.team_member set is_admin = false, version = version where id = :'ops';
-- A real signed in colleague (Google identity and team row), and an admin.
select tests.login_google('rv.colleague@example.com'); select tests.as_postgres();
insert into public.team_member (name, email, auth_user_id, discord_user_id)
select 'RV Colleague', 'rv.colleague@example.com', u.id, '700000000000000501' from auth.users u where u.email = 'rv.colleague@example.com'
on conflict ((lower(email))) do update set auth_user_id = excluded.auth_user_id, discord_user_id = excluded.discord_user_id;
-- A made up team row: no real account behind it.
insert into public.team_member (name, email, auth_user_id, discord_user_id)
values ('RV Made Up', 'rv.madeup@example.com', gen_random_uuid(), '700000000000000502');
insert into public.team_member (name, email, is_admin) values ('RV Admin', 'rv.admin@example.com', true);
select id as admin_id from public.team_member where email = 'rv.admin@example.com' \gset
update public.team_member set is_admin = false, version = version where email <> 'rv.admin@example.com' and is_admin;
update public.app_config set message_recipients = 'Test instructors and signed in colleagues', recipient_email_domains = '{}',
       beta_list_may_receive = false where id = 1;

-- =============================================================== R3, someone who is not an admin
select tests.login_member(:'ops_email');
select throws_like(format($$ update public.instructor set is_test = true where id = %L $$, :'i1'),
  'During the beta, only an admin%', '1. cannot tick Test instructor');
select throws_like(format($$ update public.instructor set primary_email = 'someone.else@example.org' where id = %L $$, :'i1'),
  'During the beta, only an admin%', '2. cannot change an instructor''s email');
select throws_like(format($$ update public.instructor set discord_username = 'someone.new' where id = %L $$, :'i1'),
  'During the beta, only an admin%', '3. cannot change an instructor''s Discord account');
select throws_like(format($$ insert into public.instructor_email (instructor_id, email) values (%L, 'rv.colleague@example.com') $$, :'i1'),
  'During the beta, only an admin%', '4. cannot add an email to an instructor already there');
select throws_like(format($$ delete from public.instructor_email where instructor_id = %L $$, :'i1'),
  'During the beta, only an admin%', '5. nor remove one');
select throws_like($$ insert into public.instructor (full_name, primary_email, is_test) values ('RV New Test', 'rv.newtest@example.org', true) $$,
  'During the beta, only an admin%', '6. cannot add a test instructor');
select throws_like($$ insert into public.instructor (full_name, primary_email, discord_username) values ('RV New D', 'rv.newd@example.org', 'any.person') $$,
  'During the beta, only an admin%', '7. nor an instructor with a Discord account');
select lives_ok(format($$ update public.instructor set full_name = full_name || ' (edited)', phone = '+1 555 0100' where id = %L $$, :'i1'),
  '8. every other edit still works');
select lives_ok($$ insert into public.instructor (full_name, primary_email) values ('RV New', 'rv.new@example.org') $$,
  '9. adding an instructor still works');
select lives_ok($$ insert into public.instructor_email (instructor_id, email)
  select id, 'rv.new.second@example.org' from public.instructor where primary_email = 'rv.new@example.org' $$,
  '10. with the extra email typed while adding them');
select throws_like(format($$ update public.team_member set discord_username = 'any.person' where id = %L $$, :'ops'),
  'During the beta, only an admin%', '11. cannot change a team member''s Discord account');
select throws_like($$ select public.update_my_profile('any.person') $$,
  'During the beta, only an admin%', '12. nor their own from the Discord prompt');
select lives_ok($$ select public.update_my_profile(null, true) $$, '13. but can close the prompt');
select lives_ok(format($$ update public.team_member set job_title = 'Operations' where id = %L $$, :'ops'),
  '14. and edit everything else on the Team page');

-- =============================================================== R3, an admin and a non beta setting
select tests.login_member('rv.admin@example.com');
select lives_ok(format($$ update public.instructor set is_test = true where id = %L $$, :'i2'), '15. an admin ticks Test instructor');
select tests.as_postgres();
update public.app_config set message_recipients = 'Anyone' where id = 1;
select tests.login_member(:'ops_email');
select lives_ok(format($$ update public.instructor set primary_email = 'rv.anyone@example.org' where id = %L $$, :'i1'),
  '16. outside the beta rule the team edits as before');
select tests.as_postgres();
update public.app_config set message_recipients = 'Test instructors and signed in colleagues' where id = 1;

-- =============================================================== R3, the checks themselves
select ok(not private.is_signed_in_colleague_discord('700000000000000502'), '17. a made up team row is no signed in colleague');
select ok(private.is_signed_in_colleague_discord('700000000000000501'), '18. a real account is');
-- Even with a colleague's address among an instructor's emails, the address the message goes to decides.
update public.instructor set is_test = false, primary_email = 'rv.real@example.org' where id = :'i1';
insert into public.instructor_email (instructor_id, email) values (:'i1', 'rv.colleague@example.com');
insert into public.message (domain_id, audience, template_id, channel, status, unique_key, instructor_id, recipient_label, to_address, subject, body_text)
values (:'dom', 'Instructor', 'M23', 'Email', 'Pending', 'rv-real', :'i1', 'RV', 'rv.real@example.org', 'RV', 'RV'),
       (:'dom', 'Instructor', 'M23', 'Email', 'Pending', 'rv-colleague', :'i1', 'RV', 'rv.colleague@example.com', 'RV', 'RV');
select is((select status from public.message where unique_key = 'rv-real'), 'Cancelled',
  '19. an email to an address that is not a beta address is blocked');
select is((select status from public.message where unique_key = 'rv-colleague'), 'Pending', '20. one to the colleague''s address goes');
select unalike((select last_error from public.message where unique_key = 'rv-real'), '%test instructor, then%',
  '21. the reason no longer says to tick Test instructor');
select alike((select last_error from public.message where unique_key = 'rv-real'), '%Ask an admin%', '22. it says to ask an admin');
delete from public.instructor_email where instructor_id = :'i1' and email = 'rv.colleague@example.com';

-- =============================================================== R7, deletes and domain status
select tests.login_member(:'ops_email');
select alike(public.delete_preview('domain', :'dom') ->> 'blocked', 'Only an admin can delete%', '23. the preview says only an admin');
select throws_like(format($$ select public.delete_item('domain', %L, 'RV') $$, :'dom'), 'Only an admin can delete%', '24. and a team member cannot delete the domain');
select throws_like(format($$ select public.delete_item('module', %L, 'Concurrency RV') $$, :'modu'), 'Only an admin can delete%', '25. nor a module');
select throws_like(format($$ select public.delete_item('team_member', %L, 'RV Colleague') $$,
  (select id from public.team_member where email = 'rv.colleague@example.com')), 'Only an admin can delete%', '26. nor a team member');
select throws_ok(format($$ delete from public.domain where id = %L $$, :'dom'), '42501', null, '27. no direct domain delete');
select throws_ok(format($$ delete from public.module where id = %L $$, :'modu'), '42501', null, '28. no direct module delete');
select throws_ok($$ delete from public.cohort $$, '42501', null, '29. no direct cohort delete');
select throws_ok($$ delete from public.team_member where email = 'rv.colleague@example.com' $$, '42501', null, '30. no direct team member delete');
select throws_ok(format($$ update public.domain set status = 'Draft' where id = %L $$, :'dom'), '42501', null, '31. no direct status change');
select throws_ok($$ insert into public.domain (name, status) values ('RV Direct Live', 'Live') $$, '42501', null, '32. a new domain starts in Draft');
select lives_ok(format($$ update public.domain set name = name || ' renamed' where id = %L $$, :'dom'), '33. renaming still works');
select tests.login_member('rv.admin@example.com');
select alike(public.delete_preview('team_member', :'admin_id') ->> 'blocked', '%only admin%', '34. the only admin cannot be deleted');

-- =============================================================== R31, settings for every domain
select tests.login_member(:'ops_email');
select throws_ok($$ select public.reset_setting_at('Global', null, 'short_notice_days') $$, '42501', 'Only an admin can change this.',
  '35. resetting for every domain needs an admin');
select lives_ok(format($$ select public.reset_setting_at('Domain', %L, 'short_notice_days') $$, :'dom'), '36. for one domain the team still can');
select tests.as_postgres();

-- =============================================================== R12, Contact instructor
select tests.scenario('RVDraft', 'Draft', '2027-02-07', 1) as d \gset
select (:'d'::jsonb ->> 'i1') as drafti \gset
select tests.login_member(:'ops_email');
select throws_like(format($$ select public.contact_instructor(%L, 'Hello') $$, :'drafti'), '%draft%',
  '37. an instructor only in draft domains cannot be messaged');
select tests.as_postgres();
select is((select count(*)::int from public.message where instructor_id = :'drafti'), 0, '38. and nothing was queued');
update public.app_config set message_recipients = 'Anyone' where id = 1;
select tests.login_member(:'ops_email');
select lives_ok(format($$ select public.contact_instructor(%L, 'Hello') $$, :'i2'), '39. an instructor of a live domain can');
select tests.as_postgres();
select is((select count(*)::int from public.message where instructor_id = :'i2' and template_id = 'M23' and domain_id is distinct from :'dom'::uuid), 0,
  '40. the message belongs to that domain, so its rules apply');
select ok(not exists (select 1 from public.message m join public.discord_channel c on c.id = m.discord_channel_id
  where m.instructor_id = :'i2' and m.template_id = 'M23' and not private.server_allowed(c.server_id, m.domain_id)),
  '41. and its channel is in a server approved for the domain');

-- =============================================================== R33, only the write access the app uses
select is((select string_agg(table_name, ', ' order by table_name) from (
  select distinct table_name::text from information_schema.role_table_grants
   where grantee = 'authenticated' and table_schema = 'public' and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')) x),
  'class_pattern_item, class_type, cohort, domain, domain_team, holiday, instructor, instructor_email, instructor_unavailability, module, module_operations, module_owner, module_resource, standard_schedule_class, team_member',
  '42. only the setup tables the app edits have write access');
select ok(not has_table_privilege('authenticated', 'public.instructor', 'DELETE'), '43. instructors are deleted only through delete');
select ok(not has_table_privilege('authenticated', 'public.team_member', 'DELETE'), '44. team members too');
select ok(not exists (select 1 from information_schema.role_table_grants where grantee = 'authenticated'
  and table_schema = 'public' and privilege_type = 'TRUNCATE'), '45. nobody can empty a table');

select * from finish();
rollback;
