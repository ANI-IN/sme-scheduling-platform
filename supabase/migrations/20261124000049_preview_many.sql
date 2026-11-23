-- Owner's night batch of 24 November 2026 (decision 334), performance: Instructor requests asked for the next
-- instructor of each class week in its own request (hundreds on a big program, each a round trip to the database).
-- One call now returns them all: { "<class week id>": <what preview_next returns>, ... }. At most 500 at once.
create or replace function public.preview_next_many(p_module_week_ids uuid[])
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_team();
  if cardinality(coalesce(p_module_week_ids, '{}')) > 500 then
    raise exception 'At most 500 class weeks at once.' using errcode = '22023';
  end if;
  return coalesce((select jsonb_object_agg(x, public.preview_next(x)) from unnest(p_module_week_ids) x), '{}'::jsonb);
end;
$$;
revoke execute on function public.preview_next_many(uuid[]) from public, anon;
grant execute on function public.preview_next_many(uuid[]) to authenticated, service_role;
