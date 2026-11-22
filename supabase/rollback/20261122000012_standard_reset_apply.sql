-- Rollback of 20261122000012_standard_reset_apply.sql (decision 299): only functions were added.
drop function if exists public.standard_compare(uuid);
drop function if exists public.apply_standard(uuid, uuid[], boolean, boolean, text);
drop function if exists public.reset_to_standard(uuid[], uuid, boolean, boolean, text);
drop function if exists private.save_standard_plans(jsonb, boolean, text, uuid, text, jsonb);
drop function if exists private.standard_plans(jsonb);
drop function if exists private.apply_week_plan(jsonb);
drop function if exists private.standard_week_plan(uuid, boolean);
drop function if exists private.standard_target(uuid);
