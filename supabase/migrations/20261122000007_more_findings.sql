-- Release 3, M4b part 2 (decisions 283 and 289): two more low findings that affect security or data.
--
-- * N5: an ask that n8n took but never reported back (now marked failed after 15 minutes, DIS 13) may still have
--   reached the instructor, so its "no longer needed" message is no longer cancelled.
-- * SEC 9 (the database part): text from outside (an unknown sender's email, a help request's details, a typed
--   reply) can reach the team alert channel. Discord masked links such as [Open the app](https://...) hide where a
--   link goes, so in every team message on Discord they are shown as "Open the app (https://...)". The app itself
--   never writes masked links. Checking that a bounce is a real delivery report is WF1's part (n8n).
-- Rollback: supabase/rollback/20261122000007_more_findings.sql.

-- private.cancel_stale_messages: N5 (was 20261112000005_r2_review_fixes.sql).
create or replace function private.cancel_stale_messages()
returns int language plpgsql security definer set search_path = ''
as $$
declare n int := 0; v int;
begin
  -- An ask or reminder whose request has closed (withdrawn, expired, superseded or declined).
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the request closed before this went out.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id in ('M1', 'M2', 'M5', 'M6', 'M7', 'M9') and m.request_id is not null
     and exists (select 1 from public.request r where r.id = m.request_id and r.status not in ('Queued', 'Sent', 'Reminded', 'Accepted'));
  get diagnostics v = row_count; n := n + v;
  -- A reminder for a request that was already answered.
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the instructor answered already.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id in ('M2', 'M9') and m.request_id is not null
     and exists (select 1 from public.request r where r.id = m.request_id and r.status = 'Accepted');
  get diagnostics v = row_count; n := n + v;
  -- A confirmation for a booking that has ended (released, cancelled) before it went out.
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the booking ended before this went out.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id = 'M4' and m.module_week_id is not null
     and not exists (select 1 from public.booking b where b.module_week_id = m.module_week_id
                       and b.instructor_id = m.instructor_id and b.status = 'Active');
  get diagnostics v = row_count; n := n + v;
  -- "No longer needed" for an ask that never went out. N5: an ask the automation took (claimed_at is set) may have
  -- arrived even if it never reported back, so its "no longer needed" still goes out.
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the request it answers never went out.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id in ('M3', 'M12') and m.request_id is not null
     and not exists (select 1 from public.message x where x.request_id = m.request_id and x.template_id in ('M1', 'M2', 'M5')
                       and (x.status in ('Sent', 'Sending') or x.claimed_at is not null));
  get diagnostics v = row_count; n := n + v;
  return n;
end;
$$;
revoke execute on function private.cancel_stale_messages() from public;

create or replace function private.plain_discord_links(p_text text)
returns text language sql immutable set search_path = ''
as $$ select regexp_replace(p_text, '\[([^]\n]*)\]\(\s*<?(https?://[^)\s>]+)>?\s*\)', '\1 (\2)', 'gi'); $$;

create or replace function private.message_plain_discord_links()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.body_text := private.plain_discord_links(new.body_text);
  return new;
end;
$$;

create trigger message_plain_discord_links before insert or update of body_text on public.message
  for each row when (new.channel = 'Discord' and new.audience = 'Team' and new.direction = 'Outbound')
  execute function private.message_plain_discord_links();
