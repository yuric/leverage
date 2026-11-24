SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: leverage_refuse_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.leverage_refuse_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'restrict_violation';
END;
$$;


--
-- Name: leverage_require_task_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.leverage_require_task_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM events
    WHERE task_id = NEW.id AND workspace_id = NEW.workspace_id AND xact_id = pg_current_xact_id()
  ) THEN
    RAISE EXCEPTION 'tasks.state of task % changed without an event for that task in the same transaction', NEW.id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NULL;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    task_id uuid NOT NULL,
    "position" integer NOT NULL,
    kind text NOT NULL,
    description text,
    state text DEFAULT 'contracted'::text NOT NULL,
    approved_by_kind text,
    approved_by_id uuid,
    approval_job_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: backup_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.backup_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ran_at timestamp with time zone NOT NULL,
    file_name text NOT NULL,
    bytes bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: brief_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brief_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    project_id uuid NOT NULL,
    kind text NOT NULL,
    text text,
    author_kind text NOT NULL,
    author_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "position" integer NOT NULL
);


--
-- Name: briefing_acknowledgements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.briefing_acknowledgements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    seat_id uuid NOT NULL,
    task_id uuid NOT NULL,
    review_id uuid,
    lease_event_id uuid NOT NULL,
    briefing_hash text NOT NULL,
    acknowledged_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: commands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commands (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    caller_kind text NOT NULL,
    caller_id uuid NOT NULL,
    key text NOT NULL,
    command text NOT NULL,
    request_hash text NOT NULL,
    pending_transition_id uuid,
    outcome text NOT NULL,
    refusal jsonb,
    result jsonb,
    notify boolean DEFAULT false NOT NULL,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT commands_refusal_holds_no_token CHECK (((refusal IS NULL) OR (NOT jsonb_path_exists(refusal, '$.**?(@.type() == "object").keyvalue()?(@."key" like_regex "(^|_)token$" flag "i")'::jsonpath)))),
    CONSTRAINT commands_result_holds_no_token CHECK (((result IS NULL) OR (NOT jsonb_path_exists(result, '$.**?(@.type() == "object").keyvalue()?(@."key" like_regex "(^|_)token$" flag "i")'::jsonpath))))
);


--
-- Name: credential_readings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credential_readings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    credential_id uuid NOT NULL,
    observed_at timestamp with time zone NOT NULL,
    state text NOT NULL,
    figures jsonb DEFAULT '[]'::jsonb NOT NULL,
    resets jsonb,
    tool_version text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credentials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    kind text NOT NULL,
    provider text NOT NULL,
    name text NOT NULL,
    masked_label text,
    plan text,
    account_email text,
    state text DEFAULT 'active'::text NOT NULL,
    limited_until timestamp with time zone,
    "position" integer NOT NULL,
    model text,
    effort text,
    strength_rank integer,
    last_verified_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    limited_since timestamp with time zone,
    CONSTRAINT credentials_limited_until_needs_limited_since CHECK (((limited_until IS NULL) OR (limited_since IS NOT NULL))),
    CONSTRAINT credentials_masked_label_is_fixed CHECK (((masked_label IS NULL) OR (masked_label = '••••••••'::text)))
);


--
-- Name: criteria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.criteria (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    task_id uuid NOT NULL,
    "position" integer NOT NULL,
    text text,
    kind text NOT NULL,
    state text DEFAULT 'open'::text NOT NULL,
    passed_at timestamp with time zone,
    passed_by_seat_id uuid,
    removed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    seq bigint NOT NULL,
    at timestamp with time zone NOT NULL,
    effective_at timestamp with time zone NOT NULL,
    type text NOT NULL,
    schema_version integer NOT NULL,
    actor_kind text NOT NULL,
    actor_id uuid,
    project_id uuid,
    task_id uuid,
    round integer,
    subject_kind text,
    subject_id uuid,
    cause_id uuid,
    command_id text,
    payload jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    xact_id xid8 DEFAULT pg_current_xact_id() NOT NULL,
    CONSTRAINT events_round_with_task CHECK (((task_id IS NULL) = (round IS NULL))),
    CONSTRAINT events_subject_pair CHECK (((subject_kind IS NULL) = (subject_id IS NULL)))
);


--
-- Name: evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evidence (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    criterion_id uuid NOT NULL,
    kind text NOT NULL,
    value text,
    attached_by_seat_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: helper_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.helper_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    kind text NOT NULL,
    seat_id uuid,
    credential_id uuid,
    state text DEFAULT 'queued'::text NOT NULL,
    requested_at timestamp with time zone NOT NULL,
    picked_up_at timestamp with time zone,
    finished_at timestamp with time zone,
    result jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    params jsonb DEFAULT '{}'::jsonb NOT NULL,
    progress jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT helper_requests_params_hold_no_name_or_token CHECK ((NOT jsonb_path_exists(params, '$.**?(@.type() == "object").keyvalue()?(@."key" like_regex "^name$|(^|_)token$" flag "i")'::jsonpath))),
    CONSTRAINT helper_requests_progress_holds_no_name_or_token CHECK ((NOT jsonb_path_exists(progress, '$.**?(@.type() == "object").keyvalue()?(@."key" like_regex "^name$|(^|_)token$" flag "i")'::jsonpath))),
    CONSTRAINT helper_requests_result_holds_no_token CHECK (((result IS NULL) OR (NOT jsonb_path_exists(result, '$.**?(@.type() == "object").keyvalue()?(@."key" like_regex "(^|_)token$" flag "i")'::jsonpath))))
);


