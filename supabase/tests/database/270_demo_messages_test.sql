-- Demo fixes, part 2 (decision 268): each Discord user is tagged once, failures are told in plain words,
-- and instructor messages say how to get help instead of listing the materials.
begin;
\ir ../helpers/helpers.psql
select plan(9);

select tests.scenario('DMX', 'Live', '2027-01-31', 1) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'module') as mod,
       (:'j'::jsonb ->> 'owner') as owner, (:'j'::jsonb ->> 'i1') as i1 \gset
-- One person is the owner, the operations person and (as in the Sandbox) the instructor's Discord account.
update public.team_member set discord_user_id = '777000000000000001', version = version where id = :'owner';
insert into public.module_operations (module_id, team_member_id) values (:'mod', :'owner');
update public.instructor set discord_user_id = '777000000000000001', full_name = 'Maya Rao', version = version where id = :'i1';
select private.queue_instructor_message('M4', :'i1', :'mw', null, '2027-01-02 18:00+00', '[]', '{}', false, 'demo');
select id as chan_id from public.message
 where template_id = 'M4' and channel = 'Discord' and discord_channel_id is not null and module_week_id = :'mw' \gset

select is((select cardinality(mention_user_ids) from public.message where id = :'chan_id'),
          (select cardinality(array(select distinct x from unnest(mention_user_ids) x)) from public.message where id = :'chan_id'),
  'tags 1. the confirmation in the channel lists each Discord user once');
select is((select (length(body_text) - length(replace(body_text, '<@777000000000000001>', ''))) / length('<@777000000000000001>')
             from public.message where id = :'chan_id'), 1,
  'tags 2. the person is tagged once in the text, not again in a team line');
update public.message set mention_user_ids = array['5', '5', '6', null, '5'] where id = :'chan_id';
select is((select mention_user_ids from public.message where id = :'chan_id'), array['5', '6'],
  'tags 3. any message keeps each mention once, in order');

select ok((select body_text like '%Need anything before class? Press Need help below or reply to this message, and %will help you.%'
             from public.message where id = :'chan_id'), 'help 1. the confirmation says how to get help');
select ok(not exists (select 1 from public.message where module_week_id = :'mw' and audience = 'Instructor'
                        and (body_text like '%Materials:%' or coalesce(body_html, '') like '%Materials:%')),
  'help 2. no instructor message lists the materials any more');

-- The channel post fails for good: the team is told in plain words, the admin channel gets the technical error.
update public.app_config set admin_discord_channel_id = '777000000000000099' where id = 1;
select public.report_message_result(:'chan_id', false, null, '400 Invalid Form Body (Discord code 50035)', true);
select is((select title from public.attention_item where message_id = :'chan_id'),
  'The confirmation could not be posted in Maya Rao''s Discord channel.',
  'fail 1. the task title says what failed, in plain words');
select ok((select detail like 'Maya still got it by %' and detail like '%Check the channel on Settings, Connections.'
             and detail not like '%50035%' from public.attention_item where message_id = :'chan_id'),
  'fail 2. the task says what still reached her and where to look, without the technical error');
select ok(exists (select 1 from public.message where audience = 'Admin' and template_id = 'T14' and body_text like '%50035%'),
  'fail 3. the admin channel still gets the technical error');
select ok(exists (select 1 from public.history_event where entity_table = 'message' and entity_id = :'chan_id'::uuid
                    and note like '%50035%'), 'fail 4. Activity history keeps the technical error in its details');

select * from finish();
rollback;
