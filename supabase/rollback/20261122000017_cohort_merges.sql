-- Rollback of 20261122000017_cohort_merges.sql (decision 304). Removes cohort merges: class weeks stay in the cohort
-- they are in now (a combined cohort stays as an ordinary cohort), and the cohorts no longer say they were merged.

drop function if exists public.undo_cohort_merge(uuid);
drop function if exists public.merge_cohorts(uuid[], date, uuid, uuid, text, text, uuid[], uuid[], boolean, boolean, text);
drop function if exists private.merge_plan(uuid[], date, uuid, uuid, text, text, uuid[], uuid[]);
drop table if exists public.cohort_merge;
alter table public.cohort drop column if exists merged_from, drop column if exists merged_into;