--
-- Name: helpers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.helpers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    name text NOT NULL,
    token_hash text NOT NULL,
    last_reported_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: holds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.holds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    task_id uuid NOT NULL,
    project_id uuid,
    reason text NOT NULL,
    rule_id uuid,
    rule_check_id uuid,
    action_id uuid,
    credential_id uuid,
    detail text,
    opened_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone,
    opened_by_kind text NOT NULL,
    opened_by_id uuid,
    closed_by_kind text,
    closed_by_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: inbox_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbox_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    kind text NOT NULL,
    about_kind text NOT NULL,
    about_id uuid,
    hold_id uuid,
    credential_id uuid,
    choices jsonb NOT NULL,
    facts jsonb NOT NULL,
    state text DEFAULT 'open'::text NOT NULL,
    opened_at timestamp with time zone NOT NULL,
    resolved_by_kind text,
    resolved_by_id uuid,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    kind text NOT NULL,
    task_id uuid,
    project_id uuid,
    target_kind text NOT NULL,
    target_id uuid NOT NULL,
    seat_role text NOT NULL,
    claimed_by_seat_id uuid,
    state text DEFAULT 'queued'::text NOT NULL,
    queued_at timestamp with time zone NOT NULL,
    claimed_at timestamp with time zone,
    finished_at timestamp with time zone,
    input jsonb,
    result jsonb,
    tokens bigint,
    spend numeric(14,6),
    credential_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    attempt_number integer DEFAULT 1 NOT NULL
);


--
-- Name: pending_transitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_transitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    task_id uuid NOT NULL,
    command_key text NOT NULL,
    command text NOT NULL,
    requester_kind text NOT NULL,
    requester_id uuid NOT NULL,
    frozen_rule_version_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    state text DEFAULT 'pending'::text NOT NULL,
    reasons jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    params jsonb,
    CONSTRAINT pending_transitions_params_hold_no_token CHECK (((params IS NULL) OR (NOT jsonb_path_exists(params, '$.**?(@.type() == "object").keyvalue()?(@."key" like_regex "(^|_)token$" flag "i")'::jsonpath)))),
    CONSTRAINT pending_transitions_params_only_while_pending CHECK (((params IS NULL) OR (state = 'pending'::text)))
);


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    name text,
    goal text,
    budget numeric(14,6),
    spent numeric(14,6) DEFAULT 0.0 NOT NULL,
    paused boolean DEFAULT false NOT NULL,
    brief_version integer DEFAULT 0 NOT NULL,
    content_deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.questions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    task_id uuid NOT NULL,
    asking_seat_id uuid NOT NULL,
    text text,
    assumption text,
    blocking boolean NOT NULL,
    outcome text DEFAULT 'open'::text NOT NULL,
    answer text,
    basis text,
    answered_by_kind text,
    answered_by_id uuid,
    asked_at timestamp with time zone NOT NULL,
    answered_at timestamp with time zone,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT questions_basis_known CHECK ((basis = ANY (ARRAY['record'::text, 'decision'::text, 'owner'::text]))),
    CONSTRAINT questions_outcome_known CHECK ((outcome = ANY (ARRAY['open'::text, 'answered'::text, 'passed_on'::text, 'overturned'::text])))
);


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    task_id uuid NOT NULL,
    round integer NOT NULL,
    reviewer_seat_id uuid,
    lease_due_at timestamp with time zone,
    lease_time_left_while_paused interval,
    verdict text,
    failed_criteria uuid[],
    failed_rule_check_id uuid,
    notes text,
    handoff_note text,
    credential_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: rule_check_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rule_check_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    rule_check_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    job_id uuid,
    checker_seat_id uuid,
    queued_at timestamp with time zone NOT NULL,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    tokens bigint,
    spend numeric(14,6),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: rule_checks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rule_checks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    task_id uuid,
    project_id uuid,
    rule_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    hook text NOT NULL,
    round integer,
    subject_kind text,
    subject_id uuid,
    input_hash text NOT NULL,
    result text,
    effect text,
    reason text,
    pending_transition_id uuid,
    overridden_by_user_id uuid,
    overridden_at timestamp with time zone,
    override_reason text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: rule_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rule_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    rule_id uuid NOT NULL,
    version integer NOT NULL,
    key text NOT NULL,
    name text NOT NULL,
    hook text NOT NULL,
    scope_kind text NOT NULL,
    scope_values jsonb DEFAULT '[]'::jsonb NOT NULL,
    kind text NOT NULL,
    checker text NOT NULL,
    checker_function text,
    parameters jsonb,
    instruction text,
    checker_role text,
    on_fail text,
    route text,
    queue_timeout_seconds integer,
    run_timeout_seconds integer,
    origin text NOT NULL,
    author_kind text NOT NULL,
    author_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    key text NOT NULL,
    enabled boolean NOT NULL,
    current_version integer NOT NULL,
    removed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: seats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    name text NOT NULL,
    provider text NOT NULL,
    model text NOT NULL,
    effort text NOT NULL,
    role text NOT NULL,
    strength_rank integer NOT NULL,
    credential_id uuid,
    enabled boolean DEFAULT true NOT NULL,
    paused boolean DEFAULT false NOT NULL,
    token_hash text,
    last_polled_at timestamp with time zone,
    run_state text,
    removed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    wanted_running boolean DEFAULT false NOT NULL,
    run_credential_id uuid,
    run_stop_reason text
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    last_used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: sweep_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sweep_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    ran_at timestamp with time zone NOT NULL,
    tasks_touched integer NOT NULL,
    workspace_timers_fired integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: task_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_steps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    task_id uuid NOT NULL,
    round integer NOT NULL,
    kind text NOT NULL,
    step_class text NOT NULL,
    subject_kind text,
    subject_id uuid,
    seat_id uuid,
    cause_kind text,
    cause_rule_id uuid,
    opened_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone,
    opening_event_id uuid NOT NULL,
    closing_event_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT task_steps_no_negative_duration CHECK (((closed_at IS NULL) OR (closed_at >= opened_at)))
);


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    project_id uuid,
    title text,
    details text,
    work_reference text,
    state text NOT NULL,
    round integer DEFAULT 0 NOT NULL,
    holder_seat_id uuid,
    builder_seat_id uuid,
    lease_due_at timestamp with time zone,
    lease_time_left_while_paused interval,
    minimum_strength_rank integer,
    contract_version integer DEFAULT 0 NOT NULL,
    budget_cap numeric(14,6),
    spent numeric(14,6) DEFAULT 0.0 NOT NULL,
    priority text DEFAULT 'normal'::text NOT NULL,
    extra_rounds integer DEFAULT 0 NOT NULL,
    credential_id uuid,
    resume_pending_since timestamp with time zone,
    content_deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    email_address text NOT NULL,
    password_digest text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    lease_length_seconds integer DEFAULT 3600 NOT NULL,
    check_queue_timeout_seconds integer DEFAULT 120 NOT NULL,
    check_run_timeout_seconds integer DEFAULT 300 NOT NULL,
    maximum_rounds integer DEFAULT 3 NOT NULL,
    rerun_limit integer DEFAULT 3 NOT NULL,
    recovery_time_ceiling_seconds integer,
    last_seq bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: actions actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actions
    ADD CONSTRAINT actions_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: backup_runs backup_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.backup_runs
    ADD CONSTRAINT backup_runs_pkey PRIMARY KEY (id);


