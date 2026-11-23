-- Rollback of 20261123000033_planned_instructor.sql: the two new functions go. No earlier definition changed.

drop function if exists public.planned_instructors(uuid[]);
drop function if exists private.planned_instructor(uuid, timestamptz);
