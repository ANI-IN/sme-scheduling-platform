-- Core readiness, step 3: archive, restore and permanent delete for every item (decisions 254 to 260).
--
-- Archive hides an item and stops its automation; restore brings both back. Permanent delete first shows what
-- it affects (delete_preview), asks for the item's name when other data goes with it, cancels and notifies
-- the same way as a cancellation, removes every linked row so nothing is left broken, and writes one Activity
-- history entry that keeps the names and values. History itself is never edited or deleted.

-- ------------------------------------------------------------------ columns
alter table public.domain add column if not exists archived_at timestamptz;
alter table public.cohort add column if not exists archived_at timestamptz;
alter table public.discord_server add column if not exists archived_at timestamptz;
-- Class weeks paused because their module or cohort was archived (restoring unpauses only these).
alter table public.module_week add column if not exists archive_paused boolean not null default false;

-- ------------------------------------------------------------------ messages outlive what they were about
-- A cancellation notice queued by a delete must still go out after the class week, request or instructor is
-- gone. The message keeps its own address and text; only the link to the deleted row is cleared.
do $$
declare r record;
begin
  for r in select c.conname, a.attname, c.confrelid::regclass::text as ref
             from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
            where c.conrelid = 'public.message'::regclass and c.contype = 'f'
              and a.attname in ('domain_id', 'module_week_id', 'request_id', 'instructor_id', 'team_member_id',
                                'help_request_id', 'attention_item_id') loop
    execute format('alter table public.message drop constraint %I', r.conname);
    execute format('alter table public.message add constraint %I foreign key (%I) references %s (id) on delete set null',
                   r.conname, r.attname, r.ref);
  end loop;
  for r in select c.conname from pg_constraint c
            where c.conrelid = 'public.reminder'::regclass and c.contype = 'f'
              and c.confrelid = 'public.message'::regclass loop
    execute format('alter table public.reminder drop constraint %I', r.conname);
    execute 'alter table public.reminder add constraint ' || quote_ident(r.conname)
         || ' foreign key (message_id) references public.message (id) on delete set null';
  end loop;
end;
$$;

-- ------------------------------------------------------------------ undo is for edits only
-- A permanent delete cannot be undone, and neither can removing a row through a table edit: undo would bring
-- back a row whose links are gone (decision 258).
create or replace function private.can_undo(e public.history_event)
returns boolean language sql stable security definer set search_path = ''
as $$
  select e.category = 'Setup changes'
     and e.undo_of is null
     and e.entity_table is not null
     and e.entity_table in ('team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
           'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'module_ranking', 'setting',
           'holiday', 'cohort', 'module_operations', 'class_type')
     and (e.action = 'Ranking saved' or e.action in (e.entity_table || ' added', e.entity_table || ' changed'))
     and not (e.entity_table in ('domain', 'cohort', 'module') and (e.before is null or e.after is null))
     and not exists (select 1 from public.history_event u where u.undo_of = e.id);
$$;

-- ------------------------------------------------------------------ plain names for the kinds of items
create or replace function private.kind_label(p_kind text)
returns text language sql immutable set search_path = ''
as $$
  select case p_kind when 'domain' then 'Domain' when 'cohort' then 'Cohort' when 'module' then 'Module'
                     when 'class_week' then 'Class week' when 'instructor' then 'Instructor'
                     when 'team_member' then 'Team member' when 'discord_server' then 'Discord server' else p_kind end;
$$;

-- ------------------------------------------------------------------ what a set of class weeks holds
create or replace function private.week_effects(p_weeks uuid[])
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'weeks', (select count(*) from public.module_week w where w.id = any (p_weeks)),
    'upcoming', (select count(*) from public.module_week w where w.id = any (p_weeks)
                  and w.status not in ('Cancelled', 'Completed')
                  and coalesce(w.last_class_end_at, w.first_class_at, 'infinity') > now()),
    'confirmed', (select count(*) from public.booking b join public.module_week w on w.id = b.module_week_id
                   where w.id = any (p_weeks) and b.status = 'Active'
                     and coalesce(w.last_class_end_at, w.first_class_at, 'infinity') > now()),
    'asking', (select count(*) from public.request r where r.module_week_id = any (p_weeks)
                and r.kind = 'Outreach' and r.status in ('Queued', 'Sent', 'Reminded')),
    'tasks', (select count(*) from public.attention_item a where a.module_week_id = any (p_weeks) and a.status <> 'Done'));