--
-- Name: brief_entries brief_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brief_entries
    ADD CONSTRAINT brief_entries_pkey PRIMARY KEY (id);


--
-- Name: briefing_acknowledgements briefing_acknowledgements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.briefing_acknowledgements
    ADD CONSTRAINT briefing_acknowledgements_pkey PRIMARY KEY (id);


--
-- Name: commands commands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT commands_pkey PRIMARY KEY (id);


--
-- Name: credential_readings credential_readings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_readings
    ADD CONSTRAINT credential_readings_pkey PRIMARY KEY (id);


--
-- Name: credentials credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credentials
    ADD CONSTRAINT credentials_pkey PRIMARY KEY (id);


--
-- Name: credentials credentials_position_unique_per_workspace; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credentials
    ADD CONSTRAINT credentials_position_unique_per_workspace UNIQUE (workspace_id, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: criteria criteria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria
    ADD CONSTRAINT criteria_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: evidence evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT evidence_pkey PRIMARY KEY (id);


--
-- Name: helper_requests helper_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.helper_requests
    ADD CONSTRAINT helper_requests_pkey PRIMARY KEY (id);


--
-- Name: helpers helpers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.helpers
    ADD CONSTRAINT helpers_pkey PRIMARY KEY (id);


--
-- Name: holds holds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holds
    ADD CONSTRAINT holds_pkey PRIMARY KEY (id);


--
-- Name: inbox_items inbox_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_items
    ADD CONSTRAINT inbox_items_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: pending_transitions pending_transitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_transitions
    ADD CONSTRAINT pending_transitions_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: questions questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_pkey PRIMARY KEY (id);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);


--
-- Name: rule_check_attempts rule_check_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_check_attempts
    ADD CONSTRAINT rule_check_attempts_pkey PRIMARY KEY (id);


--
-- Name: rule_checks rule_checks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT rule_checks_pkey PRIMARY KEY (id);


--
-- Name: rule_versions rule_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_versions
    ADD CONSTRAINT rule_versions_pkey PRIMARY KEY (id);


--
-- Name: rules rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules
    ADD CONSTRAINT rules_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: seats seats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seats
    ADD CONSTRAINT seats_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sweep_runs sweep_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sweep_runs
    ADD CONSTRAINT sweep_runs_pkey PRIMARY KEY (id);


