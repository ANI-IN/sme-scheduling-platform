-- Rollback of 20261122000018_schedule_board.sql (decision 305). Removes the Schedule board's data function; nothing
-- else changed.

drop function if exists public.schedule_board(uuid, date, date);
drop function if exists private.board_status(uuid, timestamptz);