$$;

create or replace function private.effect_lines(e jsonb)
returns jsonb language sql immutable set search_path = ''
as $$
  select coalesce(jsonb_agg(x.line order by x.n), '[]'::jsonb) from (
    select 1 n, (e ->> 'weeks') || case when (e ->> 'weeks')::int = 1 then ' class week' else ' class weeks' end
           || case when (e ->> 'upcoming')::int > 0 then ', ' || (e ->> 'upcoming') || ' still to come' else '' end
           || case when (e ->> 'weeks')::int = 1 then ', with its classes, is deleted' else ', with their classes, are deleted' end as line
     where coalesce((e ->> 'weeks')::int, 0) > 0
    union all
    select 2, (e ->> 'confirmed') || case when (e ->> 'confirmed')::int = 1 then ' confirmed instructor is' else ' confirmed instructors are' end
           || ' told their class is cancelled, as for a cancellation'
     where coalesce((e ->> 'confirmed')::int, 0) > 0
    union all
    select 3, (e ->> 'asking') || case when (e ->> 'asking')::int = 1 then ' open request is' else ' open requests are' end
           || ' withdrawn, and the instructor is told'
     where coalesce((e ->> 'asking')::int, 0) > 0
    union all
    select 4, (e ->> 'tasks') || case when (e ->> 'tasks')::int = 1 then ' open task is' else ' open tasks are' end || ' removed'
     where coalesce((e ->> 'tasks')::int, 0) > 0) x;
$$;

