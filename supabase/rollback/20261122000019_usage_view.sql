-- Rollback of 20261122000019_usage_view.sql (decision 307). Removes the Usage view's data function; nothing else
-- changed.

drop function if exists public.usage_summary();
