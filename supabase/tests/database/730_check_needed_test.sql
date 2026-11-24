-- Leftover work of 24 November 2026 (decision 341): a message the automation took 15 minutes ago without saying
-- whether it was sent is never sent again by itself. It becomes "Check needed", the team gets a task and an alert,
-- and chooses "Send again" or "It arrived, mark as sent". A late answer from the automation settles the check.
begin;
\ir ../helpers/helpers.psql
select plan(22);

select tests.scenario('CN', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1,
       (:'j'::jsonb ->> 'ops') as ops \gset

create or replace function tests.stuck(p_key text, p_minutes int, p_channel text default 'Discord', p_audience text default 'Instructor')
returns uuid language sql as $$
  insert into public.message (domain_id, audience, template_id, channel, unique_key, status, instructor_id, module_week_id,
                              recipient_label, to_address, body_text, attempts, claimed_at)
  select d, p_audience, 'M1', p_channel, p_key, 'Sending', case when p_audience = 'Instructor' then i end, w, 'CN Instr1',
         case when p_channel = 'Email' then 'cn.instr1@example.com' end, 'Can you teach?', 1, now() - make_interval(mins => p_minutes)
    from (select current_setting('tests.dom')::uuid d, current_setting('tests.i1')::uuid i, current_setting('tests.mw')::uuid w) x
  returning id;
$$;
select set_config('tests.dom', :'dom', false), set_config('tests.i1', :'i1', false), set_config('tests.mw', :'mw', false);
select count(*)::int as before_msgs from public.message \gset

-- =============================================================== 1. 14 minutes: still Sending, nothing happens
select tests.stuck('cn-young', 14) as young \gset
select public.claim_outbound_messages(1);
select is((select status from public.message where id = :'young'), 'Sending', '1. a message taken 14 minutes ago is left alone');

-- =============================================================== 2. 15 minutes: Check needed, never sent again
select tests.stuck('cn-old', 20) as old \gset
select count(*)::int as n_before from public.message where id <> :'old' and unique_key like 'cn-old%' \gset
create temp table claimed2 as select * from public.claim_outbound_messages(100);
select is((select status from public.message where id = :'old'), 'CheckNeeded', '2. after 15 minutes it becomes Check needed');
select ok(not exists (select 1 from claimed2 where id = :'old'), '3. it is not handed to the automation again');
select is((select count(*)::int from public.message where unique_key like 'cn-old%' and id <> :'old'), 0,
  '4. no copy of it is made (nothing is sent again by itself)');
select ok((select last_error from public.message where id = :'old') like 'Not known whether it arrived%not sent again by itself.',
  '5. it says plainly that it is not known whether it arrived');
select is((select discord_failed_at from public.instructor where id = :'i1'), null,
  '6. the instructor''s Discord is not marked as failing (nothing is known to have failed)');
select is((select type || ' / ' || status from public.attention_item where dedupe_key = 'msgcheck:' || :'old'), 'MessageCheck / Open',
  '7. the operations team gets a task');
select ok((select title from public.attention_item where dedupe_key = 'msgcheck:' || :'old') like 'Check whether "%" reached CN Instr1',
  '8. the task says what to check');
select ok((select detail from public.attention_item where dedupe_key = 'msgcheck:' || :'old') like '%"It arrived, mark as sent"%"Send again"%',
  '9. the task names both choices');
select ok(exists (select 1 from public.message where attention_item_id = (select id from public.attention_item where dedupe_key = 'msgcheck:' || :'old')
                   and audience = 'Team'), '10. and the team is alerted');
select ok(exists (select 1 from public.history_event where entity_id = :'old' and action like 'Check needed: M1 to CN Instr1%'),
  '11. Activity history says a check is needed');
-- A later run does nothing more.
select public.claim_outbound_messages(100);
select is((select count(*)::int from public.attention_item where dedupe_key = 'msgcheck:' || :'old'), 1, '12. one task, not one per run');

-- =============================================================== 3. It arrived, mark as sent
select tests.login_member(email) from public.team_member where id = :'ops';
select is((public.resolve_message_check(:'old', true)) ->> 'status', 'Sent', '13. It arrived marks it as sent');
select tests.as_postgres();
select is((select status from public.message where id = :'old'), 'Sent', '14. the message reads Sent');
select is((select status from public.attention_item where dedupe_key = 'msgcheck:' || :'old'), 'Done', '15. the task is done');
select ok(exists (select 1 from public.history_event where entity_id = :'old' and action like 'Marked as arrived: M1 to CN Instr1%'),
  '16. Activity history keeps who checked it');
select tests.login_member(email) from public.team_member where id = :'ops';
select throws_like($$ select public.resolve_message_check('$$ || :'old' || $$', false) $$,
  'This message no longer needs a check%', '17. a second answer is refused, so it is never sent twice');
select tests.as_postgres();

-- =============================================================== 4. It did not arrive: Send again, once
select tests.stuck('cn-lost', 30, 'Email') as lost \gset
select public.claim_outbound_messages(100);
select tests.login_member(email) from public.team_member where id = :'ops';
select (public.resolve_message_check(:'lost', false)) ->> 'message_id' as again \gset
select tests.as_postgres();
select is((select status from public.message where id = :'lost') || ' / ' || (select status from public.message where id = :'again'),
  'Failed / Pending', '18. Send again: the old one reads not delivered and one new copy waits to send');
select is((select status from public.attention_item where dedupe_key = 'msgcheck:' || :'lost'), 'Done', '19. its task is done');

-- =============================================================== 5. a late answer from the automation settles it
select tests.stuck('cn-late', 30) as late \gset
select public.claim_outbound_messages(100);
select is((public.report_message_result(:'late', true, 'discord-1')) ->> 'status', 'Sent', '20. a late "sent" answer marks it sent');
select is((select status || ' / ' || done_note from public.attention_item where dedupe_key = 'msgcheck:' || :'late'),
  'Done / The automation said later that it was sent.', '21. and closes the task');

-- =============================================================== 6. the app cannot mark checks by itself
select tests.login_anon();
select throws_ok($$ select public.resolve_message_check(gen_random_uuid(), true) $$, '42501', null,
  '22. someone signed out cannot answer a check');
select tests.as_postgres();

select * from finish();
rollback;
