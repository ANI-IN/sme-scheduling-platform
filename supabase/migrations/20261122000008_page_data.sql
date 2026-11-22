-- Release 3, M6 (decision 294): indexes for the size of a real program.
--
-- With 60 cohorts, 160 instructors and a year of class weeks, the screens and the hourly check filter and join on
-- columns that had no index: every task, message, help request and reminder is looked up by what it belongs to, and
-- deleting a parent row (for example a class week or an instructor) has to find its children. Only indexes are added;
-- no table, rule or function changes. The class week list reads one domain in date order a page at a time
-- (decision 293), so it gets an index in exactly that order.

create index if not exists module_week_domain_week_idx on public.module_week (domain_id, week_start_date, id);

create index if not exists attention_item_domain_idx on public.attention_item (domain_id);
create index if not exists attention_item_module_week_idx on public.attention_item (module_week_id);
create index if not exists attention_item_module_idx on public.attention_item (module_id);
create index if not exists attention_item_instructor_idx on public.attention_item (instructor_id);
create index if not exists attention_item_request_idx on public.attention_item (request_id);
create index if not exists attention_item_help_request_idx on public.attention_item (help_request_id);
create index if not exists attention_item_message_idx on public.attention_item (message_id);
create index if not exists attention_item_class_idx on public.attention_item (class_id);
create index if not exists attention_item_assigned_to_idx on public.attention_item (assigned_to);

create index if not exists message_domain_idx on public.message (domain_id);
create index if not exists message_instructor_idx on public.message (instructor_id);
create index if not exists message_request_idx on public.message (request_id);
create index if not exists message_help_request_idx on public.message (help_request_id);
create index if not exists message_attention_item_idx on public.message (attention_item_id);
create index if not exists message_team_member_idx on public.message (team_member_id);

create index if not exists help_request_domain_idx on public.help_request (domain_id);
create index if not exists help_request_module_week_idx on public.help_request (module_week_id);
create index if not exists help_request_booking_idx on public.help_request (booking_id);
create index if not exists help_request_instructor_idx on public.help_request (requester_instructor_id);
create index if not exists help_request_team_member_idx on public.help_request (requester_team_member_id);
create index if not exists help_request_assigned_to_idx on public.help_request (assigned_to);
create index if not exists help_request_merged_into_idx on public.help_request (merged_into);

create index if not exists reminder_attention_item_idx on public.reminder (attention_item_id);
create index if not exists reminder_message_idx on public.reminder (message_id);
create index if not exists reminder_recipient_idx on public.reminder (recipient);

create index if not exists booking_request_idx on public.booking (request_id);
create index if not exists booking_slot_class_idx on public.booking_slot (class_id);
create index if not exists checklist_item_booking_idx on public.checklist_item (booking_id);
create index if not exists request_team_member_idx on public.request (team_member_id);
create index if not exists class_session_pattern_item_idx on public.class_session (pattern_item_id);
create index if not exists manual_queue_item_instructor_idx on public.manual_queue_item (instructor_id);

create index if not exists module_resource_module_idx on public.module_resource (module_id);
create index if not exists class_pattern_item_module_idx on public.class_pattern_item (module_id);
create index if not exists class_pattern_item_cohort_idx on public.class_pattern_item (cohort_id);
create index if not exists module_ranking_cohort_idx on public.module_ranking (cohort_id);
create index if not exists module_ranking_instructor_idx on public.module_ranking (instructor_id);
create index if not exists module_owner_team_member_idx on public.module_owner (team_member_id);
create index if not exists module_operations_cohort_idx on public.module_operations (cohort_id);
create index if not exists module_operations_team_member_idx on public.module_operations (team_member_id);
create index if not exists domain_team_team_member_idx on public.domain_team (team_member_id);
create index if not exists instructor_unavailability_instructor_idx on public.instructor_unavailability (instructor_id);
create index if not exists instructor_channel_domain_idx on public.instructor_channel (domain_id);
create index if not exists discord_server_domain_domain_idx on public.discord_server_domain (domain_id);
create index if not exists holiday_domain_idx on public.holiday (domain_id);

create index if not exists setting_domain_idx on public.setting (domain_id);
create index if not exists setting_cohort_idx on public.setting (cohort_id);
create index if not exists setting_module_idx on public.setting (module_id);
create index if not exists setting_module_week_idx on public.setting (module_week_id);
