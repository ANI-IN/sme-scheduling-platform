-- =====================================================================================
-- Milestone 1 — Database foundation
-- Tables (PRD §6.1), rules the database enforces (§6.2), settings (§16), history (§7.9).
-- Nothing here refers to a specific domain, module or instructor: those are data.
-- =====================================================================================

create extension if not exists btree_gist with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pgtap with schema extensions;

create schema if not exists private;
grant usage on schema private to authenticated, service_role;

-- Lock down function execution: nothing is callable by anon; we grant per function.
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated, service_role;
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema private revoke all on functions from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke all on tables from anon;

-- -------------------------------------------------------------------------------------
-- Singletons: configuration and global switches
-- -------------------------------------------------------------------------------------
create table public.app_config (
  id int primary key default 1 check (id = 1),
  company_email_domain text not null default '' check (company_email_domain = lower(company_email_domain)),
  discord_guild_id text check (discord_guild_id ~ '^\d{17,20}$'),
  response_base_url text,          -- WF2 webhook URL, e.g. https://n8n.example.com/webhook/respond
  app_base_url text,               -- web app URL, used for links in team messages
  admin_discord_channel_id text check (admin_discord_channel_id ~ '^\d{17,20}$'),
  scheduling_email text,
  scheduling_sender_name text not null default 'SME Scheduling',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
insert into public.app_config (id) values (1);

create table public.system_state (
  id int primary key default 1 check (id = 1),
  outreach_enabled boolean not null default true,     -- false = kill switch on
  kill_switch_changed_at timestamptz,
  kill_switch_changed_by uuid,
  last_hourly_run_at timestamptz,
  last_hourly_status text,
  last_hourly_summary jsonb,
  last_daily_run_at timestamptz,
  last_heartbeat_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
insert into public.system_state (id) values (1);

-- -------------------------------------------------------------------------------------
-- People and domains
-- -------------------------------------------------------------------------------------
create table public.team_member (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  email text not null,
  discord_user_id text check (discord_user_id ~ '^\d{17,20}$'),
  label text not null default 'Ops' check (label in ('Ops', 'PM', 'Lead')),
  receives_digest boolean not null default true,
  digest_channel text not null default 'Discord' check (digest_channel in ('Discord', 'Email', 'Both')),
  active boolean not null default true,
  is_placeholder boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index team_member_email_uq on public.team_member (lower(email));
create unique index team_member_discord_uq on public.team_member (discord_user_id) where discord_user_id is not null;

create table public.domain (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  status text not null default 'Draft' check (status in ('Draft', 'Test', 'Live', 'Paused')),
  alert_discord_channel_id text check (alert_discord_channel_id ~ '^\d{17,20}$'),
  test_discord_channel_id text check (test_discord_channel_id ~ '^\d{17,20}$'),
  test_email text,
  test_clock_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  constraint domain_test_mode_needs_targets check (
    status <> 'Test' or (test_discord_channel_id is not null and coalesce(test_email, '') <> '')
  )
);
create unique index domain_name_uq on public.domain (lower(name));

create table public.domain_team (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete cascade,
  team_member_id uuid not null references public.team_member (id) on delete restrict,
  role text not null check (role in ('Lead', 'Ops')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (domain_id, team_member_id, role)
);

-- -------------------------------------------------------------------------------------
-- Modules
-- -------------------------------------------------------------------------------------
create table public.module (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  rotation_order int not null default 1 check (rotation_order >= 1),
  status text not null default 'Active' check (status in ('Active', 'Inactive', 'Archived')),
  same_instructor_for_module_week boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index module_name_per_domain_uq on public.module (domain_id, lower(name));

create table public.module_owner (
  id uuid primary key default gen_random_uuid(),
  module_id uuid not null references public.module (id) on delete cascade,
  team_member_id uuid not null references public.team_member (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (module_id, team_member_id)
);

create table public.module_resource (
  id uuid primary key default gen_random_uuid(),
  module_id uuid not null references public.module (id) on delete cascade,
  title text not null check (length(trim(title)) > 0),
  url text not null check (url ~* '^https?://'),
  include_in_confirmation boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);

create table public.class_pattern_item (
  id uuid primary key default gen_random_uuid(),
  module_id uuid not null references public.module (id) on delete cascade,
  class_type text not null check (class_type in ('Live class', 'Assignment review', 'Other')),
  title_template text not null default '{module} — {class_type}',
  weekday_offset int not null check (weekday_offset between 0 and 13),
  start_time_pt time not null,
  duration_minutes int not null check (duration_minutes between 15 and 720),
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);

-- -------------------------------------------------------------------------------------
-- Instructors
-- -------------------------------------------------------------------------------------
create table public.instructor (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (length(trim(full_name)) > 0),
  primary_email text not null check (primary_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  discord_user_id text check (discord_user_id ~ '^\d{17,20}$'),
  discord_server_id text check (discord_server_id ~ '^\d{17,20}$'),
  discord_channel_id text check (discord_channel_id ~ '^\d{17,20}$'),
  discord_channel_link text,
  phone text,
  notes text,
  status text not null default 'Active' check (status in ('Active', 'Inactive', 'Archived')),
  verified_at timestamptz,
  is_test boolean not null default false,
  email_bounced_at timestamptz,
  discord_failed_at timestamptz,
  last_response_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index instructor_discord_uq on public.instructor (discord_user_id) where discord_user_id is not null;
create unique index instructor_primary_email_uq on public.instructor (lower(primary_email));

create table public.instructor_email (
  id uuid primary key default gen_random_uuid(),
  instructor_id uuid not null references public.instructor (id) on delete cascade,
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
-- An email belongs to one instructor only (primary or extra, across all instructors).
create unique index instructor_email_uq on public.instructor_email (lower(email));
create unique index instructor_email_one_primary on public.instructor_email (instructor_id) where is_primary;

create table public.instructor_unavailability (
  id uuid primary key default gen_random_uuid(),
  instructor_id uuid not null references public.instructor (id) on delete cascade,
  from_date date not null,
  to_date date not null,
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  check (from_date <= to_date)
);

create table public.module_ranking (
  id uuid primary key default gen_random_uuid(),
  module_id uuid not null references public.module (id) on delete cascade,
  instructor_id uuid not null references public.instructor (id) on delete restrict,
  rank int not null check (rank >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (module_id, instructor_id),
  constraint module_ranking_rank_uq unique (module_id, rank) deferrable initially deferred
);

-- -------------------------------------------------------------------------------------
-- Schedule
-- -------------------------------------------------------------------------------------
create table public.module_week (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid not null references public.domain (id) on delete restrict,
  module_id uuid not null references public.module (id) on delete restrict,
  cohort text not null default '',
  week_start_date date not null,
  outreach_mode text not null default 'Sequential' check (outreach_mode in ('Sequential', 'Manual')),
  manual_end_behaviour text not null default 'Stop' check (manual_end_behaviour in ('Stop', 'ContinueWithRanking')),
  status text not null default 'Planned' check (status in (
    'Planned', 'NotReady', 'Ready', 'Asking', 'Confirmed', 'Completed', 'NeedsInstructor', 'Cancelled')),
  at_risk boolean not null default false,
  at_risk_reason text,
  paused boolean not null default false,
  time_version int not null default 1,
  first_class_at timestamptz,
  last_class_end_at timestamptz,
  readiness_problems jsonb,
  readiness_checked_at timestamptz,
  readiness_escalated_at timestamptz,
  outreach_started_at timestamptz,
  owner_checkin_sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
-- No duplicate module weeks.
create unique index module_week_uq on public.module_week (module_id, week_start_date, cohort);
create index module_week_domain_first_idx on public.module_week (domain_id, first_class_at);

create table public.manual_queue_item (
  id uuid primary key default gen_random_uuid(),
  module_week_id uuid not null references public.module_week (id) on delete cascade,
  instructor_id uuid not null references public.instructor (id) on delete restrict,
  position int not null,
  asked_request_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (module_week_id, position)
);

create table public.class_session (
  id uuid primary key default gen_random_uuid(),
  module_week_id uuid not null references public.module_week (id) on delete restrict,
  pattern_item_id uuid references public.class_pattern_item (id) on delete set null,
  class_type text not null check (class_type in ('Live class', 'Assignment review', 'Other')),
  title text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'Planned' check (status in ('Planned', 'Cancelled', 'Completed')),
  problem_flag boolean not null default false,
  cancelled_reason text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  check (ends_at > starts_at)
);
create index class_session_mw_idx on public.class_session (module_week_id);
create index class_session_starts_idx on public.class_session (starts_at);

-- -------------------------------------------------------------------------------------
-- Outreach, bookings
-- -------------------------------------------------------------------------------------
create table public.request (
  id uuid primary key default gen_random_uuid(),
  module_week_id uuid references public.module_week (id) on delete restrict,
  instructor_id uuid references public.instructor (id) on delete restrict,
  team_member_id uuid references public.team_member (id) on delete restrict,
  booking_id uuid,
  kind text not null check (kind in ('Outreach', 'TimeChange', 'CheckIn', 'OwnerCheckIn', 'Test')),
  check_in_days int,
  status text not null default 'Queued' check (status in (
    'Queued', 'Sent', 'Reminded', 'Accepted', 'Declined', 'Expired', 'Withdrawn', 'Superseded', 'Failed')),
  answer text,
  close_reason text,
  time_version int not null default 1,
  line_source text,                 -- 'Ranking' / 'Manual'
  declined_before boolean not null default false,
  sent_at timestamptz,
  reminder_at timestamptz,
  reminded_at timestamptz,
  deadline_at timestamptz,
  answered_at timestamptz,
  is_test boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  check (instructor_id is not null or team_member_id is not null)
);
-- A module week has at most one open outreach request (and one open time-change request).
create unique index request_one_open_outreach on public.request (module_week_id)
  where kind = 'Outreach' and status in ('Queued', 'Sent', 'Reminded');
create unique index request_one_open_timechange on public.request (module_week_id)
  where kind = 'TimeChange' and status in ('Queued', 'Sent', 'Reminded');
create unique index request_checkin_once on public.request (booking_id, check_in_days)
  where kind = 'CheckIn';
create unique index request_owner_checkin_once on public.request (module_week_id, team_member_id)
  where kind = 'OwnerCheckIn';
create index request_mw_idx on public.request (module_week_id, kind, status);
create index request_instructor_idx on public.request (instructor_id);

create table public.response_link (
  token text primary key,
  request_id uuid not null references public.request (id) on delete cascade,
  answer text not null,
  used_at timestamptz,
  opened_at timestamptz,
  created_at timestamptz not null default now(),
  unique (request_id, answer)
);

create table public.booking (
  id uuid primary key default gen_random_uuid(),
  module_week_id uuid not null references public.module_week (id) on delete restrict,
  instructor_id uuid not null references public.instructor (id) on delete restrict,
  request_id uuid references public.request (id) on delete set null,
  status text not null default 'Active' check (status in ('Active', 'Released', 'Cancelled', 'Completed')),
  confirmed_via text not null check (confirmed_via in ('Instructor', 'Manual', 'Offline')),
  confirmed_at timestamptz not null default now(),
  confirmed_by uuid,
  time_version_confirmed int not null default 1,
  released_at timestamptz,
  release_reason text,
  is_test boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
-- A module week has at most one active booking.
create unique index booking_one_active_per_week on public.booking (module_week_id) where status = 'Active';
create index booking_instructor_idx on public.booking (instructor_id, status);

alter table public.request
  add constraint request_booking_fk foreign key (booking_id) references public.booking (id) on delete restrict;

create table public.booking_slot (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.booking (id) on delete cascade,
  class_id uuid not null references public.class_session (id) on delete restrict,
  instructor_id uuid not null references public.instructor (id) on delete restrict,
  time_range tstzrange not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (booking_id, class_id),
  -- No instructor has two overlapping active bookings, in any domain.
  constraint booking_slot_no_overlap exclude using gist (
    instructor_id extensions.gist_uuid_ops with =,
    time_range with &&
  ) where (active)
);

create table public.checklist_item (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.class_session (id) on delete cascade,
  booking_id uuid references public.booking (id) on delete set null,
  label text not null,
  done boolean not null default false,
  done_by uuid,
  done_at timestamptz,
  due_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  unique (class_id, label)
);

-- -------------------------------------------------------------------------------------
-- Help, attention, reminders, messages
-- -------------------------------------------------------------------------------------
create table public.help_request (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid references public.domain (id) on delete restrict,
  module_week_id uuid references public.module_week (id) on delete restrict,
  booking_id uuid references public.booking (id) on delete set null,
  requester_instructor_id uuid references public.instructor (id) on delete restrict,
  requester_team_member_id uuid references public.team_member (id) on delete restrict,
  source text not null check (source in ('Instructor', 'Owner', 'Ops')),
  categories text[] not null default '{}',
  details text check (length(details) <= 1000),
  urgency text not null default 'NoRush' check (urgency in ('NoRush', 'Within24h', 'Urgent')),
  reply_channel text not null default 'Either' check (reply_channel in ('Discord', 'Email', 'Either')),
  routed_to uuid[] not null default '{}',
  assigned_to uuid references public.team_member (id) on delete set null,
  status text not null default 'Open' check (status in (
    'Open', 'InProgress', 'WaitingOnInstructor', 'Resolved', 'Closed', 'ConvertedToCancellation')),
  severity text not null default 'Normal' check (severity in ('Normal', 'Urgent')),
  response_target_at timestamptz,
  first_response_at timestamptz,
  half_reminder_at timestamptz,
  escalated_at timestamptz,
  resolved_at timestamptz,
  resolution_note text,
  merged_into uuid references public.help_request (id),
  is_test boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);

create table public.attention_item (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid references public.domain (id) on delete restrict,
  type text not null check (type in (
    'RankingExhausted', 'ClassAtRisk', 'TypedReply', 'HelpRequest', 'ReadinessFailed',
    'ChecklistOverdue', 'MessageFailed', 'LateReply', 'ScheduleLow', 'TimeChangeNotConfirmed',
    'CheckInNoReply', 'ThinBench', 'UnverifiedInRanking', 'OwnerCheckIn', 'Other')),
  severity text not null default 'Normal' check (severity in ('Normal', 'Urgent')),
  status text not null default 'Open' check (status in ('Open', 'Acknowledged', 'Done')),
  title text not null,
  detail text,
  module_id uuid references public.module (id),
  module_week_id uuid references public.module_week (id),
  class_id uuid references public.class_session (id),
  instructor_id uuid references public.instructor (id),
  request_id uuid references public.request (id),
  help_request_id uuid references public.help_request (id),
  message_id uuid,
  recipients uuid[] not null default '{}',
  assigned_to uuid references public.team_member (id) on delete set null,
  dedupe_key text,
  due_at timestamptz,
  ack_until timestamptz,
  acknowledged_by uuid,
  r1_at timestamptz,
  last_reminder_at timestamptz,
  escalated_at timestamptz,
  done_by uuid,
  done_at timestamptz,
  done_note text,
  is_test boolean not null default false,
  opened_at timestamptz not null default now(),   -- engine "now" when raised (test clock aware)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
create unique index attention_dedupe_open on public.attention_item (dedupe_key) where status <> 'Done' and dedupe_key is not null;
create index attention_status_idx on public.attention_item (status, severity);

create table public.message (
  id uuid primary key default gen_random_uuid(),
  domain_id uuid references public.domain (id) on delete restrict,
  direction text not null default 'Outbound' check (direction in ('Outbound', 'Inbound')),
  audience text not null check (audience in ('Instructor', 'Team', 'Admin')),
  template_id text not null,
  channel text not null check (channel in ('Discord', 'Email')),
  unique_key text,
  status text not null default 'Pending' check (status in (
    'Scheduled', 'Pending', 'Sending', 'Sent', 'Failed', 'Received', 'Cancelled')),
  not_before timestamptz,
  instructor_id uuid references public.instructor (id),
  team_member_id uuid references public.team_member (id),
  module_week_id uuid references public.module_week (id),
  request_id uuid references public.request (id),
  help_request_id uuid references public.help_request (id),
  attention_item_id uuid references public.attention_item (id),
  recipient_label text,
  to_address text,
  discord_channel_id text,
  discord_dm_user_id text,
  mention_user_ids text[] not null default '{}',
  subject text,
  body_text text,
  body_html text,
  buttons jsonb not null default '[]',
  attempts int not null default 0,
  last_error text,
  claimed_at timestamptz,
  sent_at timestamptz,
  external_id text,
  in_reply_to text,
  from_address text,
  summary text,
  is_test boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);
-- The same message is never sent twice.
create unique index message_unique_key on public.message (unique_key) where unique_key is not null;
create index message_status_idx on public.message (status, not_before);
create index message_mw_idx on public.message (module_week_id);

alter table public.attention_item
  add constraint attention_message_fk foreign key (message_id) references public.message (id);

create table public.reminder (
  id uuid primary key default gen_random_uuid(),
  attention_item_id uuid not null references public.attention_item (id) on delete cascade,
  recipient uuid references public.team_member (id),
  level text not null check (level in ('R1', 'R2', 'Escalation')),
  sent_at timestamptz not null default now(),
  message_id uuid references public.message (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);

-- -------------------------------------------------------------------------------------
-- History (append-only)
-- -------------------------------------------------------------------------------------
create table public.history_event (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  sim_at timestamptz,                         -- engine "now" (test clock) when different from at
  actor_kind text not null check (actor_kind in ('TeamMember', 'Instructor', 'System')),
  actor_team_member_id uuid,
  actor_instructor_id uuid,
  actor_label text,
  category text not null check (category in (
    'Messages', 'Instructor responses', 'Bookings', 'Team actions', 'Setup changes',
    'Help requests', 'Reminders', 'System')),
  action text not null,
  entity_table text,
  entity_id uuid,
  domain_id uuid,
  module_id uuid,
  module_week_id uuid,
  class_id uuid,
  instructor_id uuid,
  before jsonb,
  after jsonb,
  note text,
  undo_of bigint references public.history_event (id),
  is_test boolean not null default false
);
create index history_at_idx on public.history_event (at desc);
create index history_entity_idx on public.history_event (entity_table, entity_id);
create index history_mw_idx on public.history_event (module_week_id);
create unique index history_one_undo on public.history_event (undo_of) where undo_of is not null;

-- -------------------------------------------------------------------------------------
-- Settings, holidays, action queue, discord cursors
-- -------------------------------------------------------------------------------------
create table public.setting_definition (
  key text primary key,
  group_name text not null,
  label text not null,
  value_type text not null check (value_type in ('int', 'bool', 'enum', 'time', 'int_list', 'text_list', 'json')),
  default_value jsonb not null,
  min_value int,
  max_value int,
  allowed jsonb,
  help text,
  sort_order int not null default 0
);

create table public.setting (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('Global', 'Domain')),
  domain_id uuid references public.domain (id) on delete cascade,
  key text not null references public.setting_definition (key),
  value jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1,
  check ((scope = 'Global') = (domain_id is null))
);
create unique index setting_scope_uq on public.setting (key, coalesce(domain_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table public.holiday (
  id uuid primary key default gen_random_uuid(),
  date date not null unique,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);

create table public.action_queue (
  id uuid primary key default gen_random_uuid(),
  action text not null check (action in ('deliver', 'run_check_now', 'send_test_alert')),
  payload jsonb not null default '{}',
  status text not null default 'Queued' check (status in ('Queued', 'Processing', 'Done', 'Failed')),
  requested_by uuid,
  result jsonb,
  error text,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version int not null default 1
);

create table public.discord_cursor (
  channel_id text primary key,
  last_message_id text,
  updated_at timestamptz not null default now()
);

-- =====================================================================================
-- Helper functions (schema private, not exposed through the API)
-- =====================================================================================

-- Signed-in user from the company email domain?
create or replace function private.is_team_user()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select auth.role()) = 'authenticated'
    and (select c.company_email_domain from public.app_config c where c.id = 1) <> ''
    and lower(split_part((select auth.jwt()) ->> 'email', '@', 2))
        = (select c.company_email_domain from public.app_config c where c.id = 1),
    false);
$$;

create or replace function private.is_service()
returns boolean
language sql stable set search_path = ''
as $$
  -- service_role through the API, or a direct trusted connection (migrations, tests, mock runner)
  -- that is not impersonating an API user.
  select coalesce((select auth.role()) = 'service_role', false)
      or (session_user = 'postgres' and coalesce((select auth.role()), '') = '');
$$;

create or replace function private.current_email()
returns text
language sql stable set search_path = ''
as $$ select lower(nullif((select auth.jwt()) ->> 'email', '')); $$;

create or replace function private.current_team_member_id()
returns uuid
language sql stable security definer set search_path = ''
as $$
  select t.id from public.team_member t where lower(t.email) = private.current_email() limit 1;
$$;

-- Raise unless the caller is a company user or the service role (n8n / tests).
create or replace function private.require_team()
returns void
language plpgsql stable set search_path = ''
as $$
begin
  if not (private.is_team_user() or private.is_service()) then
    raise exception 'Sign in with a company Google account to do this.' using errcode = '42501';
  end if;
end;
$$;

-- Actor overrides inside functions (instructor clicks, system runs).
create or replace function private.set_actor(p_kind text, p_instructor_id uuid default null, p_label text default null)
returns void
language sql set search_path = ''
as $$
  select set_config('app.actor_kind', coalesce(p_kind, ''), true),
         set_config('app.actor_instructor_id', coalesce(p_instructor_id::text, ''), true),
         set_config('app.actor_label', coalesce(p_label, ''), true);
$$;

create or replace function private.set_sim_now(p_now timestamptz)
returns void
language sql set search_path = ''
as $$ select set_config('app.sim_now', coalesce(p_now::text, ''), true); $$;

-- Append one history event. The only way rows get into history_event.
create or replace function private.log_event(
  p_category text,
  p_action text,
  p_entity_table text default null,
  p_entity_id uuid default null,
  p_before jsonb default null,
  p_after jsonb default null,
  p_note text default null,
  p_domain_id uuid default null,
  p_module_id uuid default null,
  p_module_week_id uuid default null,
  p_class_id uuid default null,
  p_instructor_id uuid default null,
  p_undo_of bigint default null,
  p_is_test boolean default false
) returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_kind text := nullif(current_setting('app.actor_kind', true), '');
  v_instr uuid := nullif(current_setting('app.actor_instructor_id', true), '')::uuid;
  v_label text := nullif(current_setting('app.actor_label', true), '');
  v_sim timestamptz := nullif(current_setting('app.sim_now', true), '')::timestamptz;
  v_tm uuid;
  v_id bigint;
begin
  if v_kind is null then
    v_tm := private.current_team_member_id();
    if private.is_team_user() then
      v_kind := 'TeamMember';
      v_label := coalesce(v_label, (select t.name from public.team_member t where t.id = v_tm), private.current_email());
    else
      v_kind := 'System';
      v_label := coalesce(v_label, 'System');
    end if;
  elsif v_kind = 'TeamMember' then
    v_tm := private.current_team_member_id();
  end if;
  insert into public.history_event (
    sim_at, actor_kind, actor_team_member_id, actor_instructor_id, actor_label, category, action,
    entity_table, entity_id, domain_id, module_id, module_week_id, class_id, instructor_id,
    before, after, note, undo_of, is_test)
  values (
    v_sim, v_kind, v_tm, v_instr, v_label, p_category, p_action,
    p_entity_table, p_entity_id, p_domain_id, p_module_id, p_module_week_id, p_class_id,
    coalesce(p_instructor_id, v_instr), p_before, p_after, p_note, p_undo_of, p_is_test)
  returning id into v_id;
  return v_id;
end;
$$;

-- updated_at / version / updated_by + optimistic locking.
-- Clients send the version they loaded; if it differs from the stored one, the save is rejected.
create or replace function private.touch_row()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.version is distinct from old.version then
    raise exception 'This changed — reload. Someone else saved this record after you opened it.'
      using errcode = '40001';
  end if;
  new.version := old.version + 1;
  new.updated_at := now();
  new.updated_by := coalesce(private.current_team_member_id(), new.updated_by);
  return new;
end;
$$;

create or replace function private.set_created_by()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_by := coalesce(private.current_team_member_id(), new.updated_by);
  return new;
end;
$$;

-- Setup-change history with before/after values (PRD 7.9, HIS-1/3).
create or replace function private.log_setup_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_row jsonb;
  v_ignore text[] := array['updated_at', 'updated_by', 'version', 'verified_at', 'last_response_at',
                           'email_bounced_at', 'discord_failed_at', 'test_clock_at'];
  v_action text;
  k text;
  v_changed boolean := false;
begin
  if current_setting('app.suppress_setup_log', true) = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op = 'INSERT' then
    v_after := to_jsonb(new); v_row := v_after; v_action := tg_table_name || ' added';
  elsif tg_op = 'DELETE' then
    v_before := to_jsonb(old); v_row := v_before; v_action := tg_table_name || ' removed';
  else
    v_before := to_jsonb(old); v_after := to_jsonb(new); v_row := v_after;
    v_action := tg_table_name || ' changed';
    for k in select jsonb_object_keys(v_after) loop
      if not (k = any (v_ignore)) and (v_before -> k) is distinct from (v_after -> k) then
        v_changed := true;
      end if;
    end loop;
    if not v_changed then
      return new;
    end if;
  end if;
  perform private.log_event(
    'Setup changes', v_action, tg_table_name::text,
    case when v_row ? 'id' and jsonb_typeof(v_row -> 'id') = 'string' and (v_row ->> 'id') ~ '^[0-9a-f-]{36}$'
         then (v_row ->> 'id')::uuid end,
    v_before, v_after, null,
    case when tg_table_name = 'domain' then (v_row ->> 'id')::uuid else (v_row ->> 'domain_id')::uuid end,
    case when tg_table_name = 'module' then (v_row ->> 'id')::uuid else (v_row ->> 'module_id')::uuid end,
    null, null,
    case when tg_table_name = 'instructor' then (v_row ->> 'id')::uuid else (v_row ->> 'instructor_id')::uuid end);
  return coalesce(new, old);
end;
$$;

-- History can't be edited or deleted — even by the table owner.
create or replace function private.history_is_append_only()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  raise exception 'History can''t be edited or deleted.' using errcode = '42501';
end;
$$;

create trigger history_no_update before update or delete on public.history_event
  for each row execute function private.history_is_append_only();
create trigger history_no_truncate before truncate on public.history_event
  for each statement execute function private.history_is_append_only();

-- -------------------------------------------------------------------------------------
-- Instructor integrity: lowercase emails, primary email mirrored, friendly duplicate errors,
-- Discord channel link parsing, re-verification after contact changes.
-- -------------------------------------------------------------------------------------
create or replace function private.instructor_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_other text;
  v_guild text := (select c.discord_guild_id from public.app_config c where c.id = 1);
  m text[];
begin
  new.primary_email := lower(trim(new.primary_email));
  new.full_name := trim(new.full_name);
  if new.discord_channel_link is not null and trim(new.discord_channel_link) <> '' then
    m := regexp_match(trim(new.discord_channel_link),
                      '^https://(?:www\.|ptb\.|canary\.)?discord(?:app)?\.com/channels/(\d{17,20})/(\d{17,20})/?$');
    if m is null then
      raise exception 'The Discord channel link should look like https://discord.com/channels/<server id>/<channel id>.'
        using errcode = '22023';
    end if;
    if v_guild is not null and m[1] <> v_guild then
      raise exception 'This Discord channel link is from a different server. Use a channel in the company server.'
        using errcode = '22023';
    end if;
    new.discord_server_id := m[1];
    new.discord_channel_id := m[2];
  end if;
  select i.full_name into v_other
    from public.instructor_email e join public.instructor i on i.id = e.instructor_id
   where lower(e.email) = new.primary_email and e.instructor_id <> new.id;
  if v_other is null and new.discord_user_id is not null then
    select i.full_name into v_other from public.instructor i
     where i.discord_user_id = new.discord_user_id and i.id <> new.id;
  end if;
  if v_other is not null then
    raise exception 'An instructor with this email or Discord ID already exists: %', v_other using errcode = '23505';
  end if;
  if tg_op = 'UPDATE' and (
       new.primary_email is distinct from old.primary_email
       or new.discord_user_id is distinct from old.discord_user_id
       or new.discord_channel_id is distinct from old.discord_channel_id) then
    new.verified_at := null;   -- changing contact details removes the Verified badge
    if new.primary_email is distinct from old.primary_email then
      new.email_bounced_at := null;
    end if;
    if new.discord_channel_id is distinct from old.discord_channel_id then
      new.discord_failed_at := null;
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.instructor_after_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform set_config('app.suppress_setup_log', 'on', true);
  if tg_op = 'UPDATE' and new.primary_email is distinct from old.primary_email then
    delete from public.instructor_email e where e.instructor_id = new.id and e.is_primary;
  end if;
  insert into public.instructor_email (instructor_id, email, is_primary)
  values (new.id, new.primary_email, true)
  on conflict do nothing;
  perform set_config('app.suppress_setup_log', 'off', true);
  return new;
end;
$$;

create or replace function private.instructor_email_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_other text;
begin
  new.email := lower(trim(new.email));
  select i.full_name into v_other
    from public.instructor_email e join public.instructor i on i.id = e.instructor_id
   where lower(e.email) = new.email and e.id <> new.id and e.instructor_id <> new.instructor_id;
  if v_other is not null then
    raise exception 'An instructor with this email or Discord ID already exists: %', v_other using errcode = '23505';
  end if;
  return new;
end;
$$;

create or replace function private.team_member_before_write()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.email := lower(trim(new.email));
  return new;
end;
$$;

-- module_week.domain_id always follows its module.
create or replace function private.module_week_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.domain_id := (select m.domain_id from public.module m where m.id = new.module_id);
  new.cohort := coalesce(trim(new.cohort), '');
  return new;
end;
$$;

-- Keep first_class_at / last_class_end_at of a module week in sync with its classes.
create or replace function private.refresh_module_week_times(p_mw uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.module_week w
     set first_class_at = s.first_at,
         last_class_end_at = s.last_end
    from (select min(c.starts_at) filter (where c.status <> 'Cancelled') as first_at,
                 max(c.ends_at) filter (where c.status <> 'Cancelled') as last_end
            from public.class_session c where c.module_week_id = p_mw) s
   where w.id = p_mw
     and (w.first_class_at is distinct from s.first_at or w.last_class_end_at is distinct from s.last_end);
$$;

create or replace function private.class_session_after_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform private.refresh_module_week_times(old.module_week_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform private.refresh_module_week_times(new.module_week_id);
  end if;
  return coalesce(new, old);
end;
$$;

-- Keep booking_slot.instructor_id consistent with its booking.
create or replace function private.booking_slot_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.instructor_id := (select b.instructor_id from public.booking b where b.id = new.booking_id);
  return new;
end;
$$;

create or replace function private.booking_after_status()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status <> 'Active' and old.status = 'Active' then
    update public.booking_slot s set active = false where s.booking_id = new.id and s.active;
  end if;
  return new;
end;
$$;

-- -------------------------------------------------------------------------------------
-- Settings: definitions (PRD §16), validation, lookup
-- -------------------------------------------------------------------------------------
insert into public.setting_definition (key, group_name, label, value_type, default_value, min_value, max_value, allowed, help, sort_order) values
  ('instructor_channels', 'Channels', 'Contact instructors by', 'enum', '"Both"', null, null, '["Both","DiscordOnly","EmailOnly"]', 'Discord + Email, Discord only, or Email only.', 10),
  ('team_channels', 'Channels', 'Team reminders by', 'enum', '"Discord"', null, null, '["Discord","DiscordAndEmail"]', 'Discord, plus email for people who chose email in the team list.', 20),
  ('default_outreach_mode', 'Outreach', 'Default outreach mode', 'enum', '"Sequential"', null, null, '["Sequential","Manual"]', null, 30),
  ('outreach_days', 'Outreach', 'Start asking instructors __ days before the class', 'int', '30', 7, 60, null, null, 40),
  ('readiness_days', 'Outreach', 'Run the readiness check __ days before the class', 'int', '45', 12, 90, null, 'Must be at least 5 days more than the outreach start.', 50),
  ('manual_end_behaviour', 'Outreach', 'When a manual list runs out', 'enum', '"Stop"', null, null, '["Stop","ContinueWithRanking"]', null, 60),
  ('window_long_reminder_h', 'Windows', 'More than 10 days away: remind after __ hours', 'int', '24', 6, 72, null, null, 70),
  ('window_long_move_h', 'Windows', 'More than 10 days away: move on after __ hours', 'int', '48', 12, 120, null, null, 80),
  ('window_mid_reminder_h', 'Windows', '3–10 days away: remind after __ hours', 'int', '12', 3, 48, null, null, 90),
  ('window_mid_move_h', 'Windows', '3–10 days away: move on after __ hours', 'int', '24', 6, 72, null, null, 100),
  ('window_short_reminder_h', 'Windows', 'Under 3 days away: remind after __ hours', 'int', '3', 1, 12, null, null, 110),
  ('window_short_move_h', 'Windows', 'Under 3 days away: move on after __ hours', 'int', '6', 2, 24, null, null, 120),
  ('urgent_band_days', 'Windows', 'The urgent band starts __ days before the class', 'int', '3', 1, 7, null, null, 130),
  ('short_notice_days', 'Windows', 'Treat problems as urgent when the class is under __ days away', 'int', '10', 5, 21, null, 'Used for "urgent if under 10 days" rules and the middle response window.', 140),
  ('instructor_quiet_start', 'Quiet hours', 'Instructors: no messages from (PT)', 'time', '"21:00"', null, null, null, 'Quiet window may be up to 12 hours.', 150),
  ('instructor_quiet_end', 'Quiet hours', 'Instructors: messages allowed again at (PT)', 'time', '"08:00"', null, null, null, null, 160),
  ('instructor_urgent_quiet_start', 'Quiet hours', 'Instructors, urgent band: no messages from (PT)', 'time', '"22:00"', null, null, null, null, 170),
  ('instructor_urgent_quiet_end', 'Quiet hours', 'Instructors, urgent band: messages allowed again at (PT)', 'time', '"07:00"', null, null, null, null, 180),
  ('team_quiet_start', 'Quiet hours', 'Team, non-urgent: no reminders from (IST)', 'time', '"20:00"', null, null, null, 'Quiet window may be up to 14 hours.', 190),
  ('team_quiet_end', 'Quiet hours', 'Team, non-urgent: reminders allowed again at (IST)', 'time', '"09:00"', null, null, null, null, 200),
  ('checkin_days', 'Check-ins', 'Instructor check-ins (days before the class)', 'int_list', '[10, 2]', 1, 14, null, 'The smallest number is the last check-in.', 210),
  ('checkin_14_enabled', 'Check-ins', 'Extra 14-day instructor check-in', 'bool', 'false', null, null, null, null, 220),
  ('owner_checkin_days', 'Check-ins', 'Owner check-in (days before the class)', 'int', '14', 7, 21, null, null, 230),
  ('last_checkin_no_reply', 'Check-ins', 'No reply at the last check-in means', 'enum', '"Alert"', null, null, '["Alert","Release"]', 'Alert ops and keep the booking, or release it.', 240),
  ('checklist_items', 'Checklist', 'Default checklist items per class', 'text_list', '["Calendar invite sent","Zoom link added","Uplevel link updated"]', null, null, null, null, 250),
  ('checklist_nudge_days', 'Checklist', 'Nudge ops __ days after confirmation', 'int', '3', 1, 14, null, null, 260),
  ('checklist_due_days', 'Checklist', 'Checklist must be done __ days before the class', 'int', '7', 1, 14, null, null, 270),
  ('help_target_norush_h', 'Help', 'Help response target: no rush (hours)', 'int', '24', 1, 72, null, null, 280),
  ('help_target_24h_h', 'Help', 'Help response target: within 24 hours (hours)', 'int', '8', 1, 72, null, null, 290),
  ('help_target_urgent_h', 'Help', 'Help response target: urgent (hours)', 'int', '2', 1, 72, null, null, 300),
  ('help_routing', 'Help', 'Help routing per category', 'json',
   '{"materials":"Owner","zoom":"Ops","platform":"Ops","assignment":"Owner","students":"Owner","schedule":"Ops","payment":"Ops","other":"Both"}',
   null, null, '["Owner","Ops","Both"]', null, 310),
  ('reminder_r2_normal_h', 'Reminders', 'Second reminder after __ hours (normal)', 'int', '24', 2, 72, null, null, 320),
  ('reminder_r2_urgent_h', 'Reminders', 'Repeat urgent reminders every __ hours', 'int', '4', 1, 12, null, null, 330),
  ('reminder_escalate_normal_h', 'Reminders', 'Escalate after __ hours (normal)', 'int', '48', 4, 120, null, null, 340),
  ('reminder_escalate_urgent_h', 'Reminders', 'Escalate after __ hours (urgent)', 'int', '8', 2, 24, null, null, 350),
  ('digest_time_ist', 'Reminders', 'Daily digest time (IST)', 'time', '"10:00"', null, null, null, null, 360),
  ('schedule_low_weeks', 'Planning', '"Schedule running low" when fewer than __ weeks are planned', 'int', '6', 4, 12, null, null, 370),
  ('min_active_instructors', 'Modules', 'Minimum active instructors per ranking', 'int', '2', 1, 5, null, null, 380);

create or replace function private.time_window_minutes(p_start text, p_end text)
returns int
language sql immutable set search_path = ''
as $$
  select (((extract(epoch from (p_end::time - p_start::time)) / 60)::int % 1440) + 1440) % 1440;
$$;

-- Effective setting: domain value → global value → definition default.
create or replace function private.get_setting(p_domain uuid, p_key text)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select s.value from public.setting s where s.key = p_key and s.domain_id = p_domain),
    (select s.value from public.setting s where s.key = p_key and s.scope = 'Global'),
    (select d.default_value from public.setting_definition d where d.key = p_key));
$$;

create or replace function private.setting_int(p_domain uuid, p_key text)
returns int language sql stable set search_path = ''
as $$ select (private.get_setting(p_domain, p_key))::text::int; $$;

create or replace function private.setting_text(p_domain uuid, p_key text)
returns text language sql stable set search_path = ''
as $$ select private.get_setting(p_domain, p_key) #>> '{}'; $$;

create or replace function private.setting_bool(p_domain uuid, p_key text)
returns boolean language sql stable set search_path = ''
as $$ select (private.get_setting(p_domain, p_key))::text::boolean; $$;

create or replace function private.validate_setting()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  d public.setting_definition;
  v jsonb := new.value;
  e jsonb;
  n int;
  v_out int;
  v_read int;
  v_dom uuid := new.domain_id;
begin
  select * into d from public.setting_definition where key = new.key;
  if d.value_type = 'int' then
    if jsonb_typeof(v) <> 'number' or (v #>> '{}') !~ '^-?\d+$' then
      raise exception '"%" must be a whole number.', d.label using errcode = '22023';
    end if;
    n := (v #>> '{}')::int;
    if (d.min_value is not null and n < d.min_value) or (d.max_value is not null and n > d.max_value) then
      raise exception '"%" must be between % and %.', d.label, d.min_value, d.max_value using errcode = '22023';
    end if;
  elsif d.value_type = 'bool' then
    if jsonb_typeof(v) <> 'boolean' then
      raise exception '"%" must be on or off.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'enum' then
    if jsonb_typeof(v) <> 'string' or not (d.allowed @> jsonb_build_array(v)) then
      raise exception '"%" must be one of: %.', d.label, d.allowed using errcode = '22023';
    end if;
  elsif d.value_type = 'time' then
    if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^([01]\d|2[0-3]):[0-5]\d$' then
      raise exception '"%" must be a time like 09:00.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'int_list' then
    if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then
      raise exception '"%" needs at least one value.', d.label using errcode = '22023';
    end if;
    for e in select * from jsonb_array_elements(v) loop
      if jsonb_typeof(e) <> 'number' or (e #>> '{}')::numeric not between d.min_value and d.max_value then
        raise exception '"%": every value must be between % and %.', d.label, d.min_value, d.max_value using errcode = '22023';
      end if;
    end loop;
  elsif d.value_type = 'text_list' then
    if jsonb_typeof(v) <> 'array' then
      raise exception '"%" must be a list.', d.label using errcode = '22023';
    end if;
  elsif d.value_type = 'json' then
    if jsonb_typeof(v) <> 'object' then
      raise exception '"%" must be an object.', d.label using errcode = '22023';
    end if;
    if d.allowed is not null then
      for e in select value from jsonb_each(v) loop
        if not (d.allowed @> jsonb_build_array(e)) then
          raise exception '"%": each value must be one of %.', d.label, d.allowed using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  -- Cross-field rules (evaluated with this new value in place).
  if new.key in ('outreach_days', 'readiness_days') then
    v_out := case when new.key = 'outreach_days' then (v #>> '{}')::int else private.setting_int(v_dom, 'outreach_days') end;
    v_read := case when new.key = 'readiness_days' then (v #>> '{}')::int else private.setting_int(v_dom, 'readiness_days') end;
    if v_read < v_out + 5 then
      raise exception 'The readiness check must be at least 5 days before outreach starts (outreach % days → readiness at least % days).',
        v_out, v_out + 5 using errcode = '22023';
    end if;
  end if;
  if new.key in ('instructor_quiet_start', 'instructor_quiet_end') then
    if private.time_window_minutes(
         case when new.key = 'instructor_quiet_start' then v #>> '{}' else private.setting_text(v_dom, 'instructor_quiet_start') end,
         case when new.key = 'instructor_quiet_end' then v #>> '{}' else private.setting_text(v_dom, 'instructor_quiet_end') end) > 720 then
      raise exception 'Instructor quiet hours can be at most 12 hours long.' using errcode = '22023';
    end if;
  end if;
  if new.key in ('team_quiet_start', 'team_quiet_end') then
    if private.time_window_minutes(
         case when new.key = 'team_quiet_start' then v #>> '{}' else private.setting_text(v_dom, 'team_quiet_start') end,
         case when new.key = 'team_quiet_end' then v #>> '{}' else private.setting_text(v_dom, 'team_quiet_end') end) > 840 then
      raise exception 'Team quiet hours can be at most 14 hours long.' using errcode = '22023';
    end if;
  end if;
  if new.key = 'instructor_channels' and (v #>> '{}') not in ('Both', 'DiscordOnly', 'EmailOnly') then
    raise exception 'Choose at least one channel.' using errcode = '22023';
  end if;
  return new;
end;
$$;

-- -------------------------------------------------------------------------------------
-- Time helpers (PRD §12). Never fixed offsets: always America/Los_Angeles.
-- -------------------------------------------------------------------------------------
create or replace function private.pt_to_utc(p_date date, p_time time)
returns timestamptz
language sql immutable set search_path = ''
as $$ select (p_date + p_time) at time zone 'America/Los_Angeles'; $$;

create or replace function private.to_pt(p_ts timestamptz)
returns timestamp
language sql immutable set search_path = ''
as $$ select p_ts at time zone 'America/Los_Angeles'; $$;

-- "PST" or "PDT" for a given instant.
create or replace function private.pt_abbrev(p_ts timestamptz)
returns text
language sql immutable set search_path = ''
as $$
  select case when (p_ts at time zone 'America/Los_Angeles') - (p_ts at time zone 'UTC') = interval '-7 hours'
              then 'PDT' else 'PST' end;
$$;

-- Public wrapper, handy for the app and tests.
create or replace function public.pt_to_utc(p_date date, p_time time)
returns timestamptz
language sql immutable set search_path = ''
as $$ select private.pt_to_utc(p_date, p_time); $$;

-- -------------------------------------------------------------------------------------
-- Triggers
-- -------------------------------------------------------------------------------------
do $$
declare t text;
begin
  -- version / updated_at on every table with a version column
  foreach t in array array['app_config', 'system_state', 'team_member', 'domain', 'domain_team', 'module',
    'module_owner', 'module_resource', 'class_pattern_item', 'instructor', 'instructor_email',
    'instructor_unavailability', 'module_ranking', 'module_week', 'manual_queue_item', 'class_session',
    'request', 'booking', 'booking_slot', 'checklist_item', 'help_request', 'attention_item', 'message',
    'reminder', 'setting', 'holiday', 'action_queue']
  loop
    execute format('create trigger %I before update on public.%I for each row execute function private.touch_row()',
                   t || '_touch', t);
    execute format('create trigger %I before insert on public.%I for each row execute function private.set_created_by()',
                   t || '_created_by', t);
  end loop;
  -- setup-change history
  foreach t in array array['app_config', 'team_member', 'domain', 'domain_team', 'module', 'module_owner',
    'module_resource', 'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability',
    'module_ranking', 'setting', 'holiday']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function private.log_setup_change()',
                   t || '_history', t);
  end loop;
end;
$$;

create trigger instructor_before_write before insert or update on public.instructor
  for each row execute function private.instructor_before_write();
create trigger instructor_after_write after insert or update of primary_email on public.instructor
  for each row execute function private.instructor_after_write();
create trigger instructor_email_before_write before insert or update on public.instructor_email
  for each row execute function private.instructor_email_before_write();
create trigger team_member_before_write before insert or update on public.team_member
  for each row execute function private.team_member_before_write();
create trigger module_week_before_write before insert or update of module_id, cohort on public.module_week
  for each row execute function private.module_week_before_write();
create trigger class_session_after_write after insert or update of starts_at, ends_at, status, module_week_id or delete
  on public.class_session for each row execute function private.class_session_after_write();
create trigger booking_slot_before_write before insert or update on public.booking_slot
  for each row execute function private.booking_slot_before_write();
create trigger booking_after_status after update of status on public.booking
  for each row execute function private.booking_after_status();
create trigger setting_validate before insert or update on public.setting
  for each row execute function private.validate_setting();

-- =====================================================================================
-- Auth: only company-domain Google accounts can be created (AUTH-1).
-- Enabled through [auth.hook.before_user_created] in config.toml / Dashboard → Auth → Hooks.
-- =====================================================================================
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_email text := lower(event -> 'user' ->> 'email');
  v_domain text := (select c.company_email_domain from public.app_config c where c.id = 1);
begin
  if v_domain is null or v_domain = '' or split_part(coalesce(v_email, ''), '@', 2) <> v_domain then
    insert into public.history_event (actor_kind, actor_label, category, action, note)
    values ('System', 'Sign-in', 'System', 'Sign-in rejected', 'Rejected account: ' || coalesce(v_email, '(no email)'));
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'Only company Google accounts can use SME Scheduling.'));
  end if;
  return '{}'::jsonb;
end;
$$;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
grant select on public.app_config to supabase_auth_admin;
grant insert on public.history_event to supabase_auth_admin;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, anon, public;

-- =====================================================================================
-- Row-level security and grants (AUTH-4, NFR-5)
-- =====================================================================================
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('create policy %I on public.%I for select to authenticated using (private.is_team_user())',
                   t || '_team_read', t);
  end loop;

  -- Setup data: company users edit directly (every change is logged by trigger).
  foreach t in array array['team_member', 'domain', 'domain_team', 'module', 'module_owner', 'module_resource',
    'class_pattern_item', 'instructor', 'instructor_email', 'instructor_unavailability', 'holiday']
  loop
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (private.is_team_user())', t || '_team_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (private.is_team_user()) with check (private.is_team_user())', t || '_team_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (private.is_team_user())', t || '_team_delete', t);
  end loop;

  -- Operational data and history: read-only for the app; changes only through database functions.
  foreach t in array array['app_config', 'system_state', 'module_ranking', 'module_week', 'manual_queue_item',
    'class_session', 'request', 'booking', 'booking_slot', 'checklist_item', 'help_request', 'attention_item',
    'message', 'reminder', 'history_event', 'setting_definition', 'setting', 'action_queue', 'discord_cursor']
  loop
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end;
$$;

-- Tokens are never readable by the app.
revoke select on public.response_link from authenticated;
drop policy if exists response_link_team_read on public.response_link;

-- History: nobody may update/delete through the API, including the service role.
revoke update, delete, truncate on public.history_event from authenticated, service_role, anon;

grant execute on function private.is_team_user() to authenticated, service_role;
grant execute on function private.current_team_member_id() to authenticated, service_role;
grant execute on function private.current_email() to authenticated, service_role;
grant execute on function private.is_service() to authenticated, service_role;
grant execute on function public.pt_to_utc(date, time) to authenticated, service_role;

-- Realtime for live screens.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.attention_item, public.module_week, public.request,
      public.booking, public.help_request, public.class_session, public.system_state;
  end if;
end;
$$;
