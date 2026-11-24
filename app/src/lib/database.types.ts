
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "action_queue": {
                  Row: {
                    "action": string,"created_at": string,"error": string | null,"id": string,"payload": NonNullable<Json>,"processed_at": string | null,"requested_by": string | null,"result": Json | null,"status": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "action": string,"created_at"?: string,"error"?: string | null,"id"?: string,"payload"?: NonNullable<Json>,"processed_at"?: string | null,"requested_by"?: string | null,"result"?: Json | null,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "action"?: string,"created_at"?: string,"error"?: string | null,"id"?: string,"payload"?: NonNullable<Json>,"processed_at"?: string | null,"requested_by"?: string | null,"result"?: Json | null,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    
                  ]
                },"app_config": {
                  Row: {
                    "admin_discord_channel_id": string | null,"app_base_url": string | null,"beta_list_may_receive": boolean,"clock_enabled": boolean,"company_email_domain": string,"created_at": string,"daily_email_cap": number,"discord_bot_user_id": string | null,"discord_guild_id": string | null,"environment": string,"environment_set_at": string | null,"id": number,"message_recipients": string,"n8n_poke_url": string | null,"recipient_email_domains": (string)[],"response_base_url": string | null,"sandbox_allowed_discord_servers": (string)[],"sandbox_allowed_email_domains": (string)[],"scheduling_email": string | null,"scheduling_sender_name": string,"sign_in_mode": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "admin_discord_channel_id"?: string | null,"app_base_url"?: string | null,"beta_list_may_receive"?: boolean,"clock_enabled"?: boolean,"company_email_domain"?: string,"created_at"?: string,"daily_email_cap"?: number,"discord_bot_user_id"?: string | null,"discord_guild_id"?: string | null,"environment"?: string,"environment_set_at"?: string | null,"id"?: number,"message_recipients"?: string,"n8n_poke_url"?: string | null,"recipient_email_domains"?: (string)[],"response_base_url"?: string | null,"sandbox_allowed_discord_servers"?: (string)[],"sandbox_allowed_email_domains"?: (string)[],"scheduling_email"?: string | null,"scheduling_sender_name"?: string,"sign_in_mode"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "admin_discord_channel_id"?: string | null,"app_base_url"?: string | null,"beta_list_may_receive"?: boolean,"clock_enabled"?: boolean,"company_email_domain"?: string,"created_at"?: string,"daily_email_cap"?: number,"discord_bot_user_id"?: string | null,"discord_guild_id"?: string | null,"environment"?: string,"environment_set_at"?: string | null,"id"?: number,"message_recipients"?: string,"n8n_poke_url"?: string | null,"recipient_email_domains"?: (string)[],"response_base_url"?: string | null,"sandbox_allowed_discord_servers"?: (string)[],"sandbox_allowed_email_domains"?: (string)[],"scheduling_email"?: string | null,"scheduling_sender_name"?: string,"sign_in_mode"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    
                  ]
                },"app_error": {
                  Row: {
                    "at": string,"browser": string | null,"count": number,"detail": string | null,"id": number,"last_at": string,"message": string,"page": string | null,"team_member_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "at"?: string,"browser"?: string | null,"count"?: number,"detail"?: string | null,"id"?: never,"last_at"?: string,"message": string,"page"?: string | null,"team_member_id"?: string | null
                  }
                  Update: {
                    "at"?: string,"browser"?: string | null,"count"?: number,"detail"?: string | null,"id"?: never,"last_at"?: string,"message"?: string,"page"?: string | null,"team_member_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "app_error_team_member_id_fkey"
      columns: ["team_member_id"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"attention_item": {
                  Row: {
                    "ack_until": string | null,"acknowledged_by": string | null,"assigned_to": string | null,"class_id": string | null,"created_at": string,"dedupe_key": string | null,"detail": string | null,"domain_id": string | null,"done_at": string | null,"done_by": string | null,"done_note": string | null,"due_at": string | null,"escalated_at": string | null,"help_request_id": string | null,"id": string,"instructor_id": string | null,"is_test": boolean,"last_reminder_at": string | null,"message_id": string | null,"module_id": string | null,"module_week_id": string | null,"opened_at": string,"r1_at": string | null,"recipients": (string)[],"request_id": string | null,"severity": string,"status": string,"title": string,"type": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "ack_until"?: string | null,"acknowledged_by"?: string | null,"assigned_to"?: string | null,"class_id"?: string | null,"created_at"?: string,"dedupe_key"?: string | null,"detail"?: string | null,"domain_id"?: string | null,"done_at"?: string | null,"done_by"?: string | null,"done_note"?: string | null,"due_at"?: string | null,"escalated_at"?: string | null,"help_request_id"?: string | null,"id"?: string,"instructor_id"?: string | null,"is_test"?: boolean,"last_reminder_at"?: string | null,"message_id"?: string | null,"module_id"?: string | null,"module_week_id"?: string | null,"opened_at"?: string,"r1_at"?: string | null,"recipients"?: (string)[],"request_id"?: string | null,"severity"?: string,"status"?: string,"title": string,"type": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "ack_until"?: string | null,"acknowledged_by"?: string | null,"assigned_to"?: string | null,"class_id"?: string | null,"created_at"?: string,"dedupe_key"?: string | null,"detail"?: string | null,"domain_id"?: string | null,"done_at"?: string | null,"done_by"?: string | null,"done_note"?: string | null,"due_at"?: string | null,"escalated_at"?: string | null,"help_request_id"?: string | null,"id"?: string,"instructor_id"?: string | null,"is_test"?: boolean,"last_reminder_at"?: string | null,"message_id"?: string | null,"module_id"?: string | null,"module_week_id"?: string | null,"opened_at"?: string,"r1_at"?: string | null,"recipients"?: (string)[],"request_id"?: string | null,"severity"?: string,"status"?: string,"title"?: string,"type"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "attention_item_assigned_to_fkey"
      columns: ["assigned_to"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attention_item_class_id_fkey"
      columns: ["class_id"]
isOneToOne: false
      referencedRelation: "class_session"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attention_item_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attention_item_help_request_id_fkey"
      columns: ["help_request_id"]
isOneToOne: false
      referencedRelation: "help_request"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attention_item_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attention_item_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attention_item_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attention_item_request_id_fkey"
      columns: ["request_id"]
isOneToOne: false
      referencedRelation: "request"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "attention_message_fk"
      columns: ["message_id"]
isOneToOne: false
      referencedRelation: "message"
      referencedColumns: ["id"]
    }
                  ]
                },"beta_access": {
                  Row: {
                    "added_at": string,"added_by": string | null,"email": string,"note": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "added_at"?: string,"added_by"?: string | null,"email": string,"note"?: string | null
                  }
                  Update: {
                    "added_at"?: string,"added_by"?: string | null,"email"?: string,"note"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "beta_access_added_by_fkey"
      columns: ["added_by"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"booking": {
                  Row: {
                    "confirmed_at": string,"confirmed_by": string | null,"confirmed_via": string,"created_at": string,"id": string,"instructor_id": string,"is_test": boolean,"module_week_id": string,"release_reason": string | null,"released_at": string | null,"request_id": string | null,"status": string,"time_version_confirmed": number,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "confirmed_at"?: string,"confirmed_by"?: string | null,"confirmed_via": string,"created_at"?: string,"id"?: string,"instructor_id": string,"is_test"?: boolean,"module_week_id": string,"release_reason"?: string | null,"released_at"?: string | null,"request_id"?: string | null,"status"?: string,"time_version_confirmed"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "confirmed_at"?: string,"confirmed_by"?: string | null,"confirmed_via"?: string,"created_at"?: string,"id"?: string,"instructor_id"?: string,"is_test"?: boolean,"module_week_id"?: string,"release_reason"?: string | null,"released_at"?: string | null,"request_id"?: string | null,"status"?: string,"time_version_confirmed"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "booking_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "booking_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "booking_request_id_fkey"
      columns: ["request_id"]
isOneToOne: false
      referencedRelation: "request"
      referencedColumns: ["id"]
    }
                  ]
                },"booking_slot": {
                  Row: {
                    "active": boolean,"booking_id": string,"class_id": string,"created_at": string,"id": string,"instructor_id": string,"time_range": unknown,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"booking_id": string,"class_id": string,"created_at"?: string,"id"?: string,"instructor_id": string,"time_range": unknown,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "active"?: boolean,"booking_id"?: string,"class_id"?: string,"created_at"?: string,"id"?: string,"instructor_id"?: string,"time_range"?: unknown,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "booking_slot_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "booking"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "booking_slot_class_id_fkey"
      columns: ["class_id"]
isOneToOne: false
      referencedRelation: "class_session"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "booking_slot_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    }
                  ]
                },"checklist_item": {
                  Row: {
                    "added_manually": boolean,"booking_id": string | null,"class_id": string,"created_at": string,"done": boolean,"done_at": string | null,"done_by": string | null,"due_at": string | null,"id": string,"label": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "added_manually"?: boolean,"booking_id"?: string | null,"class_id": string,"created_at"?: string,"done"?: boolean,"done_at"?: string | null,"done_by"?: string | null,"due_at"?: string | null,"id"?: string,"label": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "added_manually"?: boolean,"booking_id"?: string | null,"class_id"?: string,"created_at"?: string,"done"?: boolean,"done_at"?: string | null,"done_by"?: string | null,"due_at"?: string | null,"id"?: string,"label"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "checklist_item_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "booking"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "checklist_item_class_id_fkey"
      columns: ["class_id"]
isOneToOne: false
      referencedRelation: "class_session"
      referencedColumns: ["id"]
    }
                  ]
                },"class_pattern_item": {
                  Row: {
                    "class_type": string,"cohort_id": string | null,"created_at": string,"day_offset": number,"duration_minutes": number,"id": string,"module_id": string,"sort_order": number,"start_time": string,"title_template": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "class_type": string,"cohort_id"?: string | null,"created_at"?: string,"day_offset": number,"duration_minutes": number,"id"?: string,"module_id": string,"sort_order"?: number,"start_time": string,"title_template"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "class_type"?: string,"cohort_id"?: string | null,"created_at"?: string,"day_offset"?: number,"duration_minutes"?: number,"id"?: string,"module_id"?: string,"sort_order"?: number,"start_time"?: string,"title_template"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "class_pattern_item_cohort_id_fkey"
      columns: ["cohort_id"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "class_pattern_item_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    }
                  ]
                },"class_session": {
                  Row: {
                    "cancelled_reason": string | null,"class_type": string,"created_at": string,"ends_at": string,"holiday_kept_on": string | null,"holiday_kept_reason": string | null,"id": string,"module_week_id": string,"moved_at": string | null,"notes": string | null,"pattern_item_id": string | null,"previous_ends_at": string | null,"previous_starts_at": string | null,"problem_flag": boolean,"region": string,"shared_class_id": string | null,"starts_at": string,"status": string,"title": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cancelled_reason"?: string | null,"class_type": string,"created_at"?: string,"ends_at": string,"holiday_kept_on"?: string | null,"holiday_kept_reason"?: string | null,"id"?: string,"module_week_id": string,"moved_at"?: string | null,"notes"?: string | null,"pattern_item_id"?: string | null,"previous_ends_at"?: string | null,"previous_starts_at"?: string | null,"problem_flag"?: boolean,"region"?: string,"shared_class_id"?: string | null,"starts_at": string,"status"?: string,"title": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "cancelled_reason"?: string | null,"class_type"?: string,"created_at"?: string,"ends_at"?: string,"holiday_kept_on"?: string | null,"holiday_kept_reason"?: string | null,"id"?: string,"module_week_id"?: string,"moved_at"?: string | null,"notes"?: string | null,"pattern_item_id"?: string | null,"previous_ends_at"?: string | null,"previous_starts_at"?: string | null,"problem_flag"?: boolean,"region"?: string,"shared_class_id"?: string | null,"starts_at"?: string,"status"?: string,"title"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "class_session_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "class_session_pattern_item_id_fkey"
      columns: ["pattern_item_id"]
isOneToOne: false
      referencedRelation: "class_pattern_item"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "class_session_shared_class_id_fkey"
      columns: ["shared_class_id"]
isOneToOne: false
      referencedRelation: "class_session"
      referencedColumns: ["id"]
    }
                  ]
                },"class_type": {
                  Row: {
                    "created_at": string,"domain_id": string,"id": string,"name": string,"sort_order": number,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"domain_id": string,"id"?: string,"name": string,"sort_order"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"domain_id"?: string,"id"?: string,"name"?: string,"sort_order"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "class_type_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    }
                  ]
                },"clock_state": {
                  Row: {
                    "budget_alert_month": string | null,"id": number,"last_poke_at": string | null,"last_reason": string | null,"last_reply_read_at": string | null,"last_result": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "budget_alert_month"?: string | null,"id"?: number,"last_poke_at"?: string | null,"last_reason"?: string | null,"last_reply_read_at"?: string | null,"last_result"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "budget_alert_month"?: string | null,"id"?: number,"last_poke_at"?: string | null,"last_reason"?: string | null,"last_reply_read_at"?: string | null,"last_result"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"cohort": {
                  Row: {
                    "archived_at": string | null,"created_at": string,"domain_id": string,"id": string,"merged_from": string | null,"merged_into": string | null,"name": string,"notes": string | null,"region": string,"standard_schedule_id": string | null,"start_date": string | null,"status": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "archived_at"?: string | null,"created_at"?: string,"domain_id": string,"id"?: string,"merged_from"?: string | null,"merged_into"?: string | null,"name": string,"notes"?: string | null,"region"?: string,"standard_schedule_id"?: string | null,"start_date"?: string | null,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "archived_at"?: string | null,"created_at"?: string,"domain_id"?: string,"id"?: string,"merged_from"?: string | null,"merged_into"?: string | null,"name"?: string,"notes"?: string | null,"region"?: string,"standard_schedule_id"?: string | null,"start_date"?: string | null,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "cohort_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "cohort_merged_into_fkey"
      columns: ["merged_into"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "cohort_standard_schedule_id_fkey"
      columns: ["standard_schedule_id"]
isOneToOne: false
      referencedRelation: "standard_schedule"
      referencedColumns: ["id"]
    }
                  ]
                },"cohort_break": {
                  Row: {
                    "cohort_id": string,"created_at": string,"domain_id": string,"id": string,"label": string | null,"moved": NonNullable<Json>,"program_break_id": string | null,"reason": string,"removed_at": string | null,"starts_on": string,"status": string,"updated_at": string,"updated_by": string | null,"version": number,"weeks": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cohort_id": string,"created_at"?: string,"domain_id": string,"id"?: string,"label"?: string | null,"moved"?: NonNullable<Json>,"program_break_id"?: string | null,"reason": string,"removed_at"?: string | null,"starts_on": string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"weeks": number
                  }
                  Update: {
                    "cohort_id"?: string,"created_at"?: string,"domain_id"?: string,"id"?: string,"label"?: string | null,"moved"?: NonNullable<Json>,"program_break_id"?: string | null,"reason"?: string,"removed_at"?: string | null,"starts_on"?: string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"weeks"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "cohort_break_cohort_id_fkey"
      columns: ["cohort_id"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "cohort_break_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "cohort_break_program_break_id_fkey"
      columns: ["program_break_id"]
isOneToOne: false
      referencedRelation: "program_break"
      referencedColumns: ["id"]
    }
                  ]
                },"cohort_holiday": {
                  Row: {
                    "cohort_id": string,"created_at": string,"date": string,"domain_id": string,"id": string,"label": string | null,"name": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cohort_id": string,"created_at"?: string,"date": string,"domain_id": string,"id"?: string,"label"?: string | null,"name": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "cohort_id"?: string,"created_at"?: string,"date"?: string,"domain_id"?: string,"id"?: string,"label"?: string | null,"name"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "cohort_holiday_cohort_id_fkey"
      columns: ["cohort_id"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "cohort_holiday_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    }
                  ]
                },"cohort_merge": {
                  Row: {
                    "created_at": string,"domain_id": string,"effective_date": string,"id": string,"order_from": string,"plan": NonNullable<Json>,"region": string,"sequence_from": string,"source_cohort_ids": (string)[],"status": string,"target_cohort_id": string,"undone_at": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"domain_id": string,"effective_date": string,"id"?: string,"order_from": string,"plan"?: NonNullable<Json>,"region": string,"sequence_from": string,"source_cohort_ids": (string)[],"status"?: string,"target_cohort_id": string,"undone_at"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"domain_id"?: string,"effective_date"?: string,"id"?: string,"order_from"?: string,"plan"?: NonNullable<Json>,"region"?: string,"sequence_from"?: string,"source_cohort_ids"?: (string)[],"status"?: string,"target_cohort_id"?: string,"undone_at"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "cohort_merge_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "cohort_merge_target_cohort_id_fkey"
      columns: ["target_cohort_id"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    }
                  ]
                },"discord_channel": {
                  Row: {
                    "bot_can_post": boolean | null,"category": string | null,"id": string,"name": string,"position": number,"refreshed_at": string,"server_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "bot_can_post"?: boolean | null,"category"?: string | null,"id": string,"name": string,"position"?: number,"refreshed_at"?: string,"server_id": string
                  }
                  Update: {
                    "bot_can_post"?: boolean | null,"category"?: string | null,"id"?: string,"name"?: string,"position"?: number,"refreshed_at"?: string,"server_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"discord_cursor": {
                  Row: {
                    "channel_id": string,"last_message_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "channel_id": string,"last_message_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "channel_id"?: string,"last_message_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"discord_server": {
                  Row: {
                    "access": string,"access_changed_at": string | null,"access_changed_by": string | null,"archived_at": string | null,"checked_at": string | null,"id": string,"name": string,"problem": string | null,"refreshed_at": string,"status": string
                  }
                  ComputedFields: never
                  Insert: {
                    "access"?: string,"access_changed_at"?: string | null,"access_changed_by"?: string | null,"archived_at"?: string | null,"checked_at"?: string | null,"id": string,"name": string,"problem"?: string | null,"refreshed_at"?: string,"status"?: string
                  }
                  Update: {
                    "access"?: string,"access_changed_at"?: string | null,"access_changed_by"?: string | null,"archived_at"?: string | null,"checked_at"?: string | null,"id"?: string,"name"?: string,"problem"?: string | null,"refreshed_at"?: string,"status"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "discord_server_access_changed_by_fkey"
      columns: ["access_changed_by"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"discord_server_domain": {
                  Row: {
                    "added_at": string,"domain_id": string,"server_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "added_at"?: string,"domain_id": string,"server_id": string
                  }
                  Update: {
                    "added_at"?: string,"domain_id"?: string,"server_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "discord_server_domain_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "discord_server_domain_server_id_fkey"
      columns: ["server_id"]
isOneToOne: false
      referencedRelation: "discord_server"
      referencedColumns: ["id"]
    }
                  ]
                },"domain": {
                  Row: {
                    "alert_discord_channel_id": string | null,"archived_at": string | null,"created_at": string,"discord_checked_at": string | null,"discord_problem": string | null,"discord_server_id": string | null,"discord_status": string,"id": string,"name": string,"paused_from": string | null,"status": string,"test_clock_at": string | null,"test_discord_channel_id": string | null,"test_email": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "alert_discord_channel_id"?: string | null,"archived_at"?: string | null,"created_at"?: string,"discord_checked_at"?: string | null,"discord_problem"?: string | null,"discord_server_id"?: string | null,"discord_status"?: string,"id"?: string,"name": string,"paused_from"?: string | null,"status"?: string,"test_clock_at"?: string | null,"test_discord_channel_id"?: string | null,"test_email"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "alert_discord_channel_id"?: string | null,"archived_at"?: string | null,"created_at"?: string,"discord_checked_at"?: string | null,"discord_problem"?: string | null,"discord_server_id"?: string | null,"discord_status"?: string,"id"?: string,"name"?: string,"paused_from"?: string | null,"status"?: string,"test_clock_at"?: string | null,"test_discord_channel_id"?: string | null,"test_email"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    
                  ]
                },"domain_team": {
                  Row: {
                    "created_at": string,"domain_id": string,"id": string,"role": string,"team_member_id": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"domain_id": string,"id"?: string,"role": string,"team_member_id": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"domain_id"?: string,"id"?: string,"role"?: string,"team_member_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "domain_team_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "domain_team_team_member_id_fkey"
      columns: ["team_member_id"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"help_request": {
                  Row: {
                    "assigned_to": string | null,"booking_id": string | null,"categories": (string)[],"created_at": string,"details": string | null,"domain_id": string | null,"escalated_at": string | null,"first_response_at": string | null,"half_reminder_at": string | null,"id": string,"is_test": boolean,"merged_into": string | null,"module_week_id": string | null,"raised_at": string,"reply_channel": string,"requester_instructor_id": string | null,"requester_team_member_id": string | null,"resolution_note": string | null,"resolved_at": string | null,"response_target_at": string | null,"routed_to": (string)[],"severity": string,"source": string,"status": string,"updated_at": string,"updated_by": string | null,"urgency": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "assigned_to"?: string | null,"booking_id"?: string | null,"categories"?: (string)[],"created_at"?: string,"details"?: string | null,"domain_id"?: string | null,"escalated_at"?: string | null,"first_response_at"?: string | null,"half_reminder_at"?: string | null,"id"?: string,"is_test"?: boolean,"merged_into"?: string | null,"module_week_id"?: string | null,"raised_at"?: string,"reply_channel"?: string,"requester_instructor_id"?: string | null,"requester_team_member_id"?: string | null,"resolution_note"?: string | null,"resolved_at"?: string | null,"response_target_at"?: string | null,"routed_to"?: (string)[],"severity"?: string,"source": string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"urgency"?: string,"version"?: number
                  }
                  Update: {
                    "assigned_to"?: string | null,"booking_id"?: string | null,"categories"?: (string)[],"created_at"?: string,"details"?: string | null,"domain_id"?: string | null,"escalated_at"?: string | null,"first_response_at"?: string | null,"half_reminder_at"?: string | null,"id"?: string,"is_test"?: boolean,"merged_into"?: string | null,"module_week_id"?: string | null,"raised_at"?: string,"reply_channel"?: string,"requester_instructor_id"?: string | null,"requester_team_member_id"?: string | null,"resolution_note"?: string | null,"resolved_at"?: string | null,"response_target_at"?: string | null,"routed_to"?: (string)[],"severity"?: string,"source"?: string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"urgency"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "help_request_assigned_to_fkey"
      columns: ["assigned_to"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "help_request_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "booking"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "help_request_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "help_request_merged_into_fkey"
      columns: ["merged_into"]
isOneToOne: false
      referencedRelation: "help_request"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "help_request_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "help_request_requester_instructor_id_fkey"
      columns: ["requester_instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "help_request_requester_team_member_id_fkey"
      columns: ["requester_team_member_id"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"history_event": {
                  Row: {
                    "action": string,"actor_instructor_id": string | null,"actor_kind": string,"actor_label": string | null,"actor_team_member_id": string | null,"after": Json | null,"at": string,"before": Json | null,"category": string,"class_id": string | null,"cohort_id": string | null,"domain_id": string | null,"entity_id": string | null,"entity_label": string | null,"entity_table": string | null,"id": number,"instructor_id": string | null,"is_test": boolean,"module_id": string | null,"module_week_id": string | null,"note": string | null,"sim_at": string | null,"undo_of": number | null,"undoable": boolean | null
                  }
                  ComputedFields: "undoable"
                  Insert: {
                    "action": string,"actor_instructor_id"?: string | null,"actor_kind": string,"actor_label"?: string | null,"actor_team_member_id"?: string | null,"after"?: Json | null,"at"?: string,"before"?: Json | null,"category": string,"class_id"?: string | null,"cohort_id"?: string | null,"domain_id"?: string | null,"entity_id"?: string | null,"entity_label"?: string | null,"entity_table"?: string | null,"id"?: never,"instructor_id"?: string | null,"is_test"?: boolean,"module_id"?: string | null,"module_week_id"?: string | null,"note"?: string | null,"sim_at"?: string | null,"undo_of"?: number | null
                  }
                  Update: {
                    "action"?: string,"actor_instructor_id"?: string | null,"actor_kind"?: string,"actor_label"?: string | null,"actor_team_member_id"?: string | null,"after"?: Json | null,"at"?: string,"before"?: Json | null,"category"?: string,"class_id"?: string | null,"cohort_id"?: string | null,"domain_id"?: string | null,"entity_id"?: string | null,"entity_label"?: string | null,"entity_table"?: string | null,"id"?: never,"instructor_id"?: string | null,"is_test"?: boolean,"module_id"?: string | null,"module_week_id"?: string | null,"note"?: string | null,"sim_at"?: string | null,"undo_of"?: number | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "history_event_undo_of_fkey"
      columns: ["undo_of"]
isOneToOne: false
      referencedRelation: "history_event"
      referencedColumns: ["id"]
    }
                  ]
                },"holiday": {
                  Row: {
                    "created_at": string,"date": string,"domain_id": string | null,"id": string,"name": string,"region": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"date": string,"domain_id"?: string | null,"id"?: string,"name": string,"region"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"date"?: string,"domain_id"?: string | null,"id"?: string,"name"?: string,"region"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "holiday_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    }
                  ]
                },"instructor": {
                  Row: {
                    "created_at": string,"discord_channel_id": string | null,"discord_channel_link": string | null,"discord_checked_at": string | null,"discord_failed_at": string | null,"discord_held_by": string | null,"time_zone": string | null,"discord_problem": string | null,"discord_server_id": string | null,"discord_status": string,"discord_user_id": string | null,"discord_username": string | null,"email_bounced_at": string | null,"full_name": string,"id": string,"is_test": boolean,"last_response_at": string | null,"monthly_class_limit": number | null,"notes": string | null,"phone": string | null,"preferred_contact": string,"primary_email": string,"status": string,"updated_at": string,"updated_by": string | null,"verified_at": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"discord_channel_id"?: string | null,"discord_channel_link"?: string | null,"discord_checked_at"?: string | null,"discord_failed_at"?: string | null,"discord_held_by"?: string | null,"time_zone"?: string | null,"discord_problem"?: string | null,"discord_server_id"?: string | null,"discord_status"?: string,"discord_user_id"?: string | null,"discord_username"?: string | null,"email_bounced_at"?: string | null,"full_name": string,"id"?: string,"is_test"?: boolean,"last_response_at"?: string | null,"monthly_class_limit"?: number | null,"notes"?: string | null,"phone"?: string | null,"preferred_contact"?: string,"primary_email": string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"verified_at"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"discord_channel_id"?: string | null,"discord_channel_link"?: string | null,"discord_checked_at"?: string | null,"discord_failed_at"?: string | null,"discord_held_by"?: string | null,"time_zone"?: string | null,"discord_problem"?: string | null,"discord_server_id"?: string | null,"discord_status"?: string,"discord_user_id"?: string | null,"discord_username"?: string | null,"email_bounced_at"?: string | null,"full_name"?: string,"id"?: string,"is_test"?: boolean,"last_response_at"?: string | null,"monthly_class_limit"?: number | null,"notes"?: string | null,"phone"?: string | null,"preferred_contact"?: string,"primary_email"?: string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"verified_at"?: string | null,"version"?: number
                  }
                  Relationships: [
                    
                  ]
                },"channel_check": {
                  Row: {
                    "action_id": string | null,"channel_id": string,"channel_name": string | null,"checked_at": string | null,"created_at": string,"created_by": string | null,"domain_id": string,"id": string,"instructor_id": string,"problems": (string)[],"status": string
                  }
                  ComputedFields: never
                  Insert: {
                    "action_id"?: string | null,"channel_id": string,"channel_name"?: string | null,"checked_at"?: string | null,"created_at"?: string,"created_by"?: string | null,"domain_id": string,"id"?: string,"instructor_id": string,"problems"?: (string)[],"status"?: string
                  }
                  Update: {
                    "action_id"?: string | null,"channel_id"?: string,"channel_name"?: string | null,"checked_at"?: string | null,"created_at"?: string,"created_by"?: string | null,"domain_id"?: string,"id"?: string,"instructor_id"?: string,"problems"?: (string)[],"status"?: string
                  }
                  Relationships: []
                },"instructor_channel": {
                  Row: {
                    "channel_id": string,"channel_name": string | null,"created_at": string,"domain_id": string,"instructor_id": string,"ready_at": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "channel_id": string,"channel_name"?: string | null,"created_at"?: string,"domain_id": string,"instructor_id": string,"ready_at"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "channel_id"?: string,"channel_name"?: string | null,"created_at"?: string,"domain_id"?: string,"instructor_id"?: string,"ready_at"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "instructor_channel_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "instructor_channel_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    }
                  ]
                },"instructor_email": {
                  Row: {
                    "created_at": string,"email": string,"id": string,"instructor_id": string,"is_primary": boolean,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"email": string,"id"?: string,"instructor_id": string,"is_primary"?: boolean,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"email"?: string,"id"?: string,"instructor_id"?: string,"is_primary"?: boolean,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "instructor_email_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    }
                  ]
                },"instructor_unavailability": {
                  Row: {
                    "created_at": string,"from_date": string,"id": string,"instructor_id": string,"reason": string | null,"to_date": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"from_date": string,"id"?: string,"instructor_id": string,"reason"?: string | null,"to_date": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"from_date"?: string,"id"?: string,"instructor_id"?: string,"reason"?: string | null,"to_date"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "instructor_unavailability_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    }
                  ]
                },"manual_queue_item": {
                  Row: {
                    "asked_request_id": string | null,"created_at": string,"id": string,"instructor_id": string,"module_week_id": string,"position": number,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "asked_request_id"?: string | null,"created_at"?: string,"id"?: string,"instructor_id": string,"module_week_id": string,"position": number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "asked_request_id"?: string | null,"created_at"?: string,"id"?: string,"instructor_id"?: string,"module_week_id"?: string,"position"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "manual_queue_item_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "manual_queue_item_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    }
                  ]
                },"message": {
                  Row: {
                    "attempts": number,"attention_item_id": string | null,"blocked": boolean,"audience": string,"body_html": string | null,"body_text": string | null,"buttons": NonNullable<Json>,"channel": string,"claimed_at": string | null,"created_at": string,"direction": string,"discord_channel_id": string | null,"discord_dm_user_id": string | null,"domain_id": string | null,"external_id": string | null,"from_address": string | null,"help_request_id": string | null,"id": string,"in_reply_to": string | null,"instructor_id": string | null,"is_test": boolean,"last_error": string | null,"mention_user_ids": (string)[],"module_week_id": string | null,"not_before": string | null,"recipient_label": string | null,"request_id": string | null,"sent_at": string | null,"status": string,"subject": string | null,"summary": string | null,"team_member_id": string | null,"template_id": string,"to_address": string | null,"unique_key": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "attempts"?: number,"attention_item_id"?: string | null,"blocked"?: boolean,"audience": string,"body_html"?: string | null,"body_text"?: string | null,"buttons"?: NonNullable<Json>,"channel": string,"claimed_at"?: string | null,"created_at"?: string,"direction"?: string,"discord_channel_id"?: string | null,"discord_dm_user_id"?: string | null,"domain_id"?: string | null,"external_id"?: string | null,"from_address"?: string | null,"help_request_id"?: string | null,"id"?: string,"in_reply_to"?: string | null,"instructor_id"?: string | null,"is_test"?: boolean,"last_error"?: string | null,"mention_user_ids"?: (string)[],"module_week_id"?: string | null,"not_before"?: string | null,"recipient_label"?: string | null,"request_id"?: string | null,"sent_at"?: string | null,"status"?: string,"subject"?: string | null,"summary"?: string | null,"team_member_id"?: string | null,"template_id": string,"to_address"?: string | null,"unique_key"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "attempts"?: number,"attention_item_id"?: string | null,"blocked"?: boolean,"audience"?: string,"body_html"?: string | null,"body_text"?: string | null,"buttons"?: NonNullable<Json>,"channel"?: string,"claimed_at"?: string | null,"created_at"?: string,"direction"?: string,"discord_channel_id"?: string | null,"discord_dm_user_id"?: string | null,"domain_id"?: string | null,"external_id"?: string | null,"from_address"?: string | null,"help_request_id"?: string | null,"id"?: string,"in_reply_to"?: string | null,"instructor_id"?: string | null,"is_test"?: boolean,"last_error"?: string | null,"mention_user_ids"?: (string)[],"module_week_id"?: string | null,"not_before"?: string | null,"recipient_label"?: string | null,"request_id"?: string | null,"sent_at"?: string | null,"status"?: string,"subject"?: string | null,"summary"?: string | null,"team_member_id"?: string | null,"template_id"?: string,"to_address"?: string | null,"unique_key"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "message_attention_item_id_fkey"
      columns: ["attention_item_id"]
isOneToOne: false
      referencedRelation: "attention_item"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "message_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "message_help_request_id_fkey"
      columns: ["help_request_id"]
isOneToOne: false
      referencedRelation: "help_request"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "message_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "message_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "message_request_id_fkey"
      columns: ["request_id"]
isOneToOne: false
      referencedRelation: "request"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "message_team_member_id_fkey"
      columns: ["team_member_id"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"message_template": {
                  Row: {
                    "body": string,"created_at": string,"domain_id": string,"id": string,"subject": string,"template_id": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "body": string,"created_at"?: string,"domain_id": string,"id"?: string,"subject": string,"template_id": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "body"?: string,"created_at"?: string,"domain_id"?: string,"id"?: string,"subject"?: string,"template_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "message_template_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    }
                  ]
                },"module": {
                  Row: {
                    "created_at": string,"domain_id": string,"id": string,"name": string,"rotation_order": number,"same_instructor_for_module_week": boolean,"status": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"domain_id": string,"id"?: string,"name": string,"rotation_order"?: number,"same_instructor_for_module_week"?: boolean,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"domain_id"?: string,"id"?: string,"name"?: string,"rotation_order"?: number,"same_instructor_for_module_week"?: boolean,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "module_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    }
                  ]
                },"module_operations": {
                  Row: {
                    "cohort_id": string | null,"created_at": string,"id": string,"module_id": string,"team_member_id": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cohort_id"?: string | null,"created_at"?: string,"id"?: string,"module_id": string,"team_member_id": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "cohort_id"?: string | null,"created_at"?: string,"id"?: string,"module_id"?: string,"team_member_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "module_operations_cohort_id_fkey"
      columns: ["cohort_id"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "module_operations_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "module_operations_team_member_id_fkey"
      columns: ["team_member_id"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"module_owner": {
                  Row: {
                    "created_at": string,"id": string,"module_id": string,"team_member_id": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"module_id": string,"team_member_id": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"module_id"?: string,"team_member_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "module_owner_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "module_owner_team_member_id_fkey"
      columns: ["team_member_id"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"module_ranking": {
                  Row: {
                    "cohort_id": string | null,"created_at": string,"id": string,"instructor_id": string,"module_id": string,"rank": number,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cohort_id"?: string | null,"created_at"?: string,"id"?: string,"instructor_id": string,"module_id": string,"rank": number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "cohort_id"?: string | null,"created_at"?: string,"id"?: string,"instructor_id"?: string,"module_id"?: string,"rank"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "module_ranking_cohort_id_fkey"
      columns: ["cohort_id"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "module_ranking_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "module_ranking_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    }
                  ]
                },"module_resource": {
                  Row: {
                    "created_at": string,"id": string,"include_in_confirmation": boolean,"module_id": string,"sort_order": number,"title": string,"updated_at": string,"updated_by": string | null,"url": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"include_in_confirmation"?: boolean,"module_id": string,"sort_order"?: number,"title": string,"updated_at"?: string,"updated_by"?: string | null,"url": string,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"include_in_confirmation"?: boolean,"module_id"?: string,"sort_order"?: number,"title"?: string,"updated_at"?: string,"updated_by"?: string | null,"url"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "module_resource_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    }
                  ]
                },"module_week": {
                  Row: {
                    "archive_paused": boolean,"at_risk": boolean,"at_risk_reason": string | null,"cohort": string,"cohort_id": string,"created_at": string,"customized_at": string | null,"domain_id": string,"first_class_at": string | null,"id": string,"last_class_end_at": string | null,"manual_end_behaviour": string,"module_id": string,"outreach_mode": string,"outreach_started_at": string | null,"owner_checkin_sent_at": string | null,"paused": boolean,"readiness_checked_at": string | null,"readiness_escalated_at": string | null,"readiness_problems": Json | null,"same_instructor": boolean,"seq": number,"shared_with": string | null,"split_group": string | null,"standard_position": number | null,"status": string,"time_version": number,"updated_at": string,"updated_by": string | null,"version": number,"week_start_date": string
                  }
                  ComputedFields: never
                  Insert: {
                    "archive_paused"?: boolean,"at_risk"?: boolean,"at_risk_reason"?: string | null,"cohort"?: string,"cohort_id": string,"created_at"?: string,"customized_at"?: string | null,"domain_id": string,"first_class_at"?: string | null,"id"?: string,"last_class_end_at"?: string | null,"manual_end_behaviour"?: string,"module_id": string,"outreach_mode"?: string,"outreach_started_at"?: string | null,"owner_checkin_sent_at"?: string | null,"paused"?: boolean,"readiness_checked_at"?: string | null,"readiness_escalated_at"?: string | null,"readiness_problems"?: Json | null,"same_instructor": boolean,"seq"?: number,"shared_with"?: string | null,"split_group"?: string | null,"standard_position"?: number | null,"status"?: string,"time_version"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"week_start_date": string
                  }
                  Update: {
                    "archive_paused"?: boolean,"at_risk"?: boolean,"at_risk_reason"?: string | null,"cohort"?: string,"cohort_id"?: string,"created_at"?: string,"customized_at"?: string | null,"domain_id"?: string,"first_class_at"?: string | null,"id"?: string,"last_class_end_at"?: string | null,"manual_end_behaviour"?: string,"module_id"?: string,"outreach_mode"?: string,"outreach_started_at"?: string | null,"owner_checkin_sent_at"?: string | null,"paused"?: boolean,"readiness_checked_at"?: string | null,"readiness_escalated_at"?: string | null,"readiness_problems"?: Json | null,"same_instructor"?: boolean,"seq"?: number,"shared_with"?: string | null,"split_group"?: string | null,"standard_position"?: number | null,"status"?: string,"time_version"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"week_start_date"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "module_week_cohort_id_fkey"
      columns: ["cohort_id"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "module_week_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "module_week_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "module_week_shared_with_fkey"
      columns: ["shared_with"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    }
                  ]
                },"n8n_usage": {
                  Row: {
                    "last_at": string | null,"month": string,"runs": number,"workflow": string
                  }
                  ComputedFields: never
                  Insert: {
                    "last_at"?: string | null,"month": string,"runs"?: number,"workflow": string
                  }
                  Update: {
                    "last_at"?: string | null,"month"?: string,"runs"?: number,"workflow"?: string
                  }
                  Relationships: [
                    
                  ]
                },"program_break": {
                  Row: {
                    "created_at": string,"domain_id": string,"id": string,"label": string | null,"reason": string,"removed_at": string | null,"starts_on": string,"status": string,"updated_at": string,"updated_by": string | null,"version": number,"weeks": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"domain_id": string,"id"?: string,"label"?: string | null,"reason": string,"removed_at"?: string | null,"starts_on": string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"weeks": number
                  }
                  Update: {
                    "created_at"?: string,"domain_id"?: string,"id"?: string,"label"?: string | null,"reason"?: string,"removed_at"?: string | null,"starts_on"?: string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"weeks"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "program_break_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    }
                  ]
                },"reminder": {
                  Row: {
                    "attention_item_id": string,"created_at": string,"id": string,"level": string,"message_id": string | null,"recipient": string | null,"sent_at": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "attention_item_id": string,"created_at"?: string,"id"?: string,"level": string,"message_id"?: string | null,"recipient"?: string | null,"sent_at"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "attention_item_id"?: string,"created_at"?: string,"id"?: string,"level"?: string,"message_id"?: string | null,"recipient"?: string | null,"sent_at"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "reminder_attention_item_id_fkey"
      columns: ["attention_item_id"]
isOneToOne: false
      referencedRelation: "attention_item"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reminder_message_id_fkey"
      columns: ["message_id"]
isOneToOne: false
      referencedRelation: "message"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reminder_recipient_fkey"
      columns: ["recipient"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"request": {
                  Row: {
                    "answer": string | null,"answered_at": string | null,"booking_id": string | null,"check_in_days": number | null,"close_reason": string | null,"created_at": string,"deadline_at": string | null,"declined_before": boolean,"id": string,"instructor_id": string | null,"is_test": boolean,"kind": string,"line_source": string | null,"module_week_id": string | null,"reminded_at": string | null,"reminder_at": string | null,"sent_at": string | null,"status": string,"team_member_id": string | null,"time_version": number,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "answer"?: string | null,"answered_at"?: string | null,"booking_id"?: string | null,"check_in_days"?: number | null,"close_reason"?: string | null,"created_at"?: string,"deadline_at"?: string | null,"declined_before"?: boolean,"id"?: string,"instructor_id"?: string | null,"is_test"?: boolean,"kind": string,"line_source"?: string | null,"module_week_id"?: string | null,"reminded_at"?: string | null,"reminder_at"?: string | null,"sent_at"?: string | null,"status"?: string,"team_member_id"?: string | null,"time_version"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "answer"?: string | null,"answered_at"?: string | null,"booking_id"?: string | null,"check_in_days"?: number | null,"close_reason"?: string | null,"created_at"?: string,"deadline_at"?: string | null,"declined_before"?: boolean,"id"?: string,"instructor_id"?: string | null,"is_test"?: boolean,"kind"?: string,"line_source"?: string | null,"module_week_id"?: string | null,"reminded_at"?: string | null,"reminder_at"?: string | null,"sent_at"?: string | null,"status"?: string,"team_member_id"?: string | null,"time_version"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "request_booking_fk"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "booking"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "request_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "request_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "request_team_member_id_fkey"
      columns: ["team_member_id"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"response_link": {
                  Row: {
                    "answer": string,"created_at": string,"opened_at": string | null,"request_id": string,"token": string,"used_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "answer": string,"created_at"?: string,"opened_at"?: string | null,"request_id": string,"token": string,"used_at"?: string | null
                  }
                  Update: {
                    "answer"?: string,"created_at"?: string,"opened_at"?: string | null,"request_id"?: string,"token"?: string,"used_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "response_link_request_id_fkey"
      columns: ["request_id"]
isOneToOne: false
      referencedRelation: "request"
      referencedColumns: ["id"]
    }
                  ]
                },"setting": {
                  Row: {
                    "cohort_id": string | null,"created_at": string,"domain_id": string | null,"id": string,"key": string,"module_id": string | null,"module_week_id": string | null,"reason": string | null,"scope": string,"updated_at": string,"updated_by": string | null,"value": NonNullable<Json>,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cohort_id"?: string | null,"created_at"?: string,"domain_id"?: string | null,"id"?: string,"key": string,"module_id"?: string | null,"module_week_id"?: string | null,"reason"?: string | null,"scope": string,"updated_at"?: string,"updated_by"?: string | null,"value": NonNullable<Json>,"version"?: number
                  }
                  Update: {
                    "cohort_id"?: string | null,"created_at"?: string,"domain_id"?: string | null,"id"?: string,"key"?: string,"module_id"?: string | null,"module_week_id"?: string | null,"reason"?: string | null,"scope"?: string,"updated_at"?: string,"updated_by"?: string | null,"value"?: NonNullable<Json>,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "setting_cohort_id_fkey"
      columns: ["cohort_id"]
isOneToOne: false
      referencedRelation: "cohort"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "setting_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "setting_key_fkey"
      columns: ["key"]
isOneToOne: false
      referencedRelation: "setting_definition"
      referencedColumns: ["key"]
    },{
      foreignKeyName: "setting_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "setting_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    }
                  ]
                },"setting_definition": {
                  Row: {
                    "allowed": Json | null,"default_value": NonNullable<Json>,"group_name": string,"help": string | null,"key": string,"label": string,"max_value": number | null,"min_value": number | null,"sort_order": number,"value_type": string
                  }
                  ComputedFields: never
                  Insert: {
                    "allowed"?: Json | null,"default_value": NonNullable<Json>,"group_name": string,"help"?: string | null,"key": string,"label": string,"max_value"?: number | null,"min_value"?: number | null,"sort_order"?: number,"value_type": string
                  }
                  Update: {
                    "allowed"?: Json | null,"default_value"?: NonNullable<Json>,"group_name"?: string,"help"?: string | null,"key"?: string,"label"?: string,"max_value"?: number | null,"min_value"?: number | null,"sort_order"?: number,"value_type"?: string
                  }
                  Relationships: [
                    
                  ]
                },"standard_schedule": {
                  Row: {
                    "archived_at": string | null,"created_at": string,"domain_id": string,"id": string,"name": string,"notes": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "archived_at"?: string | null,"created_at"?: string,"domain_id": string,"id"?: string,"name": string,"notes"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "archived_at"?: string | null,"created_at"?: string,"domain_id"?: string,"id"?: string,"name"?: string,"notes"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "standard_schedule_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    }
                  ]
                },"standard_schedule_break": {
                  Row: {
                    "after_position": number,"created_at": string,"domain_id": string,"id": string,"label": string | null,"schedule_id": string,"updated_at": string,"updated_by": string | null,"version": number,"weeks": number
                  }
                  ComputedFields: never
                  Insert: {
                    "after_position": number,"created_at"?: string,"domain_id": string,"id"?: string,"label"?: string | null,"schedule_id": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"weeks": number
                  }
                  Update: {
                    "after_position"?: number,"created_at"?: string,"domain_id"?: string,"id"?: string,"label"?: string | null,"schedule_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"weeks"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "standard_schedule_break_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "standard_schedule_break_schedule_id_fkey"
      columns: ["schedule_id"]
isOneToOne: false
      referencedRelation: "standard_schedule"
      referencedColumns: ["id"]
    }
                  ]
                },"standard_schedule_class": {
                  Row: {
                    "class_type": string,"created_at": string,"day_offset": number,"domain_id": string,"duration_minutes": number,"id": string,"label": string | null,"module_id": string,"schedule_id": string,"sort_order": number,"start_time": string,"title_template": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "class_type": string,"created_at"?: string,"day_offset"?: number,"domain_id": string,"duration_minutes": number,"id"?: string,"label"?: string | null,"module_id": string,"schedule_id": string,"sort_order"?: number,"start_time": string,"title_template"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "class_type"?: string,"created_at"?: string,"day_offset"?: number,"domain_id"?: string,"duration_minutes"?: number,"id"?: string,"label"?: string | null,"module_id"?: string,"schedule_id"?: string,"sort_order"?: number,"start_time"?: string,"title_template"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "standard_schedule_class_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "standard_schedule_class_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "standard_schedule_class_schedule_id_fkey"
      columns: ["schedule_id"]
isOneToOne: false
      referencedRelation: "standard_schedule"
      referencedColumns: ["id"]
    }
                  ]
                },"standard_schedule_module": {
                  Row: {
                    "created_at": string,"domain_id": string,"id": string,"label": string | null,"module_id": string,"position": number,"schedule_id": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"domain_id": string,"id"?: string,"label"?: string | null,"module_id": string,"position": number,"schedule_id": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"domain_id"?: string,"id"?: string,"label"?: string | null,"module_id"?: string,"position"?: number,"schedule_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "standard_schedule_module_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "standard_schedule_module_module_id_fkey"
      columns: ["module_id"]
isOneToOne: false
      referencedRelation: "module"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "standard_schedule_module_schedule_id_fkey"
      columns: ["schedule_id"]
isOneToOne: false
      referencedRelation: "standard_schedule"
      referencedColumns: ["id"]
    }
                  ]
                },"system_state": {
                  Row: {
                    "created_at": string,"id": number,"kill_switch_changed_at": string | null,"kill_switch_changed_by": string | null,"last_daily_run_at": string | null,"last_digest_date": string | null,"last_heartbeat_at": string | null,"last_hourly_run_at": string | null,"last_hourly_status": string | null,"last_hourly_summary": Json | null,"outreach_enabled": boolean,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: number,"kill_switch_changed_at"?: string | null,"kill_switch_changed_by"?: string | null,"last_daily_run_at"?: string | null,"last_digest_date"?: string | null,"last_heartbeat_at"?: string | null,"last_hourly_run_at"?: string | null,"last_hourly_status"?: string | null,"last_hourly_summary"?: Json | null,"outreach_enabled"?: boolean,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"id"?: number,"kill_switch_changed_at"?: string | null,"kill_switch_changed_by"?: string | null,"last_daily_run_at"?: string | null,"last_digest_date"?: string | null,"last_heartbeat_at"?: string | null,"last_hourly_run_at"?: string | null,"last_hourly_status"?: string | null,"last_hourly_summary"?: Json | null,"outreach_enabled"?: boolean,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    
                  ]
                },"team_member": {
                  Row: {
                    "access_removed_at": string | null,"access_removed_by": string | null,"active": boolean,"auth_user_id": string | null,"created_at": string,"digest_channel": string,"discord_checked_at": string | null,"discord_problem": string | null,"discord_prompt_dismissed_at": string | null,"discord_status": string,"discord_user_id": string | null,"discord_username": string | null,"email": string,"id": string,"is_admin": boolean,"is_placeholder": boolean,"job_title": string | null,"last_sign_in_at": string | null,"name": string,"receives_digest": boolean,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "access_removed_at"?: string | null,"access_removed_by"?: string | null,"active"?: boolean,"auth_user_id"?: string | null,"created_at"?: string,"digest_channel"?: string,"discord_checked_at"?: string | null,"discord_problem"?: string | null,"discord_prompt_dismissed_at"?: string | null,"discord_status"?: string,"discord_user_id"?: string | null,"discord_username"?: string | null,"email": string,"id"?: string,"is_admin"?: boolean,"is_placeholder"?: boolean,"job_title"?: string | null,"last_sign_in_at"?: string | null,"name": string,"receives_digest"?: boolean,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "access_removed_at"?: string | null,"access_removed_by"?: string | null,"active"?: boolean,"auth_user_id"?: string | null,"created_at"?: string,"digest_channel"?: string,"discord_checked_at"?: string | null,"discord_problem"?: string | null,"discord_prompt_dismissed_at"?: string | null,"discord_status"?: string,"discord_user_id"?: string | null,"discord_username"?: string | null,"email"?: string,"id"?: string,"is_admin"?: boolean,"is_placeholder"?: boolean,"job_title"?: string | null,"last_sign_in_at"?: string | null,"name"?: string,"receives_digest"?: boolean,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "team_member_access_removed_by_fkey"
      columns: ["access_removed_by"]
isOneToOne: false
      referencedRelation: "team_member"
      referencedColumns: ["id"]
    }
                  ]
                },"time_proposal": {
                  Row: {
                    "created_at": string,"decided_at": string | null,"decided_by": string | null,"decision_note": string | null,"domain_id": string,"id": string,"instructor_id": string,"module_week_id": string,"note": string | null,"proposed": NonNullable<Json>,"request_id": string,"status": string,"time_version": number,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"decided_at"?: string | null,"decided_by"?: string | null,"decision_note"?: string | null,"domain_id": string,"id"?: string,"instructor_id": string,"module_week_id": string,"note"?: string | null,"proposed": NonNullable<Json>,"request_id": string,"status"?: string,"time_version": number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"decided_at"?: string | null,"decided_by"?: string | null,"decision_note"?: string | null,"domain_id"?: string,"id"?: string,"instructor_id"?: string,"module_week_id"?: string,"note"?: string | null,"proposed"?: NonNullable<Json>,"request_id"?: string,"status"?: string,"time_version"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "time_proposal_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "time_proposal_instructor_id_fkey"
      columns: ["instructor_id"]
isOneToOne: false
      referencedRelation: "instructor"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "time_proposal_module_week_id_fkey"
      columns: ["module_week_id"]
isOneToOne: false
      referencedRelation: "module_week"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "time_proposal_request_id_fkey"
      columns: ["request_id"]
isOneToOne: false
      referencedRelation: "request"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "add_break":
{ Args: { "p_accept_reason"?: string,"p_accept_warnings"?: boolean,"p_cohort_ids": (string)[],"p_domain_id": string,"p_program"?: boolean,"p_reason": string,"p_release_week_ids"?: (string)[],"p_save"?: boolean,"p_starts_on": string,"p_weeks": number }; Returns: Json
                           },
"add_checklist_item":
{ Args: { "p_class_id": string,"p_label": string }; Returns: string
                           },
"add_cohort_holiday":
{ Args: { "p_cohort_id": string,"p_date": string,"p_name": string }; Returns: Json
                           },
"add_one_class":
{ Args: { "p_accept_warnings"?: boolean,"p_class_type": string,"p_cohort_id": string,"p_date": string,"p_end": string,"p_fold"?: number,"p_module_id": string,"p_module_week_id": string,"p_reason"?: string,"p_region"?: string,"p_start": string,"p_title"?: string }; Returns: Json
                           },
"advance_test_clock":
{ Args: { "p_domain_id": string,"p_hours": number }; Returns: Json
                           },
"apply_standard":
{ Args: { "p_accept_warnings"?: boolean,"p_cohort_ids"?: (string)[],"p_reason"?: string,"p_save"?: boolean,"p_schedule_id": string }; Returns: Json
                           },
"archive_standard_schedule":
{ Args: { "p_archived": boolean,"p_id": string }; Returns: undefined
                           },
"assign_manually":
{ Args: { "p_accept_warnings"?: boolean,"p_instructor_id": string,"p_module_week_id": string,"p_note"?: string,"p_reason"?: string }; Returns: Json
                           },
"attention_ack":
{ Args: { "p_item_id": string }; Returns: undefined
                           },
"attention_assign":
{ Args: { "p_item_id": string,"p_team_member_id": string }; Returns: undefined
                           },
"attention_done":
{ Args: { "p_item_id": string,"p_note"?: string }; Returns: undefined
                           },
"beta_list_add":
{ Args: { "p_email": string,"p_note"?: string }; Returns: Json
                           },
"beta_list_remove":
{ Args: { "p_email": string }; Returns: Json
                           },
"bulk_change_weeks":
{ Args: { "p_accept_warnings"?: boolean,"p_action": string,"p_reason"?: string,"p_save"?: boolean,"p_week_ids": (string)[],"p_weeks"?: number }; Returns: Json
                           },
"cancel_class":
{ Args: { "p_class_id": string,"p_reason"?: string }; Returns: Json
                           },
"cancel_module_week":
{ Args: { "p_module_week_id": string,"p_reason"?: string }; Returns: Json
                           },
"change_class_time":
{ Args: { "p_accept_warnings"?: boolean,"p_class_id": string,"p_date": string,"p_end": string,"p_expected_version"?: number,"p_fold"?: number,"p_reason"?: string,"p_region"?: string,"p_start": string }; Returns: Json
                           },
"check_discord":
{ Args: { "p_id"?: string,"p_kind": string }; Returns: undefined
                           },
"check_discord_server":
{ Args: { "p_server_id": string }; Returns: undefined
                           },
"check_plan":
{ Args: { "p_domain_id": string,"p_rows": Json }; Returns: Json
                           },
"claim_outbound_messages":
{ Args: { "p_limit"?: number }; Returns: {
              "attempts": number,
"attention_item_id": string | null,
"audience": string,
"body_html": string | null,
"body_text": string | null,
"buttons": NonNullable<Json>,
"channel": string,
"claimed_at": string | null,
"created_at": string,
"direction": string,
"discord_channel_id": string | null,
"discord_dm_user_id": string | null,
"domain_id": string | null,
"external_id": string | null,
"from_address": string | null,
"help_request_id": string | null,
"id": string,
"in_reply_to": string | null,
"instructor_id": string | null,
"is_test": boolean,
"last_error": string | null,
"mention_user_ids": (string)[],
"module_week_id": string | null,
"not_before": string | null,
"recipient_label": string | null,
"request_id": string | null,
"sent_at": string | null,
"status": string,
"subject": string | null,
"summary": string | null,
"team_member_id": string | null,
"template_id": string,
"to_address": string | null,
"unique_key": string | null,
"updated_at": string,
"updated_by": string | null,
"version": number
            }[]
                          SetofOptions: {
        from: "*"
        to: "message"
        isOneToOne: false
        isSetofReturn: true
      } },
"cohort_schedule_status":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"complete_action":
{ Args: { "p_action_id": string,"p_error"?: string,"p_ok": boolean,"p_result"?: Json }; Returns: undefined
                           },
"configure_clock":
{ Args: { "p_enabled": boolean,"p_poke_url"?: string }; Returns: Json
                           },
"configure_environment":
{ Args: { "p_allowed_email_domain": string,"p_app_base_url"?: string,"p_environment": string,"p_response_base_url"?: string,"p_sandbox_discord_servers"?: (string)[],"p_sandbox_email_domains"?: (string)[] }; Returns: undefined
                           },
"connection_status":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"contact_instructor":
{ Args: { "p_instructor_id": string,"p_text": string }; Returns: Json
                           },
"copy_domain_settings":
{ Args: { "p_from_domain_id": string,"p_to_domain_id": string }; Returns: Json
                           },
"create_help_request":
{ Args: { "p_categories": (string)[],"p_details": string,"p_module_week_id": string,"p_reply_channel"?: string,"p_urgency"?: string }; Returns: Json
                           },
"create_module_weeks":
{ Args: { "p_accept_warnings"?: boolean,"p_domain_id": string,"p_fold"?: number,"p_reason"?: string,"p_rows": Json }; Returns: Json
                           },
"create_standard_cohorts":
{ Args: { "p_accept_warnings"?: boolean,"p_cohorts": Json,"p_fold"?: number,"p_reason"?: string,"p_schedule_id": string }; Returns: Json
                           },
"daily_jobs":
{ Args: { "p_now"?: string }; Returns: Json
                           },
"deactivate_instructor":
{ Args: { "p_decisions"?: Json,"p_instructor_id": string,"p_status"?: string }; Returns: Json
                           },
"decide_time_proposal":
{ Args: { "p_accept": boolean,"p_accept_warnings"?: boolean,"p_id": string,"p_note"?: string,"p_reason"?: string }; Returns: Json
                           },
"delete_item":
{ Args: { "p_id": string,"p_kind": string,"p_typed_name"?: string }; Returns: Json
                           },
"delete_preview":
{ Args: { "p_id": string,"p_kind": string }; Returns: Json
                           },
"discord_watchlist":
{ Args: Record<PropertyKey, never>; Returns: {
              "channel_id": string,"discord_user_id": string,"instructor_id": string,"last_message_id": string
            }[]
                           },
"domain_setup_status":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"effective_settings":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"effective_settings_for":
{ Args: { "p_scope": string,"p_scope_id": string }; Returns: Json
                           },
"engine_tick":
{ Args: { "p_domain_id": string,"p_now"?: string }; Returns: Json
                           },
"engine_tick_all":
{ Args: { "p_now"?: string }; Returns: Json
                           },
"export_snapshot":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"generate_classes":
{ Args: { "p_cohort"?: string,"p_domain_id": string,"p_region"?: string,"p_start_module_id": string,"p_week_starts": (string)[] }; Returns: Json
                           },
"get_started":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"help_ack":
{ Args: { "p_help_id": string }; Returns: undefined
                           },
"help_convert_to_cancellation":
{ Args: { "p_help_id": string }; Returns: Json
                           },
"help_reassign":
{ Args: { "p_help_id": string,"p_team_member_id": string }; Returns: undefined
                           },
"help_reply":
{ Args: { "p_help_id": string,"p_resolves"?: boolean,"p_text": string }; Returns: Json
                           },
"help_set_status":
{ Args: { "p_help_id": string,"p_note": string,"p_status": string }; Returns: undefined
                           },
"hook_before_user_created":
{ Args: { "event": Json }; Returns: Json
                           },
"jump_test_clock":
{ Args: { "p_days_before": number,"p_domain_id": string,"p_module_week_id": string }; Returns: Json
                           },
"keep_class_on_holiday":
{ Args: { "p_class_id": string,"p_reason": string }; Returns: undefined
                           },
"log_app_error":
{ Args: { "p_browser"?: string,"p_detail"?: string,"p_message": string,"p_page"?: string }; Returns: undefined
                           },
"log_export":
{ Args: { "p_domain_id"?: string,"p_filters"?: Json,"p_rows": number,"p_what": string }; Returns: undefined
                           },
"log_system_error":
{ Args: { "p_message": string,"p_url"?: string,"p_workflow": string }; Returns: undefined
                           },
"mark_verified_manually":
{ Args: { "p_instructor_id": string,"p_note"?: string }; Returns: undefined
                           },
"merge_cohorts":
{ Args: { "p_accept_warnings"?: boolean,"p_cancel"?: (string)[],"p_cohort_ids": (string)[],"p_date": string,"p_keep"?: (string)[],"p_name": string,"p_order_from": string,"p_reason"?: string,"p_region": string,"p_save"?: boolean,"p_sequence_from": string }; Returns: Json
                           },
"message_templates":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"module_overview":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"my_account":
{ Args: { "p_signed_in"?: boolean }; Returns: Json
                           },
"n8n_runs_this_month":
{ Args: { "p_now"?: string }; Returns: number
                           },
"next_actions":
{ Args: { "p_limit"?: number }; Returns: {
              "action": string,
"created_at": string,
"error": string | null,
"id": string,
"payload": NonNullable<Json>,
"processed_at": string | null,
"requested_by": string | null,
"result": Json | null,
"status": string,
"updated_at": string,
"updated_by": string | null,
"version": number
            }[]
                          SetofOptions: {
        from: "*"
        to: "action_queue"
        isOneToOne: false
        isSetofReturn: true
      } },
"next_discord_lookups":
{ Args: { "p_limit"?: number }; Returns: Json
                           },
"pause_outreach":
{ Args: { "p_module_week_id": string,"p_paused": boolean }; Returns: undefined
                           },
"planned_instructors_for_domain":
{ Args: { "p_domain_id": string,"p_part"?: number,"p_parts"?: number }; Returns: Json
                           },
"planned_instructors":
{ Args: { "p_module_week_ids": (string)[] }; Returns: Json
                           },
"preview_message_template":
{ Args: { "p_body": string,"p_domain_id": string,"p_subject": string,"p_template_id": string }; Returns: Json
                           },
"next_in_line_many":
{ Args: { "p_module_week_ids": string[] }; Returns: Json
                           },
"preview_next_many":
{ Args: { "p_module_week_ids": string[] }; Returns: Json
                           },
"preview_next":
{ Args: { "p_module_week_id": string }; Returns: Json
                           },
"preview_standard_cohorts":
{ Args: { "p_cohorts": Json,"p_schedule_id": string }; Returns: Json
                           },
"pt_to_utc":
{ Args: { "p_date": string,"p_time": string }; Returns: string
                           },
"ranking_impact":
{ Args: { "p_cohort_id"?: string,"p_instructor_ids": (string)[],"p_module_id": string }; Returns: Json
                           },
"record_bounce":
{ Args: { "p_detail"?: string,"p_email": string,"p_external_id"?: string,"p_report"?: boolean,"p_thread_id"?: string }; Returns: Json
                           },
"record_discord_result":
{ Args: { "p_action_id": string,"p_result": Json }; Returns: Json
                           },
"record_inbound_message":
{ Args: { "p_body": string,"p_channel": string,"p_external_id": string,"p_from": string,"p_received_at"?: string,"p_subject": string,"p_summary"?: string }; Returns: Json
                           },
"record_offline_confirmation":
{ Args: { "p_accept_warnings"?: boolean,"p_instructor_id": string,"p_module_week_id": string,"p_note"?: string,"p_reason"?: string }; Returns: Json
                           },
"record_response":
{ Args: { "p_answer"?: string,"p_token": string }; Returns: Json
                           },
"release_booking":
{ Args: { "p_module_week_id": string,"p_reason"?: string,"p_restart"?: boolean }; Returns: Json
                           },
"remove_break":
{ Args: { "p_accept_reason"?: string,"p_accept_warnings"?: boolean,"p_break_id"?: string,"p_program_break_id"?: string,"p_release_week_ids"?: (string)[],"p_save"?: boolean }; Returns: Json
                           },
"remove_checklist_item":
{ Args: { "p_item_id": string }; Returns: undefined
                           },
"remove_cohort_holiday":
{ Args: { "p_id": string }; Returns: undefined
                           },
"reply_to_instructor":
{ Args: { "p_item_id": string,"p_text": string }; Returns: Json
                           },
"report_message_result":
{ Args: { "p_error"?: string,"p_external_id"?: string,"p_message_id": string,"p_ok": boolean,"p_permanent"?: boolean }; Returns: Json
                           },
"resolve_message_check":
{ Args: { "p_arrived": boolean,"p_message_id": string }; Returns: Json
                           },
"resend_message":
{ Args: { "p_message_id": string }; Returns: Json
                           },
"reset_message_template":
{ Args: { "p_domain_id": string,"p_template_id": string }; Returns: undefined
                           },
"reset_sandbox_data":
{ Args: { "p_confirm": string }; Returns: Json
                           },
"reset_setting":
{ Args: { "p_domain_id": string,"p_key": string }; Returns: undefined
                           },
"reset_setting_at":
{ Args: { "p_key": string,"p_scope": string,"p_scope_id": string }; Returns: undefined
                           },
"reset_to_standard":
{ Args: { "p_accept_warnings"?: boolean,"p_cohort_id"?: string,"p_module_week_ids"?: (string)[],"p_reason"?: string,"p_save"?: boolean }; Returns: Json
                           },
"response_page":
{ Args: { "p_token": string }; Returns: unknown
                           },
"response_page_text":
{ Args: { "p_token": string }; Returns: string
                           },
"restore_module_week":
{ Args: { "p_module_week_id": string }; Returns: Json
                           },
"run_check_now":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"run_practice_class":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"save_message_template":
{ Args: { "p_body": string,"p_domain_id": string,"p_subject": string,"p_template_id": string }; Returns: undefined
                           },
"save_ranking":
{ Args: { "p_cohort_id"?: string,"p_expected_ids"?: (string)[],"p_instructor_ids": (string)[],"p_module_id": string }; Returns: undefined
                           },
"save_standard_schedule":
{ Args: { "p_breaks"?: Json,"p_domain_id": string,"p_expected_version"?: number,"p_id": string,"p_module_ids": (string)[],"p_name": string,"p_notes"?: string }; Returns: Json
                           },
"schedule_board":
{ Args: { "p_domain_id": string,"p_from": string,"p_to": string }; Returns: Json
                           },
"schedule_problems":
{ Args: { "p_module_week_ids": (string)[] }; Returns: Json
                           },
"send_connection_test":
{ Args: { "p_channel": string }; Returns: Json
                           },
"send_template_test":
{ Args: { "p_body": string,"p_domain_id": string,"p_subject": string,"p_template_id": string }; Returns: undefined
                           },
"send_test_alert":
{ Args: { "p_team_member_id": string }; Returns: undefined
                           },
"send_test_message":
{ Args: { "p_instructor_id": string }; Returns: Json
                           },
"domain_status_problems":
{ Args: { "p_domain_id": string,"p_status": string }; Returns: Json
                           },
"release_discord_account":
{ Args: { "p_instructor_id": string }; Returns: Json
                           },
"request_channel_refresh":
{ Args: { "p_domain_id"?: string }; Returns: Json
                           },
"send_welcome_message":
{ Args: { "p_domain_id"?: string,"p_instructor_id": string }; Returns: string
                           },
"set_admin":
{ Args: { "p_admin": boolean,"p_team_member_id": string }; Returns: Json
                           },
"set_beta_list_recipients":
{ Args: { "p_on": boolean }; Returns: Json
                           },
"set_app_config":
{ Args: { "p_config": Json }; Returns: undefined
                           },
"set_archived":
{ Args: { "p_archived": boolean,"p_id": string,"p_kind": string }; Returns: Json
                           },
"set_checklist_item":
{ Args: { "p_done": boolean,"p_item_id": string }; Returns: undefined
                           },
"set_discord_cursor":
{ Args: { "p_channel_id": string,"p_last_message_id": string }; Returns: undefined
                           },
"set_discord_server_access":
{ Args: { "p_access": string,"p_domain_ids"?: (string)[],"p_server_id": string }; Returns: Json
                           },
"set_domain_discord_server":
{ Args: { "p_domain_id": string,"p_server_id": string }; Returns: undefined
                           },
"set_domain_status":
{ Args: { "p_domain_id": string,"p_status": string }; Returns: undefined
                           },
"check_instructor_channel":
{ Args: { "p_channel": string,"p_domain_id": string,"p_instructor_id": string }; Returns: Json
                           },
"set_instructor_channel":
{ Args: { "p_channel_id": string,"p_domain_id": string,"p_instructor_id": string }; Returns: undefined
                           },
"set_kill_switch":
{ Args: { "p_outreach_enabled": boolean }; Returns: undefined
                           },
"set_member_access":
{ Args: { "p_has_access": boolean,"p_reason"?: string,"p_team_member_id": string }; Returns: undefined
                           },
"set_outreach_queue":
{ Args: { "p_decision"?: string,"p_end_behaviour"?: string,"p_instructor_ids"?: (string)[],"p_mode": string,"p_module_week_id": string,"p_start_now"?: boolean }; Returns: Json
                           },
"set_recipient_rules":
{ Args: { "p_daily_email_cap"?: number,"p_email_domains": (string)[],"p_message_recipients": string }; Returns: undefined
                           },
"set_setting":
{ Args: { "p_domain_id": string,"p_key": string,"p_value": Json }; Returns: undefined
                           },
"set_setting_at":
{ Args: { "p_key": string,"p_reason"?: string,"p_scope": string,"p_scope_id": string,"p_value": Json }; Returns: undefined
                           },
"set_settings_at":
{ Args: { "p_reason"?: string,"p_scope": string,"p_scope_id": string,"p_values": Json }; Returns: undefined
                           },
"set_sign_in_mode":
{ Args: { "p_mode": string }; Returns: undefined
                           },
"set_test_clock":
{ Args: { "p_at": string,"p_domain_id": string }; Returns: undefined
                           },
"set_test_targets":
{ Args: { "p_domain_id": string,"p_test_discord_channel_id": string,"p_test_email": string }; Returns: undefined
                           },
"set_week_same_instructor":
{ Args: { "p_module_week_id": string,"p_on": boolean,"p_reason"?: string }; Returns: Json
                           },
"share_class_weeks":
{ Args: { "p_accept_warnings"?: boolean,"p_guest_ids": (string)[],"p_host_id": string,"p_reason"?: string,"p_release_instructors"?: boolean,"p_save"?: boolean,"p_times_from"?: string }; Returns: Json
                           },
"shift_classes":
{ Args: { "p_include_later"?: boolean,"p_module_week_id": string,"p_weeks": number }; Returns: Json
                           },
"skip_to_next":
{ Args: { "p_module_week_id": string }; Returns: Json
                           },
"standard_compare":
{ Args: { "p_module_week_id": string }; Returns: Json
                           },
"start_asking_now":
{ Args: { "p_module_week_id": string }; Returns: Json
                           },
"stop_sharing":
{ Args: { "p_module_week_id": string }; Returns: Json
                           },
"submit_help_request":
{ Args: { "p_categories": (string)[],"p_details": string,"p_reply_channel": string,"p_token": string,"p_urgency": string }; Returns: Json
                           },
"submit_response_page":
{ Args: { "p_form"?: Json,"p_token": string }; Returns: unknown
                           },
"submit_response_page_text":
{ Args: { "p_form"?: Json,"p_token": string }; Returns: string
                           },
"suggest_cohort_name":
{ Args: { "p_domain_id": string,"p_first_date": string }; Returns: string
                           },
"team_assignments":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"time_proposal_preview":
{ Args: { "p_id": string }; Returns: Json
                           },
"undo_cohort_merge":
{ Args: { "p_merge_id": string }; Returns: Json
                           },
"undo_history_event":
{ Args: { "p_event_id": number }; Returns: Json
                           },
"undoable":
{ Args: { "e": Omit<Database["public"]['Tables']["history_event"]['Row'], Database["public"]['Tables']["history_event"]['ComputedFields']> }; Returns: boolean
                           },
"update_class_details":
{ Args: { "p_class_id": string,"p_class_type": string,"p_expected_version"?: number,"p_notes": string,"p_problem_flag": boolean,"p_title": string }; Returns: undefined
                           },
"update_my_profile":
{ Args: { "p_discord_username"?: string,"p_dismiss_discord_prompt"?: boolean }; Returns: undefined
                           },
"usage_summary":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"week_eligibility":
{ Args: { "p_module_week_id": string }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            
          }
        }
} as const