--
-- Name: task_steps task_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_steps
    ADD CONSTRAINT task_steps_pkey PRIMARY KEY (id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: idx_on_workspace_id_kind_provider_name_e6117d2ae8; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_workspace_id_kind_provider_name_e6117d2ae8 ON public.credentials USING btree (workspace_id, kind, provider, name);


--
-- Name: index_actions_on_approval_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_actions_on_approval_job_id ON public.actions USING btree (approval_job_id);


--
-- Name: index_actions_on_task_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_actions_on_task_id_and_position ON public.actions USING btree (task_id, "position");


--
-- Name: index_actions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_actions_on_workspace_id ON public.actions USING btree (workspace_id);


--
-- Name: index_backup_runs_on_file_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_backup_runs_on_file_name ON public.backup_runs USING btree (file_name);


--
-- Name: index_backup_runs_on_ran_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_backup_runs_on_ran_at ON public.backup_runs USING btree (ran_at);


--
-- Name: index_brief_entries_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_brief_entries_on_project_id ON public.brief_entries USING btree (project_id);


--
-- Name: index_brief_entries_on_project_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_brief_entries_on_project_id_and_position ON public.brief_entries USING btree (project_id, "position");


--
-- Name: index_brief_entries_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_brief_entries_on_workspace_id ON public.brief_entries USING btree (workspace_id);


--
-- Name: index_briefing_acknowledgements_on_lease_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_briefing_acknowledgements_on_lease_event_id ON public.briefing_acknowledgements USING btree (lease_event_id);


--
-- Name: index_briefing_acknowledgements_on_review_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_briefing_acknowledgements_on_review_id ON public.briefing_acknowledgements USING btree (review_id);


--
-- Name: index_briefing_acknowledgements_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_briefing_acknowledgements_on_task_id ON public.briefing_acknowledgements USING btree (task_id);


--
-- Name: index_briefing_acknowledgements_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_briefing_acknowledgements_on_workspace_id ON public.briefing_acknowledgements USING btree (workspace_id);


--
-- Name: index_briefing_acknowledgements_once_per_lease_and_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_briefing_acknowledgements_once_per_lease_and_hash ON public.briefing_acknowledgements USING btree (seat_id, lease_event_id, briefing_hash);


--
-- Name: index_commands_on_caller_kind_and_caller_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commands_on_caller_kind_and_caller_id_and_key ON public.commands USING btree (caller_kind, caller_id, key);


--
-- Name: index_commands_on_pending_transition_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commands_on_pending_transition_id ON public.commands USING btree (pending_transition_id);


--
-- Name: index_commands_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commands_on_workspace_id ON public.commands USING btree (workspace_id);


--
-- Name: index_credential_readings_on_credential_id_and_observed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_credential_readings_on_credential_id_and_observed_at ON public.credential_readings USING btree (credential_id, observed_at);


--
-- Name: index_credential_readings_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_credential_readings_on_workspace_id ON public.credential_readings USING btree (workspace_id);


--
-- Name: index_credentials_one_gemini_login_per_workspace; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_credentials_one_gemini_login_per_workspace ON public.credentials USING btree (workspace_id) WHERE ((provider = 'gemini'::text) AND (kind = 'login'::text));


--
-- Name: index_criteria_on_passed_by_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_criteria_on_passed_by_seat_id ON public.criteria USING btree (passed_by_seat_id);


--
-- Name: index_criteria_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_criteria_on_task_id ON public.criteria USING btree (task_id);


--
-- Name: index_criteria_on_task_id_and_position_not_removed; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_criteria_on_task_id_and_position_not_removed ON public.criteria USING btree (task_id, "position") WHERE (removed_at IS NULL);


--
-- Name: index_criteria_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_criteria_on_workspace_id ON public.criteria USING btree (workspace_id);


--
-- Name: index_events_on_cause_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_cause_id ON public.events USING btree (cause_id);


--
-- Name: index_events_on_command_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_command_id ON public.events USING btree (command_id);


--
-- Name: index_events_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_project_id ON public.events USING btree (project_id);


--
-- Name: index_events_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_task_id ON public.events USING btree (task_id);


--
-- Name: index_events_on_task_id_and_xact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_task_id_and_xact_id ON public.events USING btree (task_id, xact_id);


--
-- Name: index_events_on_workspace_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_events_on_workspace_id_and_seq ON public.events USING btree (workspace_id, seq);


--
-- Name: index_events_on_workspace_id_and_task_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_workspace_id_and_task_id_and_seq ON public.events USING btree (workspace_id, task_id, seq);


--
-- Name: index_evidence_on_attached_by_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evidence_on_attached_by_seat_id ON public.evidence USING btree (attached_by_seat_id);


--
-- Name: index_evidence_on_criterion_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evidence_on_criterion_id ON public.evidence USING btree (criterion_id);


--
-- Name: index_evidence_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evidence_on_workspace_id ON public.evidence USING btree (workspace_id);


--
-- Name: index_helper_requests_on_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_helper_requests_on_seat_id ON public.helper_requests USING btree (seat_id);


--
-- Name: index_helper_requests_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_helper_requests_on_workspace_id ON public.helper_requests USING btree (workspace_id);


--
-- Name: index_helpers_on_token_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_helpers_on_token_hash ON public.helpers USING btree (token_hash);


--
-- Name: index_helpers_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_helpers_on_workspace_id ON public.helpers USING btree (workspace_id);


--
-- Name: index_holds_on_action_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_holds_on_action_id ON public.holds USING btree (action_id);


--
-- Name: index_holds_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_holds_on_project_id ON public.holds USING btree (project_id);


--
-- Name: index_holds_on_rule_check_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_holds_on_rule_check_id ON public.holds USING btree (rule_check_id);


--
-- Name: index_holds_on_rule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_holds_on_rule_id ON public.holds USING btree (rule_id);


--
-- Name: index_holds_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_holds_on_task_id ON public.holds USING btree (task_id);


--
-- Name: index_holds_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_holds_on_workspace_id ON public.holds USING btree (workspace_id);


--
-- Name: index_holds_open_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_holds_open_on_task_id ON public.holds USING btree (task_id) WHERE (closed_at IS NULL);


--
-- Name: index_inbox_items_on_hold_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_items_on_hold_id ON public.inbox_items USING btree (hold_id);


--
-- Name: index_inbox_items_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_items_on_workspace_id ON public.inbox_items USING btree (workspace_id);


--
-- Name: index_inbox_items_one_open_no_reviewer_eligible; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inbox_items_one_open_no_reviewer_eligible ON public.inbox_items USING btree (about_id) WHERE ((kind = 'no_reviewer_eligible'::text) AND (state = 'open'::text));


--
-- Name: index_inbox_items_one_open_orchestrator_offline; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inbox_items_one_open_orchestrator_offline ON public.inbox_items USING btree (workspace_id) WHERE ((kind = 'orchestrator_offline'::text) AND (state = 'open'::text));


--
-- Name: index_inbox_items_one_open_per_hold; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inbox_items_one_open_per_hold ON public.inbox_items USING btree (hold_id) WHERE (state = 'open'::text);


--
-- Name: index_jobs_on_claimed_by_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_jobs_on_claimed_by_seat_id ON public.jobs USING btree (claimed_by_seat_id);


--
-- Name: index_jobs_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_jobs_on_project_id ON public.jobs USING btree (project_id);


--
-- Name: index_jobs_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_jobs_on_task_id ON public.jobs USING btree (task_id);


--
-- Name: index_jobs_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_jobs_on_workspace_id ON public.jobs USING btree (workspace_id);


--
-- Name: index_pending_transitions_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pending_transitions_on_task_id ON public.pending_transitions USING btree (task_id);


--
-- Name: index_pending_transitions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pending_transitions_on_workspace_id ON public.pending_transitions USING btree (workspace_id);


--
-- Name: index_pending_transitions_one_pending_per_task; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_pending_transitions_one_pending_per_task ON public.pending_transitions USING btree (task_id) WHERE (state = 'pending'::text);


--
-- Name: index_projects_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_projects_on_workspace_id ON public.projects USING btree (workspace_id);


--
-- Name: index_questions_on_asking_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_questions_on_asking_seat_id ON public.questions USING btree (asking_seat_id);


--
-- Name: index_questions_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_questions_on_task_id ON public.questions USING btree (task_id);


--
-- Name: index_questions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_questions_on_workspace_id ON public.questions USING btree (workspace_id);


--
-- Name: index_reviews_on_failed_rule_check_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_failed_rule_check_id ON public.reviews USING btree (failed_rule_check_id);


--
-- Name: index_reviews_on_reviewer_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_reviews_on_reviewer_seat_id ON public.reviews USING btree (reviewer_seat_id) WHERE ((reviewer_seat_id IS NOT NULL) AND (verdict IS NULL));


--
-- Name: index_reviews_on_task_id_and_round; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_reviews_on_task_id_and_round ON public.reviews USING btree (task_id, round);


--
-- Name: index_reviews_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_workspace_id ON public.reviews USING btree (workspace_id);


--
-- Name: index_rule_check_attempts_on_checker_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_check_attempts_on_checker_seat_id ON public.rule_check_attempts USING btree (checker_seat_id);


--
-- Name: index_rule_check_attempts_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_check_attempts_on_job_id ON public.rule_check_attempts USING btree (job_id);


--
-- Name: index_rule_check_attempts_on_rule_check_id_and_attempt_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_rule_check_attempts_on_rule_check_id_and_attempt_number ON public.rule_check_attempts USING btree (rule_check_id, attempt_number);


--
-- Name: index_rule_check_attempts_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_check_attempts_on_workspace_id ON public.rule_check_attempts USING btree (workspace_id);


--
-- Name: index_rule_checks_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_rule_checks_identity ON public.rule_checks USING btree (task_id, rule_version_id, hook, round, subject_kind, subject_id, input_hash) NULLS NOT DISTINCT;


--
-- Name: index_rule_checks_on_overridden_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_checks_on_overridden_by_user_id ON public.rule_checks USING btree (overridden_by_user_id);


--
-- Name: index_rule_checks_on_pending_transition_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_checks_on_pending_transition_id ON public.rule_checks USING btree (pending_transition_id);


--
-- Name: index_rule_checks_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_checks_on_project_id ON public.rule_checks USING btree (project_id);


--
-- Name: index_rule_checks_on_rule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_checks_on_rule_id ON public.rule_checks USING btree (rule_id);


--
-- Name: index_rule_checks_on_rule_version_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_checks_on_rule_version_id ON public.rule_checks USING btree (rule_version_id);


--
-- Name: index_rule_checks_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_checks_on_workspace_id ON public.rule_checks USING btree (workspace_id);


--
-- Name: index_rule_versions_on_rule_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_rule_versions_on_rule_id_and_id ON public.rule_versions USING btree (rule_id, id);


--
-- Name: index_rule_versions_on_rule_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_rule_versions_on_rule_id_and_version ON public.rule_versions USING btree (rule_id, version);


--
-- Name: index_rule_versions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rule_versions_on_workspace_id ON public.rule_versions USING btree (workspace_id);


--
-- Name: index_rules_on_workspace_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_rules_on_workspace_id_and_key ON public.rules USING btree (workspace_id, key);


--
-- Name: index_seats_on_credential_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_seats_on_credential_id ON public.seats USING btree (credential_id);


--
-- Name: index_seats_on_token_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_seats_on_token_hash ON public.seats USING btree (token_hash);


--
-- Name: index_seats_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_seats_on_workspace_id ON public.seats USING btree (workspace_id);


--
-- Name: index_sessions_on_token_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sessions_on_token_hash ON public.sessions USING btree (token_hash);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_sessions_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_workspace_id ON public.sessions USING btree (workspace_id);


--
-- Name: index_sweep_runs_on_workspace_id_and_ran_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sweep_runs_on_workspace_id_and_ran_at ON public.sweep_runs USING btree (workspace_id, ran_at);


--
-- Name: index_task_steps_on_cause_rule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_steps_on_cause_rule_id ON public.task_steps USING btree (cause_rule_id);


--
-- Name: index_task_steps_on_closing_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_steps_on_closing_event_id ON public.task_steps USING btree (closing_event_id);


--
-- Name: index_task_steps_on_opening_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_steps_on_opening_event_id ON public.task_steps USING btree (opening_event_id);


--
-- Name: index_task_steps_on_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_steps_on_seat_id ON public.task_steps USING btree (seat_id);


--
-- Name: index_task_steps_on_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_steps_on_task_id ON public.task_steps USING btree (task_id);


--
-- Name: index_task_steps_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_steps_on_workspace_id ON public.task_steps USING btree (workspace_id);


--
-- Name: index_task_steps_one_open_per_task; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_task_steps_one_open_per_task ON public.task_steps USING btree (task_id) WHERE (closed_at IS NULL);


--
-- Name: index_tasks_on_builder_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_builder_seat_id ON public.tasks USING btree (builder_seat_id);


--
-- Name: index_tasks_on_holder_seat_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tasks_on_holder_seat_id ON public.tasks USING btree (holder_seat_id) WHERE (holder_seat_id IS NOT NULL);


--
-- Name: index_tasks_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_project_id ON public.tasks USING btree (project_id);


--
-- Name: index_tasks_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_workspace_id ON public.tasks USING btree (workspace_id);


--
-- Name: index_tasks_waiting_for_finishing_lease; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_waiting_for_finishing_lease ON public.tasks USING btree (workspace_id) WHERE ((state = 'finishing'::text) AND (holder_seat_id IS NULL));


--
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


--
-- Name: index_users_on_workspace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_workspace_id ON public.users USING btree (workspace_id);


--
-- Name: events events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER events_append_only BEFORE DELETE OR UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.leverage_refuse_change();


--
-- Name: events events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER events_no_truncate BEFORE TRUNCATE ON public.events FOR EACH STATEMENT EXECUTE FUNCTION public.leverage_refuse_change();


--
-- Name: rule_versions rule_versions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rule_versions_append_only BEFORE DELETE OR UPDATE ON public.rule_versions FOR EACH ROW EXECUTE FUNCTION public.leverage_refuse_change();


--
-- Name: rule_versions rule_versions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rule_versions_no_truncate BEFORE TRUNCATE ON public.rule_versions FOR EACH STATEMENT EXECUTE FUNCTION public.leverage_refuse_change();


--
-- Name: tasks tasks_insert_requires_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER tasks_insert_requires_event AFTER INSERT ON public.tasks DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.leverage_require_task_event();


--
-- Name: tasks tasks_state_change_requires_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER tasks_state_change_requires_event AFTER UPDATE OF state ON public.tasks DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((old.state IS DISTINCT FROM new.state)) EXECUTE FUNCTION public.leverage_require_task_event();


--
-- Name: tasks fk_rails_02e851e3b7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT fk_rails_02e851e3b7 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: evidence fk_rails_03a12dee7d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_rails_03a12dee7d FOREIGN KEY (criterion_id) REFERENCES public.criteria(id);


--
-- Name: events fk_rails_0434b48643; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_0434b48643 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: rule_checks fk_rails_07da8b4f14; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT fk_rails_07da8b4f14 FOREIGN KEY (rule_id) REFERENCES public.rules(id);


--
-- Name: commands fk_rails_0e669dd41c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT fk_rails_0e669dd41c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: tasks fk_rails_15a723249e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT fk_rails_15a723249e FOREIGN KEY (holder_seat_id) REFERENCES public.seats(id);


--
-- Name: jobs fk_rails_1977e8b5a6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT fk_rails_1977e8b5a6 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: events fk_rails_1f5f70151c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_1f5f70151c FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: rule_checks fk_rails_282f5e560f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT fk_rails_282f5e560f FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: task_steps fk_rails_29788f5be6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_steps
    ADD CONSTRAINT fk_rails_29788f5be6 FOREIGN KEY (seat_id) REFERENCES public.seats(id);


--
-- Name: projects fk_rails_2b526e3a7f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT fk_rails_2b526e3a7f FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: task_steps fk_rails_2d9f6fc7d2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_steps
    ADD CONSTRAINT fk_rails_2d9f6fc7d2 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: rule_versions fk_rails_398ffd882a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_versions
    ADD CONSTRAINT fk_rails_398ffd882a FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: rule_check_attempts fk_rails_4350b65e1a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_check_attempts
    ADD CONSTRAINT fk_rails_4350b65e1a FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: actions fk_rails_4399870b1a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actions
    ADD CONSTRAINT fk_rails_4399870b1a FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: events fk_rails_43fb91855e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_43fb91855e FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: actions fk_rails_452af883f2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actions
    ADD CONSTRAINT fk_rails_452af883f2 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: credential_readings fk_rails_45b7bb7ecf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_readings
    ADD CONSTRAINT fk_rails_45b7bb7ecf FOREIGN KEY (credential_id) REFERENCES public.credentials(id) ON DELETE CASCADE;


--
-- Name: pending_transitions fk_rails_4e78fe8866; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_transitions
    ADD CONSTRAINT fk_rails_4e78fe8866 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: events fk_rails_4ecb66737c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_4ecb66737c FOREIGN KEY (cause_id) REFERENCES public.events(id);


--
-- Name: rule_versions fk_rails_5240d7176b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_versions
    ADD CONSTRAINT fk_rails_5240d7176b FOREIGN KEY (rule_id) REFERENCES public.rules(id);


--
-- Name: credentials fk_rails_5258358d2b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credentials
    ADD CONSTRAINT fk_rails_5258358d2b FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: pending_transitions fk_rails_55ef3769c6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_transitions
    ADD CONSTRAINT fk_rails_55ef3769c6 FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: holds fk_rails_5a243c1893; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holds
    ADD CONSTRAINT fk_rails_5a243c1893 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: criteria fk_rails_5abe1c7513; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria
    ADD CONSTRAINT fk_rails_5abe1c7513 FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: criteria fk_rails_5c8c6ae389; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria
    ADD CONSTRAINT fk_rails_5c8c6ae389 FOREIGN KEY (passed_by_seat_id) REFERENCES public.seats(id);


--
-- Name: inbox_items fk_rails_5e2d3871fd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_items
    ADD CONSTRAINT fk_rails_5e2d3871fd FOREIGN KEY (hold_id) REFERENCES public.holds(id);


--
-- Name: rule_check_attempts fk_rails_5e7c64a0da; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_check_attempts
    ADD CONSTRAINT fk_rails_5e7c64a0da FOREIGN KEY (checker_seat_id) REFERENCES public.seats(id);


--
-- Name: actions fk_rails_64d5e7765c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.actions
    ADD CONSTRAINT fk_rails_64d5e7765c FOREIGN KEY (approval_job_id) REFERENCES public.jobs(id);


--
-- Name: evidence fk_rails_687f3eb4f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_rails_687f3eb4f1 FOREIGN KEY (attached_by_seat_id) REFERENCES public.seats(id);


--
-- Name: task_steps fk_rails_6e2a215aa0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_steps
    ADD CONSTRAINT fk_rails_6e2a215aa0 FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: credential_readings fk_rails_72d0160149; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_readings
    ADD CONSTRAINT fk_rails_72d0160149 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: users fk_rails_73214f707d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_73214f707d FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: rule_checks fk_rails_785fa07bb5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT fk_rails_785fa07bb5 FOREIGN KEY (overridden_by_user_id) REFERENCES public.users(id);


--
-- Name: briefing_acknowledgements fk_rails_79e98d5884; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.briefing_acknowledgements
    ADD CONSTRAINT fk_rails_79e98d5884 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: questions fk_rails_7f60f06ac4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT fk_rails_7f60f06ac4 FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: task_steps fk_rails_83417c900b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_steps
    ADD CONSTRAINT fk_rails_83417c900b FOREIGN KEY (opening_event_id) REFERENCES public.events(id);


--
-- Name: holds fk_rails_8493a4d8b7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holds
    ADD CONSTRAINT fk_rails_8493a4d8b7 FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: reviews fk_rails_84fbef28ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_84fbef28ca FOREIGN KEY (failed_rule_check_id) REFERENCES public.rule_checks(id);


--
-- Name: sessions fk_rails_85704b4d26; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_85704b4d26 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: helpers fk_rails_85ea7244be; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.helpers
    ADD CONSTRAINT fk_rails_85ea7244be FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: seats fk_rails_87e0f6de4b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seats
    ADD CONSTRAINT fk_rails_87e0f6de4b FOREIGN KEY (credential_id) REFERENCES public.credentials(id);


--
-- Name: rule_check_attempts fk_rails_8b71f2f938; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_check_attempts
    ADD CONSTRAINT fk_rails_8b71f2f938 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: sweep_runs fk_rails_8bdbad4e18; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sweep_runs
    ADD CONSTRAINT fk_rails_8bdbad4e18 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: task_steps fk_rails_9094aa5e64; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_steps
    ADD CONSTRAINT fk_rails_9094aa5e64 FOREIGN KEY (cause_rule_id) REFERENCES public.rules(id);


--
-- Name: task_steps fk_rails_909b52aba4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_steps
    ADD CONSTRAINT fk_rails_909b52aba4 FOREIGN KEY (closing_event_id) REFERENCES public.events(id);


--
-- Name: criteria fk_rails_972155c15d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria
    ADD CONSTRAINT fk_rails_972155c15d FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: evidence fk_rails_9bdbb39f9a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_rails_9bdbb39f9a FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: briefing_acknowledgements fk_rails_a6c7b07bd8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.briefing_acknowledgements
    ADD CONSTRAINT fk_rails_a6c7b07bd8 FOREIGN KEY (lease_event_id) REFERENCES public.events(id);


--
-- Name: helper_requests fk_rails_a8a5de7730; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.helper_requests
    ADD CONSTRAINT fk_rails_a8a5de7730 FOREIGN KEY (seat_id) REFERENCES public.seats(id);


--
-- Name: holds fk_rails_a909af5f96; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holds
    ADD CONSTRAINT fk_rails_a909af5f96 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: questions fk_rails_aa85c0a744; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT fk_rails_aa85c0a744 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: rule_checks fk_rails_ab63d31a27; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT fk_rails_ab63d31a27 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: rule_checks fk_rails_ad140253a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT fk_rails_ad140253a0 FOREIGN KEY (pending_transition_id) REFERENCES public.pending_transitions(id);


--
-- Name: briefing_acknowledgements fk_rails_b4b12734ef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.briefing_acknowledgements
    ADD CONSTRAINT fk_rails_b4b12734ef FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: helper_requests fk_rails_b59eed464a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.helper_requests
    ADD CONSTRAINT fk_rails_b59eed464a FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: questions fk_rails_b912de84d7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT fk_rails_b912de84d7 FOREIGN KEY (asking_seat_id) REFERENCES public.seats(id);


--
-- Name: holds fk_rails_bb38b179da; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holds
    ADD CONSTRAINT fk_rails_bb38b179da FOREIGN KEY (rule_id) REFERENCES public.rules(id);


--
-- Name: rule_checks fk_rails_be4dd4d257; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT fk_rails_be4dd4d257 FOREIGN KEY (rule_version_id) REFERENCES public.rule_versions(id);


--
-- Name: rule_check_attempts fk_rails_c016a3190e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_check_attempts
    ADD CONSTRAINT fk_rails_c016a3190e FOREIGN KEY (rule_check_id) REFERENCES public.rule_checks(id);


--
-- Name: tasks fk_rails_c9bea93382; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT fk_rails_c9bea93382 FOREIGN KEY (builder_seat_id) REFERENCES public.seats(id);


--
-- Name: seats fk_rails_cc76dc87fe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seats
    ADD CONSTRAINT fk_rails_cc76dc87fe FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: jobs fk_rails_d0e1fe2513; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT fk_rails_d0e1fe2513 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: holds fk_rails_d75e664cb3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holds
    ADD CONSTRAINT fk_rails_d75e664cb3 FOREIGN KEY (rule_check_id) REFERENCES public.rule_checks(id);


--
-- Name: commands fk_rails_db313c07ba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT fk_rails_db313c07ba FOREIGN KEY (pending_transition_id) REFERENCES public.pending_transitions(id);


--
-- Name: jobs fk_rails_dc9d08c350; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT fk_rails_dc9d08c350 FOREIGN KEY (claimed_by_seat_id) REFERENCES public.seats(id);


--
-- Name: reviews fk_rails_dff784dcd9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_dff784dcd9 FOREIGN KEY (reviewer_seat_id) REFERENCES public.seats(id);


--
-- Name: tasks fk_rails_e21c9f6818; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT fk_rails_e21c9f6818 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: briefing_acknowledgements fk_rails_e242b2b0d0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.briefing_acknowledgements
    ADD CONSTRAINT fk_rails_e242b2b0d0 FOREIGN KEY (seat_id) REFERENCES public.seats(id);


--
-- Name: rules fk_rails_e8ee2d7013; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules
    ADD CONSTRAINT fk_rails_e8ee2d7013 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: reviews fk_rails_e94bf9f560; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_e94bf9f560 FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: brief_entries fk_rails_eae0070fba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brief_entries
    ADD CONSTRAINT fk_rails_eae0070fba FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: reviews fk_rails_ec3a33f157; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_ec3a33f157 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: rule_checks fk_rails_eec1bd9fe9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT fk_rails_eec1bd9fe9 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: brief_entries fk_rails_ef7a97c855; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brief_entries
    ADD CONSTRAINT fk_rails_ef7a97c855 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: holds fk_rails_ef7ee81f85; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holds
    ADD CONSTRAINT fk_rails_ef7ee81f85 FOREIGN KEY (action_id) REFERENCES public.actions(id);


--
-- Name: inbox_items fk_rails_f3cbd78074; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_items
    ADD CONSTRAINT fk_rails_f3cbd78074 FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id);