-- ------------------------------------------------------------------ deleting one class week
-- Cancels it first when it is still to come (the instructor and anyone being asked are told, exactly as for a
-- cancellation), then removes everything that belongs to it.
create or replace function private.purge_module_week(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare w public.module_week;
begin
  select * into w from public.module_week where id = p_id;
  if w.id is null then return; end if;
  if w.status not in ('Cancelled', 'Completed')
     and coalesce(w.last_class_end_at, w.first_class_at, 'infinity') > now() then
    perform public.cancel_module_week(w.id, p_reason);
  end if;
  delete from public.attention_item a
   where a.module_week_id = w.id
      or a.class_id in (select id from public.class_session where module_week_id = w.id)
      or a.request_id in (select id from public.request where module_week_id = w.id)
      or a.help_request_id in (select id from public.help_request where module_week_id = w.id);
  update public.help_request set merged_into = null
   where merged_into in (select id from public.help_request where module_week_id = w.id);
  delete from public.help_request where module_week_id = w.id;
  delete from public.request where module_week_id = w.id;
  delete from public.booking_slot
   where booking_id in (select id from public.booking where module_week_id = w.id)
      or class_id in (select id from public.class_session where module_week_id = w.id);
  delete from public.booking where module_week_id = w.id;
  delete from public.class_session where module_week_id = w.id;
  delete from public.module_week where id = w.id;
end;
$$;

-- ------------------------------------------------------------------ deleting a module, cohort, domain
create or replace function private.purge_module(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v uuid;
begin
  for v in select id from public.module_week where module_id = p_id order by first_class_at loop
    perform private.purge_module_week(v, p_reason);
  end loop;
  delete from public.attention_item where module_id = p_id;
  delete from public.module where id = p_id;
end;
$$;

create or replace function private.purge_cohort(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v uuid;
begin
  for v in select id from public.module_week where cohort_id = p_id order by first_class_at loop
    perform private.purge_module_week(v, p_reason);
  end loop;
  delete from public.cohort where id = p_id;
end;
$$;

create or replace function private.purge_domain(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v uuid;
begin
  for v in select id from public.module_week where domain_id = p_id order by first_class_at loop
    perform private.purge_module_week(v, p_reason);
  end loop;
  for v in select id from public.module where domain_id = p_id loop
    perform private.purge_module(v, p_reason);
  end loop;
  delete from public.attention_item where domain_id = p_id;
  update public.help_request set merged_into = null
   where merged_into in (select id from public.help_request where domain_id = p_id);
  delete from public.help_request where domain_id = p_id;
  delete from public.cohort where domain_id = p_id;
  delete from public.domain where id = p_id;
end;
$$;

-- ------------------------------------------------------------------ deleting an instructor
-- Confirmed classes still to come are released and the next instructor is asked; open requests are
-- withdrawn and the next instructor is asked; the instructor is told, as when they are released or a
-- request is withdrawn. Their places in every instructor order close up (no gaps).
create or replace function private.purge_instructor(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  for r in select module_id, cohort_id, rank from public.module_ranking where instructor_id = p_id loop
    delete from public.module_ranking
     where module_id = r.module_id and cohort_id is not distinct from r.cohort_id and instructor_id = p_id;
    -- Two steps, so no two rows ever share a rank on the way.
    update public.module_ranking set rank = rank + 99999
     where module_id = r.module_id and cohort_id is not distinct from r.cohort_id and rank > r.rank;
    update public.module_ranking set rank = rank - 100000
     where module_id = r.module_id and cohort_id is not distinct from r.cohort_id and rank > 99999;
  end loop;
  delete from public.manual_queue_item where instructor_id = p_id;
  for r in select b.id, b.module_week_id from public.booking b join public.module_week w on w.id = b.module_week_id
            where b.instructor_id = p_id and b.status = 'Active'
              and coalesce(w.last_class_end_at, w.first_class_at, 'infinity') > now() loop
    perform private.release_booking_flow(r.id, 'OpsReleased', private.mw_now(r.module_week_id));
  end loop;
  for r in select q.module_week_id from public.request q
            where q.instructor_id = p_id and q.kind = 'Outreach' and q.status in ('Queued', 'Sent', 'Reminded') loop
    perform private.withdraw_open_request(r.module_week_id, p_reason, private.mw_now(r.module_week_id), true);
    perform private.ask_next(r.module_week_id, private.mw_now(r.module_week_id));
  end loop;
  perform private.queue_deliver('delete');
  delete from public.attention_item a
   where a.instructor_id = p_id
      or a.request_id in (select id from public.request where instructor_id = p_id)
      or a.help_request_id in (select id from public.help_request where requester_instructor_id = p_id);
  update public.help_request set merged_into = null
   where merged_into in (select id from public.help_request where requester_instructor_id = p_id);
  delete from public.help_request where requester_instructor_id = p_id;
  delete from public.request where instructor_id = p_id;
  delete from public.booking_slot where instructor_id = p_id
      or booking_id in (select id from public.booking where instructor_id = p_id);
  delete from public.booking where instructor_id = p_id;
  delete from public.instructor where id = p_id;
end;
$$;

-- ------------------------------------------------------------------ deleting a team member
create or replace function private.purge_team_member(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.module_owner where team_member_id = p_id;
  delete from public.module_operations where team_member_id = p_id;
  delete from public.domain_team where team_member_id = p_id;
  delete from public.attention_item a
   where a.request_id in (select id from public.request where team_member_id = p_id)
      or a.help_request_id in (select id from public.help_request where requester_team_member_id = p_id);
  delete from public.reminder where recipient = p_id;
  delete from public.request where team_member_id = p_id;
  update public.help_request set merged_into = null
   where merged_into in (select id from public.help_request where requester_team_member_id = p_id);
  delete from public.help_request where requester_team_member_id = p_id;
  delete from public.team_member where id = p_id;
end;
$$;

-- ------------------------------------------------------------------ forgetting a Discord server
create or replace function private.purge_discord_server(p_id text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  update public.domain set discord_server_id = null, discord_status = 'NotSet', discord_problem = null
   where discord_server_id = p_id;
  delete from public.instructor_channel
   where channel_id in (select id from public.discord_channel where server_id = p_id);
  delete from public.discord_channel where server_id = p_id;
  delete from public.discord_server where id = p_id;
end;
$$;

-- ------------------------------------------------------------------ what a delete will do
-- p_kind: domain, cohort, module, class_week, instructor, team_member, discord_server.
-- Returns the item's name, the plain lines to show, whether its name must be typed, and whether it can be
-- deleted at all (with the reason when not).
create or replace function public.delete_preview(p_kind text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_name text; v_lines jsonb := '[]'; v_e jsonb; v_weeks uuid[]; v_block text; v_extra jsonb := '[]';
  v_info jsonb := '[]'; v_needs boolean;
begin
  perform private.require_team();
  if p_kind = 'domain' then
    select name into v_name from public.domain where id = p_id::uuid;
    v_weeks := array(select id from public.module_week where domain_id = p_id::uuid);
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.module where domain_id = p_id::uuid) || ' modules, with their class times, instructor order, owners and resources' x
       where exists (select 1 from public.module where domain_id = p_id::uuid)
      union all
      select (select count(*) from public.cohort where domain_id = p_id::uuid) || ' cohorts'
       where exists (select 1 from public.cohort where domain_id = p_id::uuid)
      union all
      select (select count(*) from public.instructor_channel where domain_id = p_id::uuid) || ' instructor channels for this domain'
       where exists (select 1 from public.instructor_channel where domain_id = p_id::uuid)
      union all
      select (select count(*) from public.holiday where domain_id = p_id::uuid) || ' holidays'
       where exists (select 1 from public.holiday where domain_id = p_id::uuid)
      union all
      select (select count(*) from public.domain_team where domain_id = p_id::uuid) || ' team roles'
       where exists (select 1 from public.domain_team where domain_id = p_id::uuid)) q;
  elsif p_kind = 'cohort' then
    select name into v_name from public.cohort where id = p_id::uuid;
    v_weeks := array(select id from public.module_week where cohort_id = p_id::uuid);
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.class_pattern_item where cohort_id = p_id::uuid) || ' class times for this cohort' x
       where exists (select 1 from public.class_pattern_item where cohort_id = p_id::uuid)
      union all
      select 'Its own instructor order for ' || (select count(distinct module_id) from public.module_ranking where cohort_id = p_id::uuid) || ' modules'
       where exists (select 1 from public.module_ranking where cohort_id = p_id::uuid)) q;
  elsif p_kind = 'module' then
    select name into v_name from public.module where id = p_id::uuid;
    v_weeks := array(select id from public.module_week where module_id = p_id::uuid);
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.class_pattern_item where module_id = p_id::uuid) || ' class times' x
       where exists (select 1 from public.class_pattern_item where module_id = p_id::uuid)
      union all
      select (select count(*) from public.module_ranking where module_id = p_id::uuid) || ' places in its instructor order'
       where exists (select 1 from public.module_ranking where module_id = p_id::uuid)) q;
  elsif p_kind = 'class_week' then
    select m.name into v_name from public.module_week w join public.module m on m.id = w.module_id where w.id = p_id::uuid;
    v_weeks := array[p_id::uuid];
  elsif p_kind = 'instructor' then
    select full_name into v_name from public.instructor where id = p_id::uuid;
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.booking b join public.module_week w on w.id = b.module_week_id
               where b.instructor_id = p_id::uuid and b.status = 'Active'
                 and coalesce(w.last_class_end_at, w.first_class_at, 'infinity') > now())
             || ' confirmed class weeks still to come are released: they are told, and the next instructor is asked' x
       where exists (select 1 from public.booking b join public.module_week w on w.id = b.module_week_id
                      where b.instructor_id = p_id::uuid and b.status = 'Active'
                        and coalesce(w.last_class_end_at, w.first_class_at, 'infinity') > now())
      union all
      select (select count(*) from public.request where instructor_id = p_id::uuid and kind = 'Outreach'
               and status in ('Queued', 'Sent', 'Reminded'))
             || ' open requests are withdrawn: they are told, and the next instructor is asked'
       where exists (select 1 from public.request where instructor_id = p_id::uuid and kind = 'Outreach'
                      and status in ('Queued', 'Sent', 'Reminded'))
      union all
      select 'Removed from ' || (select count(*) from public.module_ranking where instructor_id = p_id::uuid)
             || ' instructor orders (the people after them move up)'
       where exists (select 1 from public.module_ranking where instructor_id = p_id::uuid)
      union all
      select (select count(*) from public.booking where instructor_id = p_id::uuid and status <> 'Active')
             || ' past or released bookings are removed from the records (Activity history keeps them)'
       where exists (select 1 from public.booking where instructor_id = p_id::uuid and status <> 'Active')) q;
  elsif p_kind = 'team_member' then
    select name, case
      when access_removed_at is not null then 'Their access was removed, so they stay on the Team page and cannot sign in again with this address. Give their access back first.'
      when auth_user_id is not null and auth_user_id = auth.uid() then 'You cannot delete yourself.'
    end into v_name, v_block from public.team_member where id = p_id::uuid;
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.module_owner where team_member_id = p_id::uuid)
             + (select count(*) from public.module_operations where team_member_id = p_id::uuid)
             + (select count(*) from public.domain_team where team_member_id = p_id::uuid)
             || ' roles on domains and modules are removed' x
       where exists (select 1 from public.module_owner where team_member_id = p_id::uuid)
          or exists (select 1 from public.module_operations where team_member_id = p_id::uuid)
          or exists (select 1 from public.domain_team where team_member_id = p_id::uuid)) q;
    if exists (select 1 from public.team_member where id = p_id::uuid and auth_user_id is not null) then
      v_info := jsonb_build_array('They can sign in again with a company account, which adds them back. To keep them out, use Remove access instead.');
    end if;
  elsif p_kind = 'discord_server' then
    select name into v_name from public.discord_server where id = p_id;
    select coalesce(jsonb_agg(x), '[]') into v_extra from (
      select (select count(*) from public.domain where discord_server_id = p_id) || ' domains no longer have a Discord server chosen' x
       where exists (select 1 from public.domain where discord_server_id = p_id)
      union all
      select (select count(*) from public.instructor_channel ic join public.discord_channel ch on ch.id = ic.channel_id
               where ch.server_id = p_id) || ' instructor channels in it are removed (those instructors get direct messages and email instead)'
       where exists (select 1 from public.instructor_channel ic join public.discord_channel ch on ch.id = ic.channel_id
                      where ch.server_id = p_id)) q;
    v_info := jsonb_build_array('The bot stays in the server. It comes back after Refresh servers unless you remove the bot in Discord.');
  else
    raise exception 'Unknown kind of item: %.', p_kind using errcode = '22023';
  end if;
  if v_name is null then raise exception 'This item no longer exists.' using errcode = '22023'; end if;
  if v_weeks is not null and cardinality(v_weeks) > 0 then
    v_e := private.week_effects(v_weeks);
    v_lines := private.effect_lines(v_e);
  end if;
  v_lines := v_extra || v_lines;
  -- Typing the name is asked when other data goes with the item (decision 255). For one class week: when
  -- someone is confirmed for it or being asked.
  v_needs := case when p_kind = 'class_week'
                  then coalesce((v_e ->> 'confirmed')::int, 0) + coalesce((v_e ->> 'asking')::int, 0) > 0
                  else jsonb_array_length(v_lines) > 0 end;
  return jsonb_build_object('name', v_name, 'lines', v_lines || v_info, 'needs_name', v_needs, 'blocked', v_block);
