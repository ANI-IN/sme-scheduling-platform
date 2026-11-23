-- Decision 336: both times read well, also inside brackets; the subject shows the class's own time only.
begin;
\ir ../helpers/helpers.psql
select plan(5);
select is(private.fmt_local_both('2027-01-31 17:00+00', 'US'), 'Sun, Jan 31 · 9:00 AM PST / 10:30 PM IST',
  '1. same date: the other time zone without its date');
select is(private.fmt_local_both('2027-02-05 02:00+00', 'US'), 'Thu, Feb 4 · 6:00 PM PST / Fri, Feb 5 · 7:30 AM IST',
  '2. another date: with its date');
select is(private.fmt_local_both('2027-01-31 04:30+00', 'India'), 'Sun, Jan 31 · 10:00 AM IST / Sat, Jan 30 · 8:30 PM PST',
  '3. an India class: India time first');
select tests.scenario('RB', 'Live', '2027-01-31', 1) as a \gset
select (:'a'::jsonb ->> 'domain') as dom, (:'a'::jsonb ->> 'mw') as mw \gset
select tests.tick(:'dom', '2027-01-01 18:00+00');
select is((select subject from public.message where module_week_id = :'mw' and template_id = 'M1' and channel = 'Email'),
  'Can you teach Concurrency RB? (Sun, Jan 31 · 9:00 AM PST)', '4. the subject: one time, no brackets inside brackets');
select ok(not exists (select 1 from public.message where module_week_id = :'mw' and body_text ~ '\([^()]*\([^()]*\)[^()]*\)'),
  '5. no brackets inside brackets in any message body');
select * from finish();
rollback;
