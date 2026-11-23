-- Decision 334: one call gives the next instructor of many class weeks, the same as one call each.
begin;
\ir ../helpers/helpers.psql
select plan(3);
select tests.scenario('PM', 'Live', '2027-01-31', 2) as a \gset
select tests.scenario('PN', 'Live', '2027-02-07', 2) as b \gset
select (:'a'::jsonb ->> 'mw') as amw, (:'b'::jsonb ->> 'mw') as bmw \gset
select is(public.preview_next_many(array[:'amw', :'bmw']::uuid[]) -> :'amw', public.preview_next(:'amw'), '1. the same answer as preview_next for the first week');
select is(public.preview_next_many(array[:'amw', :'bmw']::uuid[]) -> :'bmw', public.preview_next(:'bmw'), '2. and for the second');
select is(public.preview_next_many('{}'::uuid[]), '{}'::jsonb, '3. none asked, none returned');
select * from finish();
rollback;
