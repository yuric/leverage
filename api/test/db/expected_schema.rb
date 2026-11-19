# The tables the migrations must build, as data: every table, column, index,
# unique constraint and foreign key. schema_test.rb compares the database
# with it. The PRD's Data model is the requirement (docs/PRD.md, "Data
# model"); the choices for what it leaves open are in the milestone plan
# (DB-1 to DB-47) and in api/contract/README.md.
#
# Types are spelled as PostgreSQL's format_type prints them; defaults as
# pg_get_expr prints them. Index WHERE clauses are compared as
# pg_get_indexdef prints them.
module ExpectedSchema
  TZ = "timestamp with time zone".freeze
  MONEY = "numeric(14,6)".freeze
  NOW = "CURRENT_TIMESTAMP".freeze

  # Column: [type, nullable, default].
  def self.col(type, null: false, default: nil)
    [ type, null, default ].freeze
  end

  def self.uuid(null: false) = col("uuid", null: null)
  def self.text(null: false, default: nil) = col("text", null: null, default: default)
  def self.int(null: false, default: nil) = col("integer", null: null, default: default)
  def self.bool(default) = col("boolean", default: default)
  def self.time(null: true) = col(TZ, null: null)
  def self.jsonb(null: false, default: nil) = col("jsonb", null: null, default: default)
  def self.money(null: true, default: nil) = col(MONEY, null: null, default: default)

  ID = { "id" => col("uuid", default: "gen_random_uuid()") }.freeze
  OWNED = ID.merge("workspace_id" => uuid).freeze
  CREATED = { "created_at" => col(TZ, default: NOW) }.freeze
  STAMPS = CREATED.merge("updated_at" => col(TZ, default: NOW)).freeze

  # Index: [columns, unique, where, nulls_not_distinct]. Primary keys are not
  # listed; the indexes behind unique constraints are.
  def self.idx(*columns, unique: false, where: nil, nulls_not_distinct: false)
    [ columns.freeze, unique, where, nulls_not_distinct ].freeze
  end

  # Foreign key: [column, referenced table, on delete].
  def self.fk(column, table, on_delete: :restrict)
    [ column, table, on_delete ].freeze
  end

  TABLES = {
    "workspaces" => {
      columns: ID.merge(
        "lease_length_seconds" => int(default: "3600"),
        "check_queue_timeout_seconds" => int(default: "120"),
        "check_run_timeout_seconds" => int(default: "300"),
        "maximum_rounds" => int(default: "3"),
        "rerun_limit" => int(default: "3"),
        "recovery_time_ceiling_seconds" => int(null: true),
        "last_seq" => col("bigint", default: "0")
      ).merge(STAMPS),
      indexes: [],
      foreign_keys: []
    },
    "users" => {
      columns: OWNED.merge(
        "email_address" => text,
        "password_digest" => text
      ).merge(STAMPS),
      indexes: [ idx("workspace_id", unique: true), idx("email_address", unique: true) ],
      foreign_keys: [ fk("workspace_id", "workspaces") ]
    },
    "sessions" => {
      columns: OWNED.merge(
        "user_id" => uuid,
        "token_hash" => text,
        "last_used_at" => time
      ).merge(STAMPS),
      indexes: [ idx("workspace_id"), idx("user_id"), idx("token_hash", unique: true) ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("user_id", "users", on_delete: :cascade) ]
    },
    "credentials" => {
      columns: OWNED.merge(
        "kind" => text,
        "provider" => text,
        "name" => text,
        "masked_label" => text(null: true),
        "plan" => text(null: true),
        "account_email" => text(null: true),
        "state" => text(default: "'active'::text"),
        "limited_until" => time,
        "position" => int,
        "model" => text(null: true),
        "effort" => text(null: true),
        "strength_rank" => int(null: true),
        "last_verified_at" => time
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id", "kind", "provider", "name", unique: true),
        idx("workspace_id", "position", unique: true),
        idx("workspace_id", unique: true, where: "((provider = 'gemini'::text) AND (kind = 'login'::text))")
      ],
      foreign_keys: [ fk("workspace_id", "workspaces") ],
      deferrable_uniques: [ %w[workspace_id position] ]
    },
    "credential_readings" => {
      columns: OWNED.merge(
        "credential_id" => uuid,
        "observed_at" => time(null: false),
        "state" => text,
        "figures" => jsonb(default: "'[]'::jsonb"),
        "resets" => jsonb(null: true),
        "tool_version" => text(null: true)
      ).merge(CREATED),
      indexes: [ idx("workspace_id"), idx("credential_id", "observed_at") ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("credential_id", "credentials", on_delete: :cascade) ]
    },
    "helpers" => {
      columns: OWNED.merge(
        "name" => text,
        "token_hash" => text,
        "last_reported_at" => time
      ).merge(STAMPS),
      indexes: [ idx("workspace_id", unique: true), idx("token_hash", unique: true) ],
      foreign_keys: [ fk("workspace_id", "workspaces") ]
    },
    "seats" => {
      columns: OWNED.merge(
        "name" => text,
        "provider" => text,
        "model" => text,
        "effort" => text,
        "role" => text,
        "strength_rank" => int,
        "credential_id" => uuid(null: true),
        "enabled" => bool("true"),
        "paused" => bool("false"),
        "token_hash" => text(null: true),
        "last_polled_at" => time,
        "run_state" => text(null: true),
        "removed_at" => time
      ).merge(STAMPS),
      indexes: [ idx("workspace_id"), idx("credential_id"), idx("token_hash", unique: true) ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("credential_id", "credentials") ]
    },
    "helper_requests" => {
      columns: OWNED.merge(
        "kind" => text,
        "seat_id" => uuid(null: true),
        "credential_id" => uuid(null: true),
        "state" => text(default: "'queued'::text"),
        "requested_at" => time(null: false),
        "picked_up_at" => time,
        "finished_at" => time,
        "result" => jsonb(null: true)
      ).merge(STAMPS),
      indexes: [ idx("workspace_id"), idx("seat_id") ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("seat_id", "seats") ]
    },
    "projects" => {
      columns: OWNED.merge(
        "name" => text(null: true),
        "goal" => text(null: true),
        "budget" => money,
        "spent" => money(null: false, default: "0.0"),
        "paused" => bool("false"),
        "brief_version" => int(default: "0"),
        "content_deleted_at" => time
      ).merge(STAMPS),
      indexes: [ idx("workspace_id") ],
      foreign_keys: [ fk("workspace_id", "workspaces") ]
    },
    "brief_entries" => {
      columns: OWNED.merge(
        "project_id" => uuid,
        "kind" => text,
        "text" => text(null: true),
        "author_kind" => text,
        "author_id" => uuid(null: true)
      ).merge(STAMPS),
      indexes: [ idx("workspace_id"), idx("project_id") ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("project_id", "projects") ]
    },
    "rules" => {
      columns: OWNED.merge(
        "key" => text,
        "enabled" => col("boolean"),
        "current_version" => int,
        "removed_at" => time
      ).merge(STAMPS),
      indexes: [ idx("workspace_id", "key", unique: true) ],
      # The current version is a version of this rule (deferred).
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("id, current_version", "rule_versions") ]
    },
    "rule_versions" => {
      # No `enabled`: it lives on rules (PRD, Data model; P-4).
      columns: OWNED.merge(
        "rule_id" => uuid,
        "version" => int,
        "key" => text,
        "name" => text,
        "hook" => text,
        "scope_kind" => text,
        "scope_values" => jsonb(default: "'[]'::jsonb"),
        "kind" => text,
        "checker" => text,
        "checker_function" => text(null: true),
        "parameters" => jsonb(null: true),
        "instruction" => text(null: true),
        "checker_role" => text(null: true),
        "on_fail" => text(null: true),
        "route" => text(null: true),
        "queue_timeout_seconds" => int(null: true),
        "run_timeout_seconds" => int(null: true),
        "origin" => text,
        "author_kind" => text,
        "author_id" => uuid(null: true)
      ).merge(CREATED),
      indexes: [ idx("workspace_id"), idx("rule_id", "version", unique: true), idx("rule_id", "id", unique: true) ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("rule_id", "rules") ]
    },
    "tasks" => {
      columns: OWNED.merge(
        "project_id" => uuid(null: true),
        "title" => text(null: true),
        "goal" => text(null: true),
        "details" => text(null: true),
        "work_reference" => text(null: true),
        "state" => text,
        "round" => int(default: "0"),
        "holder_seat_id" => uuid(null: true),
        "builder_seat_id" => uuid(null: true),
        "lease_due_at" => time,
        "lease_time_left_while_paused" => col("interval", null: true),
        "minimum_strength_rank" => int(null: true),
        "contract_version" => int(default: "0"),
        "budget_cap" => money,
        "spent" => money(null: false, default: "0.0"),
        "priority" => text(default: "'normal'::text"),
        "extra_rounds" => int(default: "0"),
        "credential_id" => uuid(null: true),
        "resume_pending_since" => time,
        "content_deleted_at" => time
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("project_id"),
        idx("holder_seat_id", unique: true, where: "(holder_seat_id IS NOT NULL)"),
        idx("builder_seat_id")
      ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("project_id", "projects"),
        fk("holder_seat_id", "seats"), fk("builder_seat_id", "seats")
      ]
    },
    "criteria" => {
      columns: OWNED.merge(
        "task_id" => uuid,
        "position" => int,
        "text" => text(null: true),
        "kind" => text,
        "state" => text(default: "'open'::text"),
        "passed_at" => time,
        "passed_by_seat_id" => uuid(null: true),
        "removed_at" => time
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("task_id"),
        idx("task_id", "position", unique: true, where: "(removed_at IS NULL)"),
        idx("passed_by_seat_id")
      ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("task_id", "tasks"), fk("passed_by_seat_id", "seats") ]
    },
    "evidence" => {
      columns: OWNED.merge(
        "criterion_id" => uuid,
        "kind" => text,
        "value" => text(null: true),
        "attached_by_seat_id" => uuid
      ).merge(STAMPS),
      indexes: [ idx("workspace_id"), idx("criterion_id"), idx("attached_by_seat_id") ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("criterion_id", "criteria"), fk("attached_by_seat_id", "seats")
      ]
    },
    "reviews" => {
      columns: OWNED.merge(
        "task_id" => uuid,
        "round" => int,
        "reviewer_seat_id" => uuid(null: true),
        "lease_due_at" => time,
        "lease_time_left_while_paused" => col("interval", null: true),
        "verdict" => text(null: true),
        "failed_criteria" => col("uuid[]", null: true),
        "failed_rule_check_id" => uuid(null: true),
        "notes" => text(null: true),
        "handoff_note" => text(null: true),
        "credential_id" => uuid(null: true)
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("task_id", "round", unique: true),
        idx("reviewer_seat_id", unique: true, where: "((reviewer_seat_id IS NOT NULL) AND (verdict IS NULL))"),
        idx("failed_rule_check_id")
      ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("task_id", "tasks"),
        fk("reviewer_seat_id", "seats"), fk("failed_rule_check_id", "rule_checks")
      ]
    },
    "questions" => {
      columns: OWNED.merge(
        "task_id" => uuid,
        "asking_seat_id" => uuid,
        "text" => text(null: true),
        "assumption" => text(null: true),
        "blocking" => col("boolean"),
        "outcome" => text(default: "'open'::text"),
        "answer" => text(null: true),
        "basis" => text(null: true),
        "answered_by_kind" => text(null: true),
        "answered_by_id" => uuid(null: true),
        "asked_at" => time(null: false),
        "answered_at" => time,
        "read_at" => time
      ).merge(STAMPS),
      indexes: [ idx("workspace_id"), idx("task_id"), idx("asking_seat_id") ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("task_id", "tasks"), fk("asking_seat_id", "seats") ]
    },
    "actions" => {
      columns: OWNED.merge(
        "task_id" => uuid,
        "position" => int,
        "kind" => text,
        "description" => text(null: true),
        "state" => text(default: "'contracted'::text"),
        "approved_by_kind" => text(null: true),
        "approved_by_id" => uuid(null: true),
        "approval_job_id" => uuid(null: true)
      ).merge(STAMPS),
      indexes: [ idx("workspace_id"), idx("task_id", "position", unique: true), idx("approval_job_id") ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("task_id", "tasks"), fk("approval_job_id", "jobs") ]
    },
    "events" => {
      columns: ID.merge(
        "workspace_id" => uuid,
        "seq" => col("bigint"),
        "at" => time(null: false),
        "effective_at" => time(null: false),
        "type" => text,
        "schema_version" => int,
        "actor_kind" => text,
        "actor_id" => uuid(null: true),
        "project_id" => uuid(null: true),
        "task_id" => uuid(null: true),
        "round" => int(null: true),
        "subject_kind" => text(null: true),
        "subject_id" => uuid(null: true),
        "cause_id" => uuid(null: true),
        "command_id" => text(null: true),
        "payload" => jsonb
      ).merge(CREATED).merge("xact_id" => col("xid8", default: "pg_current_xact_id()")),
      indexes: [
        idx("workspace_id", "seq", unique: true),
        idx("workspace_id", "task_id", "seq"),
        idx("task_id", "xact_id"),
        idx("command_id"),
        idx("task_id"),
        idx("project_id"),
        idx("cause_id")
      ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("project_id", "projects"),
        fk("task_id", "tasks"), fk("cause_id", "events")
      ]
    },
    "pending_transitions" => {
      columns: OWNED.merge(
        "task_id" => uuid,
        "command_key" => text,
        "command" => text,
        "requester_kind" => text,
        "requester_id" => uuid,
        "frozen_rule_version_ids" => col("uuid[]", default: "'{}'::uuid[]"),
        "state" => text(default: "'pending'::text"),
        "reasons" => jsonb(null: true)
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("task_id"),
        idx("task_id", unique: true, where: "(state = 'pending'::text)")
      ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("task_id", "tasks") ]
    },
    "jobs" => {
      columns: OWNED.merge(
        "kind" => text,
        "task_id" => uuid(null: true),
        "project_id" => uuid(null: true),
        "target_kind" => text,
        "target_id" => uuid,
        "seat_role" => text,
        "claimed_by_seat_id" => uuid(null: true),
        "state" => text(default: "'queued'::text"),
        "queued_at" => time(null: false),
        "claimed_at" => time,
        "finished_at" => time,
        "input" => jsonb,
        "result" => jsonb(null: true),
        "tokens" => col("bigint", null: true),
        "spend" => money,
        "credential_id" => uuid(null: true)
      ).merge(STAMPS),
      indexes: [ idx("workspace_id"), idx("task_id"), idx("project_id"), idx("claimed_by_seat_id") ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("task_id", "tasks"),
        fk("project_id", "projects"), fk("claimed_by_seat_id", "seats")
      ]
    },
    "rule_checks" => {
      columns: OWNED.merge(
        "task_id" => uuid(null: true),
        "project_id" => uuid(null: true),
        "rule_id" => uuid,
        "rule_version_id" => uuid,
        "hook" => text,
        "round" => int(null: true),
        "subject_kind" => text(null: true),
        "subject_id" => uuid(null: true),
        "input_hash" => text,
        "result" => text(null: true),
        "effect" => text(null: true),
        "reason" => text(null: true),
        "pending_transition_id" => uuid(null: true),
        "overridden_by_user_id" => uuid(null: true),
        "overridden_at" => time,
        "override_reason" => text(null: true)
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("task_id", "rule_version_id", "hook", "round", "subject_kind", "subject_id", "input_hash",
            unique: true, nulls_not_distinct: true),
        idx("project_id"),
        idx("rule_id"),
        idx("rule_version_id"),
        idx("pending_transition_id"),
        idx("overridden_by_user_id")
      ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("task_id", "tasks"), fk("project_id", "projects"),
        fk("rule_id", "rules"), fk("rule_version_id", "rule_versions"), fk("rule_id, rule_version_id", "rule_versions"),
        fk("pending_transition_id", "pending_transitions"), fk("overridden_by_user_id", "users")
      ]
    },
    "rule_check_attempts" => {
      columns: OWNED.merge(
        "rule_check_id" => uuid,
        "attempt_number" => int,
        "job_id" => uuid(null: true),
        "checker_seat_id" => uuid(null: true),
        "queued_at" => time(null: false),
        "started_at" => time,
        "finished_at" => time,
        "tokens" => col("bigint", null: true),
        "spend" => money
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("rule_check_id", "attempt_number", unique: true),
        idx("job_id"),
        idx("checker_seat_id")
      ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("rule_check_id", "rule_checks"),
        fk("job_id", "jobs"), fk("checker_seat_id", "seats")
      ]
    },
    "holds" => {
      columns: OWNED.merge(
        "task_id" => uuid,
        "project_id" => uuid(null: true),
        "reason" => text,
        "rule_id" => uuid(null: true),
        "rule_check_id" => uuid(null: true),
        "action_id" => uuid(null: true),
        "credential_id" => uuid(null: true),
        "detail" => text(null: true),
        "opened_at" => time(null: false),
        "closed_at" => time,
        "opened_by_kind" => text,
        "opened_by_id" => uuid(null: true),
        "closed_by_kind" => text(null: true),
        "closed_by_id" => uuid(null: true)
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("task_id"),
        idx("task_id", where: "(closed_at IS NULL)"),
        idx("project_id"),
        idx("rule_id"),
        idx("rule_check_id"),
        idx("action_id")
      ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("task_id", "tasks"), fk("project_id", "projects"),
        fk("rule_id", "rules"), fk("rule_check_id", "rule_checks"), fk("action_id", "actions")
      ]
    },
    "inbox_items" => {
      columns: OWNED.merge(
        "kind" => text,
        "about_kind" => text,
        "about_id" => uuid(null: true),
        "hold_id" => uuid(null: true),
        "credential_id" => uuid(null: true),
        "choices" => jsonb,
        "facts" => jsonb,
        "state" => text(default: "'open'::text"),
        "opened_at" => time(null: false),
        "resolved_by_kind" => text(null: true),
        "resolved_by_id" => uuid(null: true),
        "resolved_at" => time
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("hold_id"),
        idx("workspace_id", unique: true,
            where: "((kind = 'orchestrator_offline'::text) AND (state = 'open'::text))"),
        idx("about_id", unique: true,
            where: "((kind = 'no_reviewer_eligible'::text) AND (state = 'open'::text))"),
        idx("hold_id", unique: true, where: "(state = 'open'::text)")
      ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("hold_id", "holds") ]
    },
    "task_steps" => {
      # `step_class`, not the PRD's "class": Active Record refuses an
      # attribute named `class`.
      columns: OWNED.merge(
        "task_id" => uuid,
        "round" => int,
        "kind" => text,
        "step_class" => text,
        "subject_kind" => text(null: true),
        "subject_id" => uuid(null: true),
        "seat_id" => uuid(null: true),
        "cause_kind" => text(null: true),
        "cause_rule_id" => uuid(null: true),
        "opened_at" => time(null: false),
        "closed_at" => time,
        "opening_event_id" => uuid,
        "closing_event_id" => uuid(null: true)
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("task_id"),
        idx("task_id", unique: true, where: "(closed_at IS NULL)"),
        idx("seat_id"),
        idx("cause_rule_id"),
        idx("opening_event_id"),
        idx("closing_event_id")
      ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("task_id", "tasks"), fk("seat_id", "seats"),
        fk("cause_rule_id", "rules"), fk("opening_event_id", "events"), fk("closing_event_id", "events")
      ]
    },
    "briefing_acknowledgements" => {
      # `briefing_hash`, not `hash`: Active Record defines #hash.
      columns: OWNED.merge(
        "seat_id" => uuid,
        "task_id" => uuid,
        "review_id" => uuid(null: true),
        "lease_event_id" => uuid,
        "briefing_hash" => text,
        "acknowledged_at" => time(null: false)
      ).merge(CREATED),
      indexes: [
        idx("workspace_id"),
        idx("seat_id", "lease_event_id", "briefing_hash", unique: true),
        idx("task_id"),
        idx("review_id"),
        idx("lease_event_id")
      ],
      foreign_keys: [
        fk("workspace_id", "workspaces"), fk("seat_id", "seats"), fk("task_id", "tasks"),
        fk("review_id", "reviews"), fk("lease_event_id", "events")
      ]
    },
    "commands" => {
      columns: OWNED.merge(
        "caller_kind" => text,
        "caller_id" => uuid,
        "key" => text,
        "command" => text,
        "request_hash" => text,
        "pending_transition_id" => uuid(null: true),
        "outcome" => text,
        "refusal" => jsonb(null: true),
        "result" => jsonb(null: true),
        "notify" => bool("false"),
        "read_at" => time
      ).merge(STAMPS),
      indexes: [
        idx("workspace_id"),
        idx("caller_kind", "caller_id", "key", unique: true),
        idx("pending_transition_id")
      ],
      foreign_keys: [ fk("workspace_id", "workspaces"), fk("pending_transition_id", "pending_transitions") ]
    },
    "sweep_runs" => {
      columns: OWNED.merge(
        "ran_at" => time(null: false),
        "tasks_touched" => int,
        "workspace_timers_fired" => int
      ).merge(CREATED),
      indexes: [ idx("workspace_id", "ran_at") ],
      foreign_keys: [ fk("workspace_id", "workspaces") ]
    }
  }.freeze

  # Rails' own bookkeeping tables, not part of the Data model.
  RAILS_TABLES = %w[schema_migrations ar_internal_metadata].freeze

  # Column names a secret could hide behind (C20, C23). Only hashes of
  # tokens and the owner's password digest may be stored.
  SECRET_WORD = /(\A|_)(token|secret|password|passwd|keychain|api_key|private_key|settings_folder|cookie)(_|\z)/
  ALLOWED_SECRET_NAMES = %w[token_hash password_digest].freeze

  # Values a partial index names, and the registry list each must be in.
  INDEX_VALUES = {
    "credentials.provider = 'gemini'" => [ "gemini", :credential_providers ],
    "credentials.kind = 'login'" => [ "login", "credential_kinds" ],
    "inbox_items.kind = 'orchestrator_offline'" => [ "orchestrator_offline", :needs_you_items ],
    "inbox_items.kind = 'no_reviewer_eligible'" => [ "no_reviewer_eligible", :needs_you_items ],
    "inbox_items.state = 'open'" => [ "open", "inbox_states" ],
    "pending_transitions.state = 'pending'" => [ "pending", "pending_transition_states" ],
    "credentials.state default 'active'" => [ "active", "credential_states" ],
    "tasks.priority default 'normal'" => [ "normal", "priorities" ],
    "criteria.state default 'open'" => [ "open", "criterion_states" ],
    "questions.outcome default 'open'" => [ "open", "question_outcomes" ],
    "actions.state default 'contracted'" => [ "contracted", "action_states" ],
    "jobs.state default 'queued'" => [ "queued", "job_states" ],
    "helper_requests.state default 'queued'" => [ "queued", "helper_request_states" ]
  }.freeze
end
