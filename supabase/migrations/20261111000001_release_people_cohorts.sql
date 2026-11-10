-- Release Milestone 2, part 1: data model for people and ownership, cohorts, flexible classes,
-- class types, instructor preferences and settings layers. Existing data is moved over.
-- Decisions 81 to 87 and the architecture in docs/RELEASE_PLAN.md section 2.

-- -------------------------------------------------------------------------------------
-- People and ownership
-- -------------------------------------------------------------------------------------
-- The single role label is replaced by assignments; a job title is shown only.
alter table public.team_member add column job_title text;
update public.team_member set job_title = case label when 'PM' then 'Product manager' when 'Lead' then 'Lead' else 'Operations' end
 where job_title is null;
alter table public.team_member drop column label;

-- Domain assignments: escalation contacts (were "leads") and the default operations team.
alter table public.domain_team drop constraint domain_team_role_check;
update public.domain_team set role = case role when 'Lead' then 'Escalation' when 'Ops' then 'Operations' else role end;
alter table public.domain_team add constraint domain_team_role_check check (role in ('Escalation', 'Operations'));

-- -------------------------------------------------------------------------------------
-- Cohorts
-- -------------------------------------------------------------------------------------
create table public.cohort (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  start_date date,
  status text not null default 'Planned' check (status in ('Planned', 'Running', 'Finished')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index cohort_name_per_domain_uq on public.cohort (domain_id, lower(name));

alter table public.module_week add column cohort_id uuid references public.cohort (id) on delete restrict;
insert into public.cohort (domain_id, name, start_date, status)
select w.domain_id, coalesce(nullif(trim(w.cohort), ''), 'Main cohort'), min(w.week_start_date), 'Running'
  from public.module_week w group by 1, 2;
update public.module_week w set cohort_id = c.id
  from public.cohort c
 where c.domain_id = w.domain_id and lower(c.name) = lower(coalesce(nullif(trim(w.cohort), ''), 'Main cohort'));

-- Operations team per module (and per cohort); the domain default is used when a module has none.
create table public.module_operations (
  id uuid primary key default gen_random_uuid(),
  module_id uuid not null references public.module (id) on delete cascade,
  cohort_id uuid references public.cohort (id) on delete cascade,
  team_member_id uuid not null references public.team_member (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index module_operations_uq on public.module_operations
  (module_id, coalesce(cohort_id, '00000000-0000-0000-0000-000000000000'::uuid), team_member_id);

-- -------------------------------------------------------------------------------------
-- Flexible classes
-- -------------------------------------------------------------------------------------
-- Class types are an editable list per domain.
create table public.class_type (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index class_type_name_uq on public.class_type (domain_id, lower(name));

alter table public.class_pattern_item drop constraint class_pattern_item_class_type_check;
alter table public.class_session drop constraint class_session_class_type_check;
alter table public.class_pattern_item add constraint class_pattern_item_class_type_check check (length(trim(class_type)) > 0);
alter table public.class_session add constraint class_session_class_type_check check (length(trim(class_type)) > 0);

insert into public.class_type (domain_id, name, sort_order)
select d.id, t.name, t.ord from public.domain d
 cross join (values ('Live class', 1), ('Assignment review', 2), ('Office hours', 3), ('Other', 4)) t(name, ord);
insert into public.class_type (domain_id, name, sort_order)
select distinct m.domain_id, p.class_type, 10 from public.class_pattern_item p join public.module m on m.id = p.module_id
on conflict do nothing;

-- A pattern is "days after the first class" (any weekday), optionally for one cohort.
alter table public.class_pattern_item rename column weekday_offset to day_offset;
alter table public.class_pattern_item add column cohort_id uuid references public.cohort (id) on delete cascade;
alter table public.class_pattern_item alter column title_template set default '{module}: {class_type}';
update public.class_pattern_item p set day_offset = p.day_offset - m.min_off
  from (select module_id, min(day_offset) as min_off from public.class_pattern_item group by module_id) m
 where m.module_id = p.module_id and m.min_off > 0;

-- Class weeks: cohort required; "same instructor" per class week; a class week starts on its first class.
alter table public.module_week add column same_instructor boolean;
update public.module_week w set same_instructor = m.same_instructor_for_module_week from public.module m where m.id = w.module_id;
alter table public.module_week alter column same_instructor set not null;
alter table public.module_week add column seq int not null default 1 check (seq >= 1);
alter table public.module_week add column split_group uuid;
alter table public.module_week alter column cohort_id set not null;
drop index public.module_week_uq;
create unique index module_week_uq on public.module_week (module_id, cohort_id, week_start_date, seq);
create index module_week_cohort_idx on public.module_week (cohort_id, first_class_at);

-- The cohort name is kept on the class week as a read only copy (and accepted as input).
create or replace function private.module_week_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_name text;
begin
  new.domain_id := (select m.domain_id from public.module m where m.id = new.module_id);
  if new.cohort_id is null or (tg_op = 'UPDATE' and new.cohort is distinct from old.cohort and new.cohort_id = old.cohort_id) then
    v_name := coalesce(nullif(trim(new.cohort), ''), 'Main cohort');
    select c.id into new.cohort_id from public.cohort c where c.domain_id = new.domain_id and lower(c.name) = lower(v_name);
    if new.cohort_id is null then
      insert into public.cohort (domain_id, name, start_date) values (new.domain_id, v_name, new.week_start_date)
      returning id into new.cohort_id;
    end if;
  end if;
  select c.name into new.cohort from public.cohort c where c.id = new.cohort_id;
  if (select c.domain_id from public.cohort c where c.id = new.cohort_id) <> new.domain_id then
    raise exception 'The cohort belongs to another domain.' using errcode = '22023';
  end if;
  if tg_op = 'INSERT' and new.same_instructor is null then
    new.same_instructor := coalesce((select m.same_instructor_for_module_week from public.module m where m.id = new.module_id), true);
  end if;
  return new;
end;
$$;
drop trigger if exists module_week_before_write on public.module_week;
create trigger module_week_before_write before insert or update of module_id, cohort, cohort_id on public.module_week
  for each row execute function private.module_week_before_write();
-- Renaming a cohort updates the copy on its class weeks.
create or replace function private.cohort_after_update()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.name is distinct from old.name then
    update public.module_week set cohort = new.name where cohort_id = new.id;
  end if;
  return new;
end;
$$;
create trigger cohort_after_update after update of name on public.cohort
  for each row execute function private.cohort_after_update();

-- New domains get the default class types.
create or replace function private.domain_after_insert_defaults()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.class_type (domain_id, name, sort_order)
  values (new.id, 'Live class', 1), (new.id, 'Assignment review', 2), (new.id, 'Office hours', 3), (new.id, 'Other', 4)
  on conflict do nothing;
  return new;
end;
$$;
create trigger domain_after_insert_defaults after insert on public.domain
  for each row execute function private.domain_after_insert_defaults();

-- -------------------------------------------------------------------------------------
-- Instructor order: per module, optionally per cohort; exactly one Primary, then Backups 1..N
-- -------------------------------------------------------------------------------------
alter table public.module_ranking add column cohort_id uuid references public.cohort (id) on delete cascade;
alter table public.module_ranking drop constraint module_ranking_rank_uq;
alter table public.module_ranking drop constraint module_ranking_module_id_instructor_id_key;
create unique index module_ranking_instructor_uq on public.module_ranking
  (module_id, coalesce(cohort_id, '00000000-0000-0000-0000-000000000000'::uuid), instructor_id);
create unique index module_ranking_rank_uq on public.module_ranking
  (module_id, coalesce(cohort_id, '00000000-0000-0000-0000-000000000000'::uuid), rank);

-- Checked when the transaction commits: ranks are 1, 2, 3 … with no gaps, so there is exactly one Primary.
create or replace function private.check_instructor_order()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_mod uuid := coalesce(new.module_id, old.module_id); v_coh uuid := case when tg_op = 'DELETE' then old.cohort_id else new.cohort_id end;
begin
  if exists (select 1 from public.module where id = v_mod)
     and exists (
       select 1 from (select rank, row_number() over (order by rank) as n from public.module_ranking
                       where module_id = v_mod and cohort_id is not distinct from v_coh) x
        where x.rank <> x.n) then
    raise exception 'The instructor order must have one Primary instructor and then Backups numbered without gaps.'
      using errcode = '23514';
  end if;
  return null;
end;
$$;
create constraint trigger module_ranking_order_check after insert or update or delete on public.module_ranking
  deferrable initially deferred for each row execute function private.check_instructor_order();

-- -------------------------------------------------------------------------------------
-- Instructor preferences; test instructors may share a Discord user ID
-- -------------------------------------------------------------------------------------
alter table public.instructor add column preferred_contact text not null default 'Both'
  check (preferred_contact in ('Discord', 'Email', 'Both'));
alter table public.instructor add column monthly_class_limit int check (monthly_class_limit between 1 and 100);
drop index public.instructor_discord_uq;
create unique index instructor_discord_uq on public.instructor (discord_user_id) where discord_user_id is not null and not is_test;

-- Duplicate check: real instructors keep unique emails and Discord IDs; test instructors may share a
-- Discord user ID (one person testing as several instructors) and use plus addresses.
create or replace function private.instructor_duplicate_name(p_id uuid, p_email text, p_discord text, p_is_test boolean)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select i.full_name from public.instructor_email e join public.instructor i on i.id = e.instructor_id
      where lower(e.email) = lower(p_email) and e.instructor_id <> p_id limit 1),
    (select i.full_name from public.instructor i
      where p_discord is not null and i.discord_user_id = p_discord and i.id <> p_id
        and not (p_is_test and i.is_test) limit 1));
$$;

-- -------------------------------------------------------------------------------------
-- Settings layers: Global, Domain, Cohort, Module, single class week
-- -------------------------------------------------------------------------------------
alter table public.setting drop constraint setting_check;
alter table public.setting drop constraint setting_scope_check;
alter table public.setting add column cohort_id uuid references public.cohort (id) on delete cascade;
alter table public.setting add column module_id uuid references public.module (id) on delete cascade;
alter table public.setting add column module_week_id uuid references public.module_week (id) on delete cascade;
alter table public.setting add column reason text;
alter table public.setting add constraint setting_scope_check check (scope in ('Global', 'Domain', 'Cohort', 'Module', 'ModuleWeek'));
alter table public.setting add constraint setting_scope_ids check (
  case scope
    when 'Global' then domain_id is null and cohort_id is null and module_id is null and module_week_id is null
    when 'Domain' then domain_id is not null and cohort_id is null and module_id is null and module_week_id is null
    when 'Cohort' then cohort_id is not null and module_id is null and module_week_id is null
    when 'Module' then module_id is not null and cohort_id is null and module_week_id is null
    when 'ModuleWeek' then module_week_id is not null and cohort_id is null and module_id is null
  end);
drop index public.setting_scope_uq;
create unique index setting_scope_uq on public.setting (key, scope,
  coalesce(module_week_id, module_id, cohort_id, domain_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- -------------------------------------------------------------------------------------
-- Wiring for the new tables: version/updated_at, setup history, row level security
-- -------------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['cohort', 'module_operations', 'class_type'] loop
    execute format('create trigger %I before update on public.%I for each row execute function private.touch_row()', t || '_touch', t);
    execute format('create trigger %I before insert on public.%I for each row execute function private.set_created_by()', t || '_created_by', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function private.log_setup_change()', t || '_history', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (private.is_team_user())', t || '_team_read', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (private.is_team_user())', t || '_team_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (private.is_team_user()) with check (private.is_team_user())', t || '_team_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (private.is_team_user())', t || '_team_delete', t);
  end loop;
end;
$$;

-- Realtime: the app refreshes when cohorts or assignments change.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.cohort, public.module_operations, public.class_type;
  end if;
exception when others then null;
end;
$$;