end;
$$;
grant execute on function public.delete_preview(text, text) to authenticated;

-- ------------------------------------------------------------------ the delete itself
create or replace function public.delete_item(p_kind text, p_id text, p_typed_name text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  p jsonb := public.delete_preview(p_kind, p_id);
  v_name text := p ->> 'name';
  v_before jsonb;
  v_domain uuid; v_module uuid; v_week uuid; v_cohort uuid; v_instr uuid;
  v_reason text;
begin
  if p ->> 'blocked' is not null then raise exception '%', p ->> 'blocked' using errcode = '42501'; end if;
  if (p ->> 'needs_name')::boolean and lower(trim(coalesce(p_typed_name, ''))) <> lower(trim(v_name)) then
    raise exception 'Type the name exactly as shown to delete it: %', v_name using errcode = '22023';
  end if;
  v_reason := 'Deleted: ' || v_name;
  -- One readable history entry for the whole delete (the rows below would each add their own).
  perform set_config('app.suppress_setup_log', 'on', true);
  if p_kind = 'domain' then
    select to_jsonb(d) into v_before from public.domain d where id = p_id::uuid;
    v_domain := p_id::uuid;
    v_before := v_before || jsonb_build_object(
      'modules', (select coalesce(jsonb_agg(name order by rotation_order), '[]') from public.module where domain_id = v_domain),
      'cohorts', (select coalesce(jsonb_agg(name order by name), '[]') from public.cohort where domain_id = v_domain));
    perform private.purge_domain(v_domain, v_reason);
    v_domain := null;
  elsif p_kind = 'cohort' then
    select to_jsonb(c), c.domain_id into v_before, v_domain from public.cohort c where id = p_id::uuid;
    perform private.purge_cohort(p_id::uuid, v_reason);
  elsif p_kind = 'module' then
    select to_jsonb(m), m.domain_id into v_before, v_domain from public.module m where id = p_id::uuid;
    perform private.purge_module(p_id::uuid, v_reason);
  elsif p_kind = 'class_week' then
    select to_jsonb(w) || jsonb_build_object('module', v_name, 'label', private.mw_label(w.id)), w.domain_id
      into v_before, v_domain from public.module_week w where id = p_id::uuid;
    v_name := v_before ->> 'label';
    perform private.purge_module_week(p_id::uuid, v_reason);
  elsif p_kind = 'instructor' then
    select to_jsonb(i) || jsonb_build_object('emails', (select coalesce(jsonb_agg(email), '[]') from public.instructor_email where instructor_id = i.id))
      into v_before from public.instructor i where id = p_id::uuid;
    perform private.purge_instructor(p_id::uuid, v_reason);
  elsif p_kind = 'team_member' then
    select to_jsonb(t) into v_before from public.team_member t where id = p_id::uuid;
    perform private.purge_team_member(p_id::uuid);
  elsif p_kind = 'discord_server' then
    select to_jsonb(s) into v_before from public.discord_server s where id = p_id;
    perform private.purge_discord_server(p_id);
  end if;
  perform set_config('app.suppress_setup_log', 'off', true);
  perform private.log_event(case when p_kind = 'class_week' then 'Team actions' else 'Setup changes' end,
    private.kind_label(p_kind) || ' deleted: ' || v_name,
    case p_kind when 'class_week' then 'module_week' when 'discord_server' then null else p_kind end,
    case when p_kind = 'discord_server' then null else p_id::uuid end,
    v_before, null, (select string_agg(x, '. ') from jsonb_array_elements_text(p -> 'lines') x),
    case when p_kind = 'domain' then null else v_domain end, null, null, null, null, null, false, null, v_name);
  return jsonb_build_object('deleted', true, 'name', v_name);
end;
$$;
grant execute on function public.delete_item(text, text, text) to authenticated;

-- ------------------------------------------------------------------ archive and restore
-- Domains, cohorts, modules and Discord servers. Instructors (Archive, Start using again), team members
-- (Remove access, Give access back) and class weeks (Cancel, Restore) have their own (decision 256).
create or replace function public.set_archived(p_kind text, p_id text, p_archived boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_name text; v_paused int := 0;
begin
  perform private.require_team();
  if p_kind = 'domain' then
    update public.domain set archived_at = case when p_archived then coalesce(archived_at, now()) end
     where id = p_id::uuid returning name into v_name;
  elsif p_kind = 'cohort' then
    update public.cohort set archived_at = case when p_archived then coalesce(archived_at, now()) end
     where id = p_id::uuid returning name into v_name;
  elsif p_kind = 'module' then
    update public.module set status = case when p_archived then 'Archived'
                                           when status = 'Archived' then 'Active' else status end
     where id = p_id::uuid returning name into v_name;
  elsif p_kind = 'discord_server' then
    update public.discord_server set archived_at = case when p_archived then coalesce(archived_at, now()) end
     where id = p_id returning name into v_name;
  else
    raise exception 'Unknown kind of item: %.', p_kind using errcode = '22023';
  end if;
  if v_name is null then raise exception 'This item no longer exists.' using errcode = '22023'; end if;
  -- A module's or cohort's class weeks stop (and start again) with it.
  if p_kind in ('cohort', 'module') then
    if p_archived then
      update public.module_week set paused = true, archive_paused = true
       where (case when p_kind = 'cohort' then cohort_id else module_id end) = p_id::uuid
         and not paused and status not in ('Cancelled', 'Completed');
      get diagnostics v_paused = row_count;
    else
      update public.module_week set paused = false, archive_paused = false
       where (case when p_kind = 'cohort' then cohort_id else module_id end) = p_id::uuid and archive_paused;
      get diagnostics v_paused = row_count;
    end if;
  end if;
  perform private.log_event('Setup changes',
    private.kind_label(p_kind) || case when p_archived then ' archived: ' else ' restored: ' end || v_name,
    case when p_kind = 'discord_server' then null else p_kind end,
    case when p_kind = 'discord_server' then null else p_id::uuid end,
    null, jsonb_build_object('archived', p_archived, 'class_weeks', v_paused), null,
    case p_kind when 'domain' then p_id::uuid
                when 'cohort' then (select domain_id from public.cohort where id = p_id::uuid)
                when 'module' then (select domain_id from public.module where id = p_id::uuid) end,
    case when p_kind = 'module' then p_id::uuid end, null, null, null, null, false,
    case when p_kind = 'cohort' then p_id::uuid end, v_name);
  return jsonb_build_object('name', v_name, 'class_weeks', v_paused);
end;
$$;
grant execute on function public.set_archived(text, text, boolean) to authenticated;

-- A cancelled class week can be planned again: its classes still to come come back, and the automation asks
-- for an instructor as for any new class week.
create or replace function public.restore_module_week(p_module_week_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare w public.module_week; v_n int;
begin
  perform private.require_team();
  select * into w from public.module_week where id = p_module_week_id for update;
  if w.id is null then raise exception 'This class week no longer exists.' using errcode = '22023'; end if;
  if w.status <> 'Cancelled' then raise exception 'Only a cancelled class week can be restored.' using errcode = '22023'; end if;
  update public.class_session set status = 'Planned', cancelled_reason = null
   where module_week_id = w.id and status = 'Cancelled' and starts_at > now();
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Every class of this week has already passed, so it cannot be planned again.' using errcode = '22023'; end if;
  update public.module_week set status = 'Planned', at_risk = false where id = w.id;
  perform private.log_event('Team actions', 'Class week restored', 'module_week', w.id, null,
    jsonb_build_object('classes', v_n), null, w.domain_id, w.module_id, w.id, null, null, null, false, w.cohort_id,
    private.mw_label(w.id));
  return jsonb_build_object('classes', v_n);
end;
$$;
grant execute on function public.restore_module_week(uuid) to authenticated;

create or replace function public.engine_tick_all(p_now timestamptz default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  d record;
  v jsonb := '[]';
  v_res jsonb;
  v_err text;
  v_errors int := 0;
begin
  perform private.require_team();
  for d in select * from public.domain where status in ('Test', 'Live', 'Paused') and archived_at is null order by name loop
    begin
      v_res := public.engine_tick(d.id, p_now);
      v := v || v_res;
    exception when others then
      get stacked diagnostics v_err = message_text;
      v_errors := v_errors + 1;
      v := v || jsonb_build_object('domain', d.name, 'error', v_err);
      perform private.set_actor('System', null, 'System');
      perform private.log_event('System', 'Hourly check failed: ' || d.name, 'domain', d.id, null, null, v_err, d.id);
      perform private.queue_team_message('T14', d.id, 'admin', null, '{}', 'Hourly check failed: ' || d.name,
        '❗ Hourly check failed for ' || d.name || ': ' || v_err, 'T14:tick:' || d.id || ':' || to_char(now(), 'YYYYMMDDHH24'), now());
    end;
  end loop;
  perform private.set_actor('System', null, 'System');
  perform private.send_digests(coalesce(p_now, now()));
  perform private.step_release(null, coalesce(p_now, now()));
  update public.system_state
     set last_hourly_run_at = now(), last_hourly_status = case when v_errors = 0 then 'ok' else v_errors || ' error(s)' end,
         last_hourly_summary = v
   where id = 1;
  return jsonb_build_object('domains', v, 'errors', v_errors);
end;
$$;
create or replace function public.claim_outbound_messages(p_limit int default 25)
returns setof public.message language plpgsql security definer set search_path = ''
as $$
declare v_stuck uuid;
begin
  perform private.require_team();
  -- OUT-2: drop what should no longer go out before handing messages to n8n.
  perform private.cancel_stale_messages();
  -- DIS-13: never send again what may already have arrived (Discord only drops a repeated nonce for a
  -- few minutes, and Gmail never does). It fails like any other message, with a task to check.
  for v_stuck in select id from public.message where status = 'Sending' and claimed_at < now() - interval '15 minutes' loop
    perform public.report_message_result(v_stuck,
      false, null,
      'The automation took this message but never said whether it was sent, so it may or may not have arrived. Check, and send it again if it did not.',
      true);
  end loop;
  return query
  with c as (
    select m.id from public.message m left join public.domain d on d.id = m.domain_id
     where m.status = 'Pending' and m.direction = 'Outbound'
       and (m.audience <> 'Instructor'
            or ((select s.outreach_enabled from public.system_state s where s.id = 1)
                and coalesce(d.status, 'Live') <> 'Paused' and d.archived_at is null))
     order by m.created_at
     limit greatest(1, least(p_limit, 100))
     for update of m skip locked),
  u as (
    update public.message m set status = 'Sending', claimed_at = now(), attempts = m.attempts + 1
      from c where m.id = c.id
    returning m.*)
  select (jsonb_populate_record(null::public.message, to_jsonb(u) || jsonb_build_object(
           'body_text', private.with_tokens(u.body_text, u.instructor_id, u.team_member_id, u.is_test),
           'body_html', private.with_tokens(u.body_html, u.instructor_id, u.team_member_id, u.is_test),
           'buttons', private.with_tokens(u.buttons::text, u.instructor_id, u.team_member_id, u.is_test)::jsonb))).*
    from u;
end;
$$;
create or replace function public.get_started()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select case when private.is_team_user() then jsonb_build_array(
    jsonb_build_object('key', 'domain', 'label', 'Add a domain', 'link', '/setup/domains',
      'done', exists (select 1 from public.domain where archived_at is null)),
    jsonb_build_object('key', 'discord', 'label', 'Choose its Discord server', 'link', '/settings/connections',
      'done', exists (select 1 from public.domain where archived_at is null and discord_server_id is not null)),
    jsonb_build_object('key', 'team', 'label', 'Add team members', 'link', '/setup/team',
      'done', exists (select 1 from public.domain_team)
              or (select count(*) from public.team_member where active and access_removed_at is null) > 1),
    jsonb_build_object('key', 'instructors', 'label', 'Add instructors', 'link', '/setup/instructors',
      'done', exists (select 1 from public.instructor where status = 'Active')),
    jsonb_build_object('key', 'modules', 'label', 'Add modules', 'link', '/setup/modules',
      'done', exists (select 1 from public.module where status = 'Active')),
    jsonb_build_object('key', 'cohort', 'label', 'Create a cohort', 'link', '/setup/domains',
      'done', exists (select 1 from public.cohort where archived_at is null)),
    jsonb_build_object('key', 'classes', 'label', 'Plan classes', 'link', '/classes',
      'done', exists (select 1 from public.module_week))
  ) else '[]'::jsonb end;
$$;
