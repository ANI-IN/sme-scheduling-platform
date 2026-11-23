-- Decision 337: Contact instructor sends one message to the instructor's channel and email, logged.
begin;
\ir ../helpers/helpers.psql
select plan(6);
select tests.scenario('CI', 'Live', '2027-01-31', 1) as a \gset
select (:'a'::jsonb ->> 'i1') as i1 \gset
select throws_ok(format($$ select public.contact_instructor(%L, '  ') $$, :'i1'), '22023', 'Write a message first.', '1. an empty message is refused');
select is((public.contact_instructor(:'i1', 'Can you share your slides by Friday?') ->> 'messages')::int, 2, '2. on Discord and by email');
select ok((select bool_and(template_id = 'M23' and body_text like '%Can you share your slides by Friday?%') from public.message
            where instructor_id = :'i1' and template_id = 'M23'), '3. with the text written');
select ok(exists (select 1 from public.message where instructor_id = :'i1' and template_id = 'M23' and channel = 'Discord' and discord_channel_id is not null),
  '4. the Discord copy goes to their own channel');
select ok(exists (select 1 from public.history_event where action = 'Message sent to CI Instr1'), '5. and it is in Activity history');
update public.instructor set status = 'Archived' where id = :'i1';
select throws_ok(format($$ select public.contact_instructor(%L, 'Hello') $$, :'i1'), '22023', null, '6. nothing goes to an archived instructor');
select * from finish();
rollback;
