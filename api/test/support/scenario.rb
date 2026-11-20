# Builds the state a test needs (milestone 2 plan WP1, TS-8): it inserts
# rows through the models and appends the events that match them through
# Leverage::EventLog, never through a command's entry, so a test of one
# entry does not depend on another package's entries. A task's row and an
# event of that task are always written in one transaction, because the
# deferred state trigger refuses a task without one (test_helper fires it
# in every transactional test; a commit fires it in a CommittingTestCase).
#
#   scenario = Scenario.new(lease_length_seconds: 600)
#   builder = scenario.seat(role: "builder", credential: scenario.credential)
#   task = scenario.task(state: "working", builder: builder)
#   scenario.make_due(task)                    # the lease is past its due time
#   scenario.token_for(builder)                # the seat's bearer token
#
# Milestone 3 adds (its plan, WP1): limit_credential, sign_out_credential,
# hold (a credential hold with its item, or item: false), pause_seat,
# run (where a seat's run is), finishing_task (HS-3), and a seat's run on
# its own credential by default.
#
# Milestone 4 adds (its plan, WP1, RT-2): with_shipped_rules, rule (a
# custom rule and its versions), current_version, rule_check (with its
# attempts and their jobs), job (in any state), pending_transition (with
# its request), orchestrator and planner, and seed's rules. A workspace
# still has no rule row unless a test asks for one (RT-2).
#
# Every value is made up. Each method returns the row it made.
class Scenario
  PASSWORD = "made-up-password-1".freeze

  # The states Scenario#task can build, in the order a task reaches them.
  # Finishing needs an outward action, which milestone 2 does not build.
  TASK_STATES = %w[imaginarium backlog ready working in_review done cancelled].freeze

  attr_reader :workspace

  # settings: workspace columns (lease_length_seconds, maximum_rounds, ...).
  def initialize(**settings)
    @tokens = {}
    @positions = 0
    @workspace = Workspace.create!(**settings)
  end

  def workspace_id = workspace.id

  # The bearer token made for a seat, a helper or a session, or nil.
  def token_for(record)
    @tokens[record.id]
  end

  # The owner: the workspace's one user.
  def owner(email_address: nil, password: PASSWORD, id: nil)
    @owner ||= User.create!(id: id || SecureRandom.uuid, workspace_id: workspace_id, password: password,
      email_address: email_address || "owner-#{SecureRandom.hex(4)}@example.test")
  end

  # A signed-in session of the owner. Returns the Session; its token is
  # token_for(session), or owner_token for the first one.
  def owner_session(user = owner)
    token, digest = issue(:owner)
    Session.create!(workspace_id: workspace_id, user_id: user.id, token_hash: digest).tap { |session| remember(session, token) }
  end

  def owner_token
    @owner_token ||= token_for(owner_session)
  end

  # The workspace's helper (one per workspace), with a token.
  def helper(name: "Made-up Mac", id: nil)
    @helper ||= begin
      token, digest = issue(:helper)
      Helper.create!(id: id || SecureRandom.uuid, workspace_id: workspace_id, name: name, token_hash: digest)
        .tap { |helper| remember(helper, token) }
    end
  end

  def helper_token = token_for(helper)

  # A credential. added: true (the default) is a credential whose checks
  # have passed, with its credential.added event; added: false is one whose
  # Add credential is still running (IN-24): signed out and no event.
  # limited_until: alone also sets limited_since (milestone 3 plan HE-3: a
  # reset time is only stored for a limit that was reported), to the
  # earlier of the database's now and the reset time.
  def credential(provider: "claude", kind: "login", name: nil, added: true, id: nil, **columns)
    @positions += 1
    values = { id: id || SecureRandom.uuid, workspace_id: workspace_id, kind: kind, provider: provider,
               name: name || "Made-up account #{@positions}", position: @positions,
               state: added ? "active" : "signed_out", last_verified_at: (Time.current if added) }
    if columns[:limited_until] && !columns.key?(:limited_since)
      columns[:limited_since] = [ database_now, columns[:limited_until] ].min
    end
    transaction do
      credential = Credential.create!(**values, **columns)
      append("credential.added", subject: credential) if added
      credential
    end
  end

  # A seat, with seat.connected. A seat the app runs has a credential; the
  # provider comes from it. token: false leaves the seat without one (a seat
  # the app runs before the helper picks its token up). A seat with a token
  # has its run on its own credential (milestone 3 plan HD-3:
  # run_credential_id is the credential its token was issued for) unless
  # the test names run_credential_id; run(seat, on:) moves it.
  def seat(role: "builder", credential: nil, provider: nil, name: nil, model: "made-up-model", effort: "",
           strength_rank: 1, token: true, id: nil, **columns)
    token_value, digest = issue(:seat) if token
    values = { id: id || SecureRandom.uuid, workspace_id: workspace_id, role: role, credential_id: credential&.id,
               provider: credential&.provider || provider || "claude", name: name || "Made-up #{role} #{SecureRandom.hex(3)}",
               model: model, effort: effort, strength_rank: strength_rank, token_hash: digest,
               run_credential_id: (credential&.id if token) }
    transaction do
      seat = Seat.create!(**values.merge(columns))
      remember(seat, token_value) if token
      append("seat.connected", subject: seat, actor_kind: "owner", actor_id: owner.id)
      seat
    end
  end

  # A project, with project.created. Tasks have no project in milestone 2
  # (SC-8); a trace's setup may still name one.
  def project(name: "Made-up project", id: nil, **columns)
    transaction do
      project = Project.create!(id: id || SecureRandom.uuid, workspace_id: workspace_id, name: name, **columns)
      append("project.created", project_id: project.id, actor_kind: "owner", actor_id: owner.id)
      project
    end
  end

  # A task in the given state, with the events that brought it there:
  #
  #   backlog, imaginarium  task.created
  #   ready                 + task.contract_changed, task.ready (criteria made)
  #   working               + task.claimed by builder (lease granted)
  #   in_review             + criterion.started and criterion.passed for each
  #                           build criterion, task.submitted (review row made)
  #   done                  + review.started by reviewer, review.passed, task.done
  #   cancelled             task.created, task.cancelled
  #
  # criteria: the kinds of the contract's criteria, in order. builder and
  # reviewer default to new seats of that role.
  def task(state: "backlog", builder: nil, reviewer: nil, criteria: %w[build review], title: "A made-up task",
           goal: "A made-up goal.", details: nil, priority: "normal", work_reference: "~/work/made-up", project: nil,
           id: nil)
    raise ArgumentError, "Scenario#task builds #{TASK_STATES.join(", ")}, not #{state}" unless TASK_STATES.include?(state)

    reach = TASK_STATES.index(state)
    transaction do
      first = state == "imaginarium" ? "imaginarium" : "backlog"
      task = Task.create!(id: id || SecureRandom.uuid, workspace_id: workspace_id, project_id: project&.id, title: title,
        goal: goal, details: details, work_reference: work_reference, priority: priority, state: first)
      append("task.created", task: task, actor_kind: "owner", actor_id: owner.id, payload: { state: first })
      if state == "cancelled"
        move(task, "cancelled", "task.cancelled", actor_kind: "owner", actor_id: owner.id)
      elsif reach >= TASK_STATES.index("ready")
        contract(task, criteria)
        claim(task, builder || seat(role: "builder")) if reach >= TASK_STATES.index("working")
        submit(task) if reach >= TASK_STATES.index("in_review")
        pass(task, reviewer || seat(role: "reviewer")) if state == "done"
      end
      task.reload
    end
  end

  # The open review of an In review task, claimed by reviewer: the review
  # lease is granted and review.started written.
  def review(task, reviewer: nil)
    reviewer ||= seat(role: "reviewer")
    transaction do
      review = Review.where(task_id: task.id, verdict: nil).order(:round).last || raise(ArgumentError, "the task has no open review")
      review.update!(reviewer_seat_id: reviewer.id, credential_id: reviewer.credential_id, lease_due_at: lease_due_at)
      append("review.started", task: task, subject: review, actor_kind: "seat", actor_id: reviewer.id,
        payload: { credential_id: reviewer.credential_id, model: reviewer.model.presence })
      review
    end
  end

  # Marks a credential limited (milestone 3 plan HE-3): limited_since
  # (default the database's now) and limited_until, the reset time (nil
  # for a limit with no reset time). With seat:, the run that met the
  # limit, it also appends credential.limit_reached, on the task or the
  # review's task it names. Returns the Credential, reloaded.
  def limit_credential(credential, reset_at: nil, since: nil, seat: nil, task: nil, review: nil, window: "five_hour")
    transaction do
      credential.update!(limited_since: since || database_now, limited_until: reset_at)
      if seat
        append("credential.limit_reached", task: task || (review && Task.find(review.task_id)), subject: credential,
          payload: { seat_id: seat.id, review_id: review&.id, job_id: nil, window: window,
                     reset_at: reset_at&.utc&.iso8601 })
      end
      credential.reload
    end
  end

  # Marks a credential signed out, with credential.signed_out: found by a
  # run of seat on task or review, or by Verify when no seat is named.
  # Returns the Credential, reloaded.
  def sign_out_credential(credential, seat: nil, task: nil, review: nil)
    transaction do
      credential.update!(state: "signed_out")
      append("credential.signed_out", task: task || (review && Task.find(review.task_id)), subject: credential,
        payload: { seat_id: seat&.id, review_id: review&.id, job_id: nil })
      credential.reload
    end
  end

  # Opens a hold on a task through Leverage::Holds, as the app: its
  # hold.opened, the Needs you item the registry names for the reason
  # unless item: false, and the lease clocks paused when the reason
  # pauses them. A credential hold names its credential. Returns the Hold.
  def hold(task, reason:, credential: nil, item: true, facts: {})
    transaction do
      Leverage::Holds.open(context, task: task, reason: reason, credential_id: credential&.id, item: item, facts: facts)
    end
  end

  # Pauses a seat, with seat.paused by the owner. A task it holds is not
  # held here: hold(task, reason: "seat_paused") does that. Returns the
  # Seat, reloaded.
  def pause_seat(seat)
    transaction do
      seat.update!(paused: true)
      append("seat.paused", subject: seat, actor_kind: "owner", actor_id: owner.id)
      seat.reload
    end
  end

  # Puts the seat's run on a credential (default its own), in run state
  # state (milestone 3 plan HD-3: run_credential_id is the credential the
  # seat's current token was issued for). on: nil leaves it on none.
  # Returns the Seat, reloaded.
  def run(seat, on: :own, state: "running")
    credential_id = on == :own ? seat.credential_id : on&.id
    seat.update!(run_credential_id: credential_id, run_state: state)
    seat.reload
  end

  # A task in Finishing, which no command can reach until milestone 5
  # (milestone 3 plan HS-3), for the tests that prove a row from Finishing
  # is refused invalid_state. It is built to Working (builder holds it,
  # with its lease) and moved to Finishing with task.changed, an event no
  # step reads; no outward action row is made (SC-3). Returns the Task.
  def finishing_task(builder: nil)
    transaction do
      row = task(state: "working", builder: builder)
      row.update!(state: "finishing")
      append("task.changed", task: row, actor_kind: "owner", actor_id: owner.id,
        payload: { priority: row.priority, project_id: row.project_id, budget_cap: row.budget_cap })
      row.reload
    end
  end

  # Appends one event through EventLog, at the database clock unless at:
  # is given. The actor is the app unless named. Returns the Event.
  def append(type, task: nil, subject: nil, payload: {}, actor_kind: "app", actor_id: nil, cause_id: nil,
             project_id: nil, round: nil, at: nil, effective_at: nil)
    transaction do
      ctx = context(at: at)
      fields = { subject: subject, payload: payload, actor_kind: actor_kind, actor_id: actor_id, cause_id: cause_id,
                 command_id: nil }
      fields[:task] = task if task
      fields[:project_id] = project_id if project_id
      fields[:round] = round if round
      fields[:effective_at] = effective_at if effective_at
      ctx.emit(type, **fields)
    end
  end

  # Puts a task's or a review's lease due time at the database's now
  # (EN-18): the engine has no clock stub, and no test sleeps past a lease.
  # Any later command's clock is past it, and it is never before the events
  # Scenario has just written, so no test relies on the timers' clamp of
  # effective_at to the task's latest event (WP5's choice 3).
  def make_due(record, at: nil)
    record.update_columns(lease_due_at: at || database_now)
    record
  end

  # Ends a token the way a later command would: a seat's or a helper's
  # digest is cleared, a session is deleted.
  def end_token(record)
    record.is_a?(Session) ? record.destroy! : record.update_columns(token_hash: SecureRandom.hex(32))
    record
  end

  # Marks a seat removed without touching its token, so a test can prove
  # that authentication checks removed_at as well.
  def remove(seat)
    seat.update_columns(removed_at: database_now)
    seat
  end

  # Builds a golden trace's setup (TS-8), already bound by TraceBinder:
  # settings, users, helpers, rules, credentials, seats and projects with
  # their ids, and the events they imply. The rules come right after the
  # owner, so their rule.created are the workspace's first events but the
  # owner's (SM-33). A shipped rule's version fields are Rules::Shipped's;
  # a custom rule's are on its row (seed_rule).
  def seed(setup)
    workspace.update!(setup.fetch("settings", {}))
    Array(setup["users"]).each { |user| owner(id: user.fetch("id")) }
    Array(setup["helpers"]).each { |row| helper(id: row.fetch("id"), name: row.fetch("name")) }
    Array(setup["rules"]).each { |row| seed_rule(row) }
    Array(setup["credentials"]).each do |row|
      @positions = [ @positions, row.fetch("position") - 1 ].max
      credential(**row.transform_keys(&:to_sym).except(:state), added: row.fetch("state") == "active")
    end
    Array(setup["seats"]).each { |row| seat(**row.transform_keys(&:to_sym)) }
    Array(setup["projects"]).each { |row| project(**row.transform_keys(&:to_sym)) }
    self
  end

  # --- milestone 4: rules, checks, jobs, pending transitions -----------------

  # The version fields of a custom rule a test does not name (DB-28): a
  # blocking model gate checked by the orchestrator, every task, its
  # failures to the builder.
  CUSTOM_RULE = { name: "A made-up rule", hook: "task.before_submit", kind: "gate", checker: "model",
                  scope_kind: "all_tasks", scope_values: [], checker_function: nil, parameters: {},
                  instruction: "Made-up instruction: pass work that says what it changed.", checker_role: "orchestrator",
                  on_fail: "block", route: "builder", queue_timeout_seconds: nil, run_timeout_seconds: nil }.freeze

  # The seven shipped rules (Rules::Shipped), each at version 1 with
  # rule.created by the owner, as create_owner writes them (L434). off:
  # the keys created switched off. Returns the Rules, in shipped order.
  def with_shipped_rules(off: [])
    Leverage::Rules::Shipped.all.map do |record|
      rule(key: record.key, origin: "shipped", enabled: !off.include?(record.key), **record.version_fields.except(:key, :origin))
    end
  end

  # A rule with versions 1 to versions, all with the same fields: a custom
  # rule (key custom_ and its id, RD-23) unless origin: "shipped" and a key
  # are given. rule.created by the owner for version 1, rule.changed for
  # each later one. fields: rule_versions columns over CUSTOM_RULE (a
  # shipped rule's come from Rules::Shipped when not given). Returns the
  # Rule.
  def rule(key: nil, origin: "custom", enabled: true, versions: 1, id: nil, version_id: nil, **fields)
    id ||= SecureRandom.uuid
    key ||= "custom_#{id}"
    base = origin == "shipped" ? Leverage::Rules::Shipped.find(key).version_fields.except(:key, :origin) : CUSTOM_RULE
    values = base.merge(fields)
    # A custom app rule has a function, not an instruction (RD-6).
    values = values.merge(instruction: nil, checker_role: nil).merge(fields) if origin != "shipped" && values[:checker] == "app"
    transaction do
      rule = Rule.create!(id: id, workspace_id: workspace_id, key: key, enabled: enabled, current_version: versions)
      (1..versions).each do |number|
        version = RuleVersion.create!(id: (version_id if number == versions) || SecureRandom.uuid, workspace_id: workspace_id,
          rule_id: rule.id, version: number, key: key, origin: origin, author_kind: "owner", author_id: owner.id, **values)
        if number == 1
          append("rule.created", subject: rule, actor_kind: "owner", actor_id: owner.id,
            payload: { rule_version_id: version.id, version: 1, enabled: enabled })
        else
          append("rule.changed", subject: rule, actor_kind: "owner", actor_id: owner.id,
            payload: { rule_version_id: version.id, version: number })
        end
      end
      rule
    end
  end

  # The rule's current version row.
  def current_version(rule)
    RuleVersion.find_by!(rule_id: rule.id, version: rule.reload.current_version)
  end

  # An orchestrator seat, and a planner seat (milestone 4's two job roles).
  def orchestrator(**options) = seat(role: "orchestrator", **options)

  def planner(**options) = seat(role: "planner", **options)

  # A rule check of the rule's current version on a task, with its
  # attempts, as the app writes them:
  #
  #   an app rule (checker "app")  one attempt queued, started and finished
  #                                at once, no job, and check.finished
  #                                (result required, DB-30);
  #   a model rule                 one rule_check job per attempt (DB-31):
  #                                check.queued and, for the first,
  #                                job.queued; each earlier attempt's job
  #                                timed out and requeued (trace 07). The
  #                                last attempt is queued; started: true
  #                                has the checker (default a new
  #                                orchestrator) claim it (job.claimed,
  #                                check.started); a result finishes it
  #                                (job.finished, check.finished).
  #
  # The reason is on the row only. hook and round default to the version's
  # and the task's; subject is a Seat or a Review (or nil); pending a
  # PendingTransition. Returns the RuleCheck.
  def rule_check(task, rule:, result: nil, reason: nil, effect: nil, attempts: 1, started: false, checker: nil, hook: nil,
                 round: nil, subject: nil, input_hash: nil, pending: nil)
    version = current_version(rule)
    app = version.checker == "app"
    raise ArgumentError, "an app check is written with its result" if app && result.nil?

    transaction do
      check = RuleCheck.create!(workspace_id: workspace_id, task_id: task.id, project_id: task.project_id, rule_id: rule.id,
        rule_version_id: version.id, hook: hook || version.hook, round: round || task.round,
        subject_kind: subject && Leverage::EventLog.kind_of(subject), subject_id: subject&.id,
        input_hash: input_hash || SecureRandom.hex(32), result: result, effect: effect, reason: reason,
        pending_transition_id: pending&.id)
      app ? app_attempt(task, check) : model_attempts(task, check, attempts, started || !result.nil?, checker)
      finish_check(task, check) if result
      check
    end
  end

  # A job of kind on a task, in state: queued (job.queued), claimed by seat
  # (+ job.claimed), finished (+ job.finished), timed_out (+ job.timed_out,
  # claimed first when a seat is named) or withdrawn (+ job.withdrawn,
  # likewise). target defaults to the task (a contract draft's), seat_role
  # to the kind's (orchestrator, or planner for a draft). Returns the Job.
  def job(kind:, task:, target: task, state: "queued", seat: nil, seat_role: nil, attempt_number: 1, input: {})
    raise ArgumentError, "a #{state} job needs the seat that claimed it" if %w[claimed finished].include?(state) && seat.nil?

    transaction do
      at = database_now
      job = Job.create!(workspace_id: workspace_id, kind: kind, task_id: task&.id, project_id: task&.project_id,
        target_kind: Leverage::EventLog.kind_of(target), target_id: target.id,
        seat_role: seat_role || (kind == "contract_draft" ? "planner" : "orchestrator"), state: "queued", queued_at: at,
        input: input, attempt_number: attempt_number)
      job_event("job.queued", job, task, payload: { kind: kind })
      claim_job(job, task, seat) if seat
      job.update!(state: state, finished_at: (at if %w[finished timed_out withdrawn].include?(state)))
      { "finished" => "job.finished", "timed_out" => "job.timed_out", "withdrawn" => "job.withdrawn" }[state]
        &.then { |type| job_event(type, job, task) }
      job
    end
  end

  # A pending transition of a task: the command waiting, its requester (a
  # Seat or the owner's User), the requester's key, the rule versions
  # frozen for it and the request it will complete with (RE-2). The row
  # only: no event records a pending transition. Returns the
  # PendingTransition.
  def pending_transition(task, command:, requester:, key: nil, params: {}, frozen_rule_version_ids: [], state: "pending")
    PendingTransition.create!(workspace_id: workspace_id, task_id: task.id, command: command,
      command_key: key || "key-#{SecureRandom.hex(6)}", requester_kind: requester.is_a?(User) ? "owner" : "seat",
      requester_id: requester.id, frozen_rule_version_ids: frozen_rule_version_ids, state: state,
      params: (params if state == "pending"))
  end

  # A Context holding the workspace lock in the current transaction: what
  # an engine test needs to call EventLog, Holds or Leases directly.
  def context(at: nil, request: nil)
    workspace_row, clock = Leverage::WorkspaceLock.take(workspace_id)
    request ||= Leverage::Transitions::Request.new(command: "scenario", workspace_id: workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: {})
    Leverage::Transitions::Context.new(request: request, workspace: workspace_row, at: at || clock)
  end

  def database_now
    ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
  end

  private

  # One rule of a golden trace's setup: its id, key, switch, current
  # version and that version's id. A shipped rule's fields are
  # Rules::Shipped's; a custom rule's row carries them (name, hook, kind,
  # checker, scope {kind, values}, instruction, checker_function,
  # parameters, checker_role, on_fail, route, the two timeouts).
  def seed_rule(row)
    shipped = row.fetch("origin") == "shipped"
    fields = row.except("id", "key", "origin", "enabled", "current_version", "current_version_id", "scope")
      .transform_keys(&:to_sym)
    if (scope = row["scope"])
      fields[:scope_kind] = scope.fetch("kind")
      fields[:scope_values] = scope.fetch("values")
    end
    unless shipped || (fields[:name] && fields[:hook])
      raise ArgumentError, "the setup's custom rule #{row.fetch("key")} names no version fields (name, hook, ...)"
    end
    rule(key: row.fetch("key"), origin: row.fetch("origin"), enabled: row.fetch("enabled"),
      versions: row.fetch("current_version"), id: row.fetch("id"), version_id: row.fetch("current_version_id"), **fields)
  end

  def app_attempt(task, check)
    at = database_now
    RuleCheckAttempt.create!(workspace_id: workspace_id, rule_check_id: check.id, attempt_number: 1, queued_at: at,
      started_at: at, finished_at: at)
  end

  # The model attempts of a check, each with its job; the last one claimed
  # by checker when claimed is true.
  def model_attempts(task, check, count, claimed, checker)
    previous = nil
    blocking = RuleVersion.find(check.rule_version_id).on_fail != "warn"
    (1..count).each do |number|
      if previous
        previous.update!(state: "timed_out", finished_at: database_now)
        job_event("job.timed_out", previous, task)
        job_event("job.requeued", previous, task)
      end
      job = Job.create!(workspace_id: workspace_id, kind: "rule_check", task_id: task.id, project_id: task.project_id,
        target_kind: "rule_check", target_id: check.id, seat_role: "orchestrator", state: "queued", queued_at: database_now,
        input: {}, attempt_number: number)
      RuleCheckAttempt.create!(workspace_id: workspace_id, rule_check_id: check.id, attempt_number: number, job_id: job.id,
        queued_at: job.queued_at)
      append("check.queued", task: task, subject: check, payload: check_payload(check).merge(attempt_number: number,
        job_id: job.id, blocking: blocking, claimant_seat_id: nil, pending_transition_id: check.pending_transition_id,
        action_id: nil))
      job_event("job.queued", job, task, payload: { kind: "rule_check" }) if number == 1
      previous = job
    end
    return unless claimed

    seat = checker || orchestrator
    claim_job(previous, task, seat)
    RuleCheckAttempt.find_by!(rule_check_id: check.id, attempt_number: count)
      .update!(started_at: previous.claimed_at, checker_seat_id: seat.id)
    append("check.started", task: task, subject: check, actor_kind: "seat", actor_id: seat.id,
      payload: { attempt_number: count })
  end

  # Ends a check with its result: the last attempt finishes, its job too.
  def finish_check(task, check)
    attempt = RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last
    at = database_now
    attempt.update!(finished_at: at) unless attempt.finished_at
    if attempt.job_id
      job = Job.find(attempt.job_id)
      job.update!(state: "finished", finished_at: at)
      job_event("job.finished", job, task)
    end
    append("check.finished", task: task, subject: check, payload: check_payload(check).merge(result: check.result,
      effect: check.effect, wait_cause: nil))
  end

  def check_payload(check)
    { hook: check.hook, rule_id: check.rule_id, rule_version_id: check.rule_version_id, subject_kind: check.subject_kind,
      subject_id: check.subject_id, input_hash: check.input_hash }
  end

  def claim_job(job, task, seat)
    job.update!(state: "claimed", claimed_by_seat_id: seat.id, claimed_at: database_now, credential_id: seat.credential_id)
    job_event("job.claimed", job, task, actor_kind: "seat", actor_id: seat.id,
      payload: { credential_id: seat.credential_id, model: seat.model.presence })
  end

  def job_event(type, job, task, payload: {}, actor_kind: "app", actor_id: nil)
    fields = { subject: job, payload: payload, actor_kind: actor_kind, actor_id: actor_id }
    fields[:task] = task if task
    append(type, **fields)
  end

  def transaction(&block)
    ActiveRecord::Base.transaction(requires_new: true, &block)
  end

  def issue(kind)
    token = Leverage::Tokens.issue(kind)
    [ token, Leverage::Tokens.digest(token) ]
  end

  def remember(record, token)
    @tokens[record.id] = token
  end

  def lease_due_at
    database_now + workspace.reload.lease_length_seconds
  end

  def move(task, state, type, payload: {}, **actor)
    task.update!(state: state)
    append(type, task: task, payload: payload, **actor)
  end

  def contract(task, kinds)
    criteria = kinds.each_with_index.map do |kind, index|
      Criterion.create!(workspace_id: workspace_id, task_id: task.id, position: index + 1, kind: kind,
        text: "Made-up criterion #{index + 1}.")
    end
    task.update!(contract_version: 1)
    append("task.contract_changed", task: task, actor_kind: "owner", actor_id: owner.id,
      payload: { contract_version: 1, minimum_strength_rank: task.minimum_strength_rank,
                 added_criterion_ids: criteria.map(&:id), reset_criterion_ids: [],
                 removed_criterion_ids: [], added_action_ids: [], removed_action_ids: [] })
    move(task, "ready", "task.ready", payload: { wait_cause: nil }, actor_kind: "owner", actor_id: owner.id)
  end

  def claim(task, builder)
    task.update!(holder_seat_id: builder.id, builder_seat_id: builder.id, credential_id: builder.credential_id,
      lease_due_at: lease_due_at)
    move(task, "working", "task.claimed", actor_kind: "seat", actor_id: builder.id,
      payload: { seat_id: builder.id, credential_id: builder.credential_id, model: builder.model.presence })
  end

  def submit(task)
    builder_id = task.holder_seat_id
    Criterion.where(task_id: task.id, kind: "build", removed_at: nil).order(:position).each do |criterion|
      append("criterion.started", task: task, subject: criterion, actor_kind: "seat", actor_id: builder_id)
      criterion.update!(state: "passed", passed_at: database_now, passed_by_seat_id: builder_id)
      append("criterion.passed", task: task, subject: criterion, actor_kind: "seat", actor_id: builder_id)
    end
    review = Review.create!(workspace_id: workspace_id, task_id: task.id, round: task.round)
    task.update!(state: "in_review", holder_seat_id: nil, lease_due_at: nil)
    append("task.submitted", task: task, subject: review, actor_kind: "seat", actor_id: builder_id,
      payload: { work_reference_changed: false })
  end

  def pass(task, reviewer)
    review = review(task, reviewer: reviewer)
    review.update!(verdict: "passed", lease_due_at: nil)
    Criterion.where(task_id: task.id, kind: "review", removed_at: nil).update_all(state: "passed", passed_at: database_now,
      passed_by_seat_id: reviewer.id)
    append("review.passed", task: task, subject: review, actor_kind: "seat", actor_id: reviewer.id)
    move(task, "done", "task.done", actor_kind: "seat", actor_id: reviewer.id)
  end
end
