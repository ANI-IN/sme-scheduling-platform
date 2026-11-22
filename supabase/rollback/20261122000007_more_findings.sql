-- Rollback of 20261122000007_more_findings.sql.
drop trigger if exists message_plain_discord_links on public.message;
drop function if exists private.message_plain_discord_links();
drop function if exists private.plain_discord_links(text);

-- private.cancel_stale_messages as in 20261112000005_r2_review_fixes.sql.
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
  -- "No longer needed" for an ask that never went out.
  update public.message m set status = 'Cancelled', last_error = 'Not sent: the request it answers never went out.'
   where m.status in ('Scheduled', 'Pending') and m.direction = 'Outbound' and m.audience = 'Instructor'
     and m.template_id in ('M3', 'M12') and m.request_id is not null
     and not exists (select 1 from public.message x where x.request_id = m.request_id and x.template_id in ('M1', 'M2', 'M5')
                       and x.status in ('Sent', 'Sending'));
  get diagnostics v = row_count; n := n + v;
  return n;
end;
$$;
revoke execute on function private.cancel_stale_messages() from public;
