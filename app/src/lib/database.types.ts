
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "public": {
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
                    "admin_discord_channel_id": string | null,"app_base_url": string | null,"company_email_domain": string,"created_at": string,"discord_guild_id": string | null,"environment": string,"id": number,"response_base_url": string | null,"sandbox_allowed_discord_servers": (string)[],"sandbox_allowed_email_domains": (string)[],"scheduling_email": string | null,"scheduling_sender_name": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "admin_discord_channel_id"?: string | null,"app_base_url"?: string | null,"company_email_domain"?: string,"created_at"?: string,"discord_guild_id"?: string | null,"environment"?: string,"id"?: number,"response_base_url"?: string | null,"sandbox_allowed_discord_servers"?: (string)[],"sandbox_allowed_email_domains"?: (string)[],"scheduling_email"?: string | null,"scheduling_sender_name"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "admin_discord_channel_id"?: string | null,"app_base_url"?: string | null,"company_email_domain"?: string,"created_at"?: string,"discord_guild_id"?: string | null,"environment"?: string,"id"?: number,"response_base_url"?: string | null,"sandbox_allowed_discord_servers"?: (string)[],"sandbox_allowed_email_domains"?: (string)[],"scheduling_email"?: string | null,"scheduling_sender_name"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
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
                    "class_type": string,"cohort_id": string | null,"created_at": string,"day_offset": number,"duration_minutes": number,"id": string,"module_id": string,"sort_order": number,"start_time_pt": string,"title_template": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "class_type": string,"cohort_id"?: string | null,"created_at"?: string,"day_offset": number,"duration_minutes": number,"id"?: string,"module_id": string,"sort_order"?: number,"start_time_pt": string,"title_template"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "class_type"?: string,"cohort_id"?: string | null,"created_at"?: string,"day_offset"?: number,"duration_minutes"?: number,"id"?: string,"module_id"?: string,"sort_order"?: number,"start_time_pt"?: string,"title_template"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
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
                    "cancelled_reason": string | null,"class_type": string,"created_at": string,"ends_at": string,"id": string,"module_week_id": string,"notes": string | null,"pattern_item_id": string | null,"problem_flag": boolean,"starts_at": string,"status": string,"title": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "cancelled_reason"?: string | null,"class_type": string,"created_at"?: string,"ends_at": string,"id"?: string,"module_week_id": string,"notes"?: string | null,"pattern_item_id"?: string | null,"problem_flag"?: boolean,"starts_at": string,"status"?: string,"title": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "cancelled_reason"?: string | null,"class_type"?: string,"created_at"?: string,"ends_at"?: string,"id"?: string,"module_week_id"?: string,"notes"?: string | null,"pattern_item_id"?: string | null,"problem_flag"?: boolean,"starts_at"?: string,"status"?: string,"title"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
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
                },"cohort": {
                  Row: {
                    "created_at": string,"domain_id": string,"id": string,"name": string,"notes": string | null,"start_date": string | null,"status": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"domain_id": string,"id"?: string,"name": string,"notes"?: string | null,"start_date"?: string | null,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"domain_id"?: string,"id"?: string,"name"?: string,"notes"?: string | null,"start_date"?: string | null,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "cohort_domain_id_fkey"
      columns: ["domain_id"]
isOneToOne: false
      referencedRelation: "domain"
      referencedColumns: ["id"]
    }
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
                },"domain": {
                  Row: {
                    "alert_discord_channel_id": string | null,"created_at": string,"id": string,"name": string,"paused_from": string | null,"status": string,"test_clock_at": string | null,"test_discord_channel_id": string | null,"test_email": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "alert_discord_channel_id"?: string | null,"created_at"?: string,"id"?: string,"name": string,"paused_from"?: string | null,"status"?: string,"test_clock_at"?: string | null,"test_discord_channel_id"?: string | null,"test_email"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "alert_discord_channel_id"?: string | null,"created_at"?: string,"id"?: string,"name"?: string,"paused_from"?: string | null,"status"?: string,"test_clock_at"?: string | null,"test_discord_channel_id"?: string | null,"test_email"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
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
                    "created_at": string,"date": string,"domain_id": string | null,"id": string,"name": string,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"date": string,"domain_id"?: string | null,"id"?: string,"name": string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"date"?: string,"domain_id"?: string | null,"id"?: string,"name"?: string,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
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
                    "created_at": string,"discord_channel_id": string | null,"discord_channel_link": string | null,"discord_failed_at": string | null,"discord_server_id": string | null,"discord_user_id": string | null,"email_bounced_at": string | null,"full_name": string,"id": string,"is_test": boolean,"last_response_at": string | null,"monthly_class_limit": number | null,"notes": string | null,"phone": string | null,"preferred_contact": string,"primary_email": string,"status": string,"updated_at": string,"updated_by": string | null,"verified_at": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"discord_channel_id"?: string | null,"discord_channel_link"?: string | null,"discord_failed_at"?: string | null,"discord_server_id"?: string | null,"discord_user_id"?: string | null,"email_bounced_at"?: string | null,"full_name": string,"id"?: string,"is_test"?: boolean,"last_response_at"?: string | null,"monthly_class_limit"?: number | null,"notes"?: string | null,"phone"?: string | null,"preferred_contact"?: string,"primary_email": string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"verified_at"?: string | null,"version"?: number
                  }
                  Update: {
                    "created_at"?: string,"discord_channel_id"?: string | null,"discord_channel_link"?: string | null,"discord_failed_at"?: string | null,"discord_server_id"?: string | null,"discord_user_id"?: string | null,"email_bounced_at"?: string | null,"full_name"?: string,"id"?: string,"is_test"?: boolean,"last_response_at"?: string | null,"monthly_class_limit"?: number | null,"notes"?: string | null,"phone"?: string | null,"preferred_contact"?: string,"primary_email"?: string,"status"?: string,"updated_at"?: string,"updated_by"?: string | null,"verified_at"?: string | null,"version"?: number
                  }
                  Relationships: [
                    
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
                    "attempts": number,"attention_item_id": string | null,"audience": string,"body_html": string | null,"body_text": string | null,"buttons": NonNullable<Json>,"channel": string,"claimed_at": string | null,"created_at": string,"direction": string,"discord_channel_id": string | null,"discord_dm_user_id": string | null,"domain_id": string | null,"external_id": string | null,"from_address": string | null,"help_request_id": string | null,"id": string,"in_reply_to": string | null,"instructor_id": string | null,"is_test": boolean,"last_error": string | null,"mention_user_ids": (string)[],"module_week_id": string | null,"not_before": string | null,"recipient_label": string | null,"request_id": string | null,"sent_at": string | null,"status": string,"subject": string | null,"summary": string | null,"team_member_id": string | null,"template_id": string,"to_address": string | null,"unique_key": string | null,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "attempts"?: number,"attention_item_id"?: string | null,"audience": string,"body_html"?: string | null,"body_text"?: string | null,"buttons"?: NonNullable<Json>,"channel": string,"claimed_at"?: string | null,"created_at"?: string,"direction"?: string,"discord_channel_id"?: string | null,"discord_dm_user_id"?: string | null,"domain_id"?: string | null,"external_id"?: string | null,"from_address"?: string | null,"help_request_id"?: string | null,"id"?: string,"in_reply_to"?: string | null,"instructor_id"?: string | null,"is_test"?: boolean,"last_error"?: string | null,"mention_user_ids"?: (string)[],"module_week_id"?: string | null,"not_before"?: string | null,"recipient_label"?: string | null,"request_id"?: string | null,"sent_at"?: string | null,"status"?: string,"subject"?: string | null,"summary"?: string | null,"team_member_id"?: string | null,"template_id": string,"to_address"?: string | null,"unique_key"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "attempts"?: number,"attention_item_id"?: string | null,"audience"?: string,"body_html"?: string | null,"body_text"?: string | null,"buttons"?: NonNullable<Json>,"channel"?: string,"claimed_at"?: string | null,"created_at"?: string,"direction"?: string,"discord_channel_id"?: string | null,"discord_dm_user_id"?: string | null,"domain_id"?: string | null,"external_id"?: string | null,"from_address"?: string | null,"help_request_id"?: string | null,"id"?: string,"in_reply_to"?: string | null,"instructor_id"?: string | null,"is_test"?: boolean,"last_error"?: string | null,"mention_user_ids"?: (string)[],"module_week_id"?: string | null,"not_before"?: string | null,"recipient_label"?: string | null,"request_id"?: string | null,"sent_at"?: string | null,"status"?: string,"subject"?: string | null,"summary"?: string | null,"team_member_id"?: string | null,"template_id"?: string,"to_address"?: string | null,"unique_key"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
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
                    "at_risk": boolean,"at_risk_reason": string | null,"cohort": string,"cohort_id": string,"created_at": string,"domain_id": string,"first_class_at": string | null,"id": string,"last_class_end_at": string | null,"manual_end_behaviour": string,"module_id": string,"outreach_mode": string,"outreach_started_at": string | null,"owner_checkin_sent_at": string | null,"paused": boolean,"readiness_checked_at": string | null,"readiness_escalated_at": string | null,"readiness_problems": Json | null,"same_instructor": boolean,"seq": number,"split_group": string | null,"status": string,"time_version": number,"updated_at": string,"updated_by": string | null,"version": number,"week_start_date": string
                  }
                  ComputedFields: never
                  Insert: {
                    "at_risk"?: boolean,"at_risk_reason"?: string | null,"cohort"?: string,"cohort_id": string,"created_at"?: string,"domain_id": string,"first_class_at"?: string | null,"id"?: string,"last_class_end_at"?: string | null,"manual_end_behaviour"?: string,"module_id": string,"outreach_mode"?: string,"outreach_started_at"?: string | null,"owner_checkin_sent_at"?: string | null,"paused"?: boolean,"readiness_checked_at"?: string | null,"readiness_escalated_at"?: string | null,"readiness_problems"?: Json | null,"same_instructor": boolean,"seq"?: number,"split_group"?: string | null,"status"?: string,"time_version"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"week_start_date": string
                  }
                  Update: {
                    "at_risk"?: boolean,"at_risk_reason"?: string | null,"cohort"?: string,"cohort_id"?: string,"created_at"?: string,"domain_id"?: string,"first_class_at"?: string | null,"id"?: string,"last_class_end_at"?: string | null,"manual_end_behaviour"?: string,"module_id"?: string,"outreach_mode"?: string,"outreach_started_at"?: string | null,"owner_checkin_sent_at"?: string | null,"paused"?: boolean,"readiness_checked_at"?: string | null,"readiness_escalated_at"?: string | null,"readiness_problems"?: Json | null,"same_instructor"?: boolean,"seq"?: number,"split_group"?: string | null,"status"?: string,"time_version"?: number,"updated_at"?: string,"updated_by"?: string | null,"version"?: number,"week_start_date"?: string
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
                    "access_removed_at": string | null,"access_removed_by": string | null,"active": boolean,"auth_user_id": string | null,"created_at": string,"digest_channel": string,"discord_prompt_dismissed_at": string | null,"discord_user_id": string | null,"email": string,"id": string,"is_placeholder": boolean,"job_title": string | null,"last_sign_in_at": string | null,"name": string,"receives_digest": boolean,"updated_at": string,"updated_by": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "access_removed_at"?: string | null,"access_removed_by"?: string | null,"active"?: boolean,"auth_user_id"?: string | null,"created_at"?: string,"digest_channel"?: string,"discord_prompt_dismissed_at"?: string | null,"discord_user_id"?: string | null,"email": string,"id"?: string,"is_placeholder"?: boolean,"job_title"?: string | null,"last_sign_in_at"?: string | null,"name": string,"receives_digest"?: boolean,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
                  }
                  Update: {
                    "access_removed_at"?: string | null,"access_removed_by"?: string | null,"active"?: boolean,"auth_user_id"?: string | null,"created_at"?: string,"digest_channel"?: string,"discord_prompt_dismissed_at"?: string | null,"discord_user_id"?: string | null,"email"?: string,"id"?: string,"is_placeholder"?: boolean,"job_title"?: string | null,"last_sign_in_at"?: string | null,"name"?: string,"receives_digest"?: boolean,"updated_at"?: string,"updated_by"?: string | null,"version"?: number
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
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "add_checklist_item":
{ Args: { "p_class_id": string,"p_label": string }; Returns: string
                           },
"add_one_class":
{ Args: { "p_accept_warnings"?: boolean,"p_class_type": string,"p_cohort_id": string,"p_date": string,"p_end": string,"p_module_id": string,"p_module_week_id": string,"p_reason"?: string,"p_start": string,"p_title"?: string }; Returns: Json
                           },
"advance_test_clock":
{ Args: { "p_domain_id": string,"p_hours": number }; Returns: Json
                           },
"assign_manually":
{ Args: { "p_instructor_id": string,"p_module_week_id": string,"p_note"?: string }; Returns: Json
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
"cancel_class":
{ Args: { "p_class_id": string,"p_reason"?: string }; Returns: Json
                           },
"cancel_module_week":
{ Args: { "p_module_week_id": string,"p_reason"?: string }; Returns: Json
                           },
"change_class_time":
{ Args: { "p_class_id": string,"p_date": string,"p_end": string,"p_expected_version"?: number,"p_start": string }; Returns: Json
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
"complete_action":
{ Args: { "p_action_id": string,"p_error"?: string,"p_ok": boolean,"p_result"?: Json }; Returns: undefined
                           },
"configure_environment":
{ Args: { "p_allowed_email_domain": string,"p_environment": string,"p_sandbox_discord_servers"?: (string)[],"p_sandbox_email_domains"?: (string)[] }; Returns: undefined
                           },
"connection_status":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"copy_domain_settings":
{ Args: { "p_from_domain_id": string,"p_to_domain_id": string }; Returns: Json
                           },
"create_help_request":
{ Args: { "p_categories": (string)[],"p_details": string,"p_module_week_id": string,"p_reply_channel"?: string,"p_urgency"?: string }; Returns: Json
                           },
"create_module_weeks":
{ Args: { "p_accept_warnings"?: boolean,"p_domain_id": string,"p_reason"?: string,"p_rows": Json }; Returns: Json
                           },
"daily_jobs":
{ Args: { "p_now"?: string }; Returns: Json
                           },
"deactivate_instructor":
{ Args: { "p_decisions"?: Json,"p_instructor_id": string,"p_status"?: string }; Returns: Json
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
{ Args: { "p_cohort"?: string,"p_domain_id": string,"p_start_module_id": string,"p_week_starts": (string)[] }; Returns: Json
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
"message_templates":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"module_overview":
{ Args: { "p_domain_id": string }; Returns: Json
                           },
"my_account":
{ Args: { "p_signed_in"?: boolean }; Returns: Json
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
"pause_outreach":
{ Args: { "p_module_week_id": string,"p_paused": boolean }; Returns: undefined
                           },
"preview_message_template":
{ Args: { "p_body": string,"p_domain_id": string,"p_subject": string,"p_template_id": string }; Returns: Json
                           },
"preview_next":
{ Args: { "p_module_week_id": string }; Returns: Json
                           },
"pt_to_utc":
{ Args: { "p_date": string,"p_time": string }; Returns: string
                           },
"ranking_impact":
{ Args: { "p_cohort_id"?: string,"p_instructor_ids": (string)[],"p_module_id": string }; Returns: Json
                           },
"record_bounce":
{ Args: { "p_detail"?: string,"p_email": string,"p_external_id"?: string }; Returns: Json
                           },
"record_inbound_message":
{ Args: { "p_body": string,"p_channel": string,"p_external_id": string,"p_from": string,"p_received_at"?: string,"p_subject": string,"p_summary"?: string }; Returns: Json
                           },
"record_offline_confirmation":
{ Args: { "p_instructor_id": string,"p_module_week_id": string,"p_note"?: string }; Returns: Json
                           },
"record_response":
{ Args: { "p_answer"?: string,"p_token": string }; Returns: Json
                           },
"release_booking":
{ Args: { "p_module_week_id": string,"p_reason"?: string,"p_restart"?: boolean }; Returns: Json
                           },
"remove_checklist_item":
{ Args: { "p_item_id": string }; Returns: undefined
                           },
"reply_to_instructor":
{ Args: { "p_item_id": string,"p_text": string }; Returns: Json
                           },
"report_message_result":
{ Args: { "p_error"?: string,"p_external_id"?: string,"p_message_id": string,"p_ok": boolean,"p_permanent"?: boolean }; Returns: Json
                           },
"resend_message":
{ Args: { "p_message_id": string }; Returns: Json
                           },
"reset_message_template":
{ Args: { "p_domain_id": string,"p_template_id": string }; Returns: undefined
                           },
"reset_sandbox_data":
{ Args: { "p_confirm": string,"p_test_channel_id"?: string,"p_test_discord_user_id"?: string,"p_test_email"?: string }; Returns: Json
                           },
"reset_setting":
{ Args: { "p_domain_id": string,"p_key": string }; Returns: undefined
                           },
"reset_setting_at":
{ Args: { "p_key": string,"p_scope": string,"p_scope_id": string }; Returns: undefined
                           },
"response_page":
{ Args: { "p_token": string }; Returns: unknown
                           },
"response_page_text":
{ Args: { "p_token": string }; Returns: string
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
"send_template_test":
{ Args: { "p_body": string,"p_domain_id": string,"p_subject": string,"p_template_id": string }; Returns: undefined
                           },
"send_test_alert":
{ Args: { "p_team_member_id": string }; Returns: undefined
                           },
"send_test_message":
{ Args: { "p_instructor_id": string }; Returns: Json
                           },
"set_app_config":
{ Args: { "p_config": Json }; Returns: undefined
                           },
"set_checklist_item":
{ Args: { "p_done": boolean,"p_item_id": string }; Returns: undefined
                           },
"set_discord_cursor":
{ Args: { "p_channel_id": string,"p_last_message_id": string }; Returns: undefined
                           },
"set_domain_status":
{ Args: { "p_domain_id": string,"p_status": string }; Returns: undefined
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
"set_setting":
{ Args: { "p_domain_id": string,"p_key": string,"p_value": Json }; Returns: undefined
                           },
"set_setting_at":
{ Args: { "p_key": string,"p_reason"?: string,"p_scope": string,"p_scope_id": string,"p_value": Json }; Returns: undefined
                           },
"set_settings_at":
{ Args: { "p_reason"?: string,"p_scope": string,"p_scope_id": string,"p_values": Json }; Returns: undefined
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
"shift_classes":
{ Args: { "p_include_later"?: boolean,"p_module_week_id": string,"p_weeks": number }; Returns: Json
                           },
"skip_to_next":
{ Args: { "p_module_week_id": string }; Returns: Json
                           },
"start_asking_now":
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
{ Args: { "p_discord_user_id"?: string,"p_dismiss_discord_prompt"?: boolean }; Returns: undefined
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
  "public": {
          Enums: {
            
          }
        }
} as const
