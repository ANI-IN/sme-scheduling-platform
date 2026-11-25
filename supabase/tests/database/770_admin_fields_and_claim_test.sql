-- Decision 346, two Critical findings of the independent review of 25 November 2026 (docs/REVIEW_REPORT.md).
-- R1: only an admin changes who is an admin and whose access is removed, even writing the table directly.
-- R2: a message the beta guard cancels as it is claimed is never handed to n8n.
begin;
\ir ../helpers/helpers.psql
select plan(14);

select tests.company();
select tests.scenario('AF', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'ops') as ops \gset
select email as ops_email from public.team_member where id = :'ops' \gset
update public.team_member set is_admin = false, version = version where id = :'ops';
insert into public.team_member (name, email, is_admin) values ('AF Admin', 'af.admin@example.com', true)
on conflict ((lower(email))) do update set is_admin = true;
insert into public.team_member (name, email, access_removed_at) values ('AF Removed', 'af.removed@example.com', now())
on conflict ((lower(email))) do update set access_removed_at = now();
select id as admin_id from public.team_member where email = 'af.admin@example.com' \gset
select id as removed_id from public.team_member where email = 'af.removed@example.com' \gset

-- Decision 347 takes away direct team member deletes altogether; the grant is put back here only so check 3 still
-- tests the admin guard itself.
grant delete on public.team_member to authenticated;

-- =============================================================== R1, as a team member who is not an admin
select tests.login_member(:'ops_email');
select throws_ok(format($$ update public.team_member set is_admin = true where id = %L $$, :'ops'),
  '42501', 'Only an admin can change who is an admin or whose access is removed.',
  '1. someone who is not an admin cannot make themselves an admin');
select throws_ok(format($$ update public.team_member set access_removed_at = null, access_removed_by = null where id = %L $$, :'removed_id'),
  '42501', 'Only an admin can change who is an admin or whose access is removed.',
  '2. nor give back access an admin removed');
select throws_ok(format($$ delete from public.team_member where id = %L $$, :'admin_id'),
  '42501', 'Only an admin can remove an admin.', '3. nor delete an admin');
select throws_ok($$ insert into public.team_member (name, email, is_admin) values ('AF Sneaky', 'af.sneaky@example.com', true) $$,
  '42501', 'Only an admin can add someone as an admin or with their access removed.', '4. nor add a new admin');
select lives_ok(format($$ update public.team_member set job_title = 'Operations lead' where id = %L $$, :'ops'),
  '5. the Team page''s own saves still work (name, job title, email, Discord)');
select lives_ok($$ insert into public.team_member (name, email) values ('AF New', 'af.new@example.com') $$,
  '6. and adding a colleague who is not an admin still works');
select tests.as_postgres();
select is((select is_admin from public.team_member where id = :'ops'), false, '7. nothing changed: still not an admin');
select ok((select access_removed_at is not null from public.team_member where id = :'removed_id'), '8. and the access is still removed');

-- =============================================================== R1, as an admin
select tests.login_member('af.admin@example.com');
select lives_ok(format($$ update public.team_member set is_admin = true where id = %L $$, :'ops'),
  '9. an admin still makes someone an admin (set_admin does this after its own checks)');
select tests.as_postgres();
select is((select is_admin from public.team_member where id = :'ops'), true, '10. and it is saved');

-- =============================================================== R2, a message blocked as it is claimed
delete from public.message;
insert into public.message (audience, template_id, channel, status, unique_key, recipient_label, to_address, subject, body_text)
values ('Team', 'T_AF', 'Email', 'Pending', 'af-outside', 'AF', 'friend@gmail.com', 'AF', 'AF'),
       ('Team', 'T_AF', 'Email', 'Pending', 'af-inside', 'AF', 'pat@example.com', 'AF', 'AF');
-- Queued while anyone could receive messages; the beta rule is switched on before n8n takes them.
select public.set_recipient_rules('{example.com}', 'Test instructors and signed in colleagues');
select is((select array_agg(unique_key order by unique_key) from public.claim_outbound_messages(25)), '{af-inside}'::text[],
  '11. only the message that may still go out is handed to n8n');
select is((select status from public.message where unique_key = 'af-outside'), 'Cancelled', '12. the other is cancelled');
select ok((select blocked from public.message where unique_key = 'af-outside'), '13. as blocked, with its reason');
select is((select status from public.message where unique_key = 'af-inside'), 'Sending', '14. the allowed one is being sent');

select * from finish();
rollback;
