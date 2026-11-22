-- Rollback of 20261122000024_board_bulk_actions.sql (decision 314). Removes bulk move and bulk cancel; nothing else
-- changed.

drop function if exists public.bulk_change_weeks(text, uuid[], int, text, boolean, boolean);
