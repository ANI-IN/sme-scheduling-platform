-- Release 3, M0 (decision 284): the Need help page offers no materials, and "Please answer by" is in the class's
-- own time zone.
begin;
\ir ../helpers/helpers.psql
select plan(9);

select tests.scenario('BF', 'Live', '2027-01-31', 2) as j \gset
select (:'j'::jsonb ->> 'domain') as dom, (:'j'::jsonb ->> 'mw') as mw, (:'j'::jsonb ->> 'i1') as i1 \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select r.deadline_at as deadline from public.request r
 where r.module_week_id = :'mw' and r.kind = 'Outreach' and r.instructor_id = :'i1' \gset

-- 1 to 4: the Need help page.
select tests.click(:'mw', :'i1', 'Yes');
select tests.tick(:'dom', '2027-01-21 18:00+00');
select public.response_page(tests.token(:'mw', :'i1', 'NeedHelp'))::text as help_page \gset
select ok(:'help_page' not like '%Here are your materials%' and :'help_page' not like '%No materials have been added%',
  '1. the Need help page no longer offers materials');
select ok(:'help_page' like '%Tell us what you need, and we''ll help you before class.%Send help request%',
  '2. it opens the help form at once, with a help line');
select ok(:'help_page' not like '%I still need help%', '3. the help form is no longer hidden behind "I still need help"');
select ok(:'help_page' like '%Class materials or content%', '4. an instructor can still ask for materials with Need help');

-- 5 to 9: "Please answer by" in the class's own time zone.
select tests.scenario('BG', 'Live', '2027-01-31', 2) as k \gset
select (:'k'::jsonb ->> 'domain') as dom2, (:'k'::jsonb ->> 'mw') as mw2, (:'k'::jsonb ->> 'i1') as j1 \gset
select tests.tick(:'dom2', '2027-01-01 18:00+00');
select r.deadline_at as deadline2 from public.request r
 where r.module_week_id = :'mw2' and r.kind = 'Outreach' and r.instructor_id = :'j1' \gset
select isnt(nullif(:'deadline2', '')::timestamptz, null::timestamptz, '5. the request has a reply by time');
select ok(public.response_page(tests.token(:'mw2', :'j1', 'Yes'))::text
            like '%Please answer by ' || private.fmt_local(:'deadline2'::timestamptz, 'US') || '.%',
  '6. a US class shows the reply by time in US Pacific time');
select ok(public.response_page(tests.token(:'mw2', :'j1', 'Yes'))::text ~ 'Please answer by [^<]* P[SD]T\.',
  '7. with the Pacific zone named');

update public.class_session set region = 'India' where module_week_id = :'mw2';
select ok(public.response_page(tests.token(:'mw2', :'j1', 'Yes'))::text
            like '%Please answer by ' || private.fmt_local(:'deadline2'::timestamptz, 'India') || '.%',
  '8. an India class shows the reply by time in India time');
select ok(public.response_page(tests.token(:'mw2', :'j1', 'Yes'))::text ~ 'Please answer by [^<]* IST\.',
  '9. with IST named, not Pacific');

select * from finish();
rollback;