--
-- Name: briefing_acknowledgements fk_rails_f8f51f3c3f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.briefing_acknowledgements
    ADD CONSTRAINT fk_rails_f8f51f3c3f FOREIGN KEY (review_id) REFERENCES public.reviews(id);


--
-- Name: jobs fk_rails_fc8fe60b73; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT fk_rails_fc8fe60b73 FOREIGN KEY (task_id) REFERENCES public.tasks(id);


--
-- Name: rule_checks rule_checks_rule_version_of_rule_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rule_checks
    ADD CONSTRAINT rule_checks_rule_version_of_rule_fkey FOREIGN KEY (rule_id, rule_version_id) REFERENCES public.rule_versions(rule_id, id);


--
-- Name: rules rules_current_version_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules
    ADD CONSTRAINT rules_current_version_fkey FOREIGN KEY (id, current_version) REFERENCES public.rule_versions(rule_id, version) DEFERRABLE INITIALLY DEFERRED;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261124171356'),
('20261124100000'),
('20261121114342'),
('20261121011155'),
('20261120094700'),
('20261120011824'),
('20261119182802'),
('20261119162424'),
('20261119162423'),
('20261119162422'),
('20261119162421'),
('20261119162420'),
('20261119162419'),
('20261119162418'),
('20261119162417'),
('20261119162416'),
('20261119162415'),
('20261119162414');

