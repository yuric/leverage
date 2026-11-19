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
  def credential(provider: "claude", kind: "login", name: nil, added: true, id: nil, **columns)
    @positions += 1
    values = { id: id || SecureRandom.uuid, workspace_id: workspace_id, kind: kind, provider: provider,
               name: name || "Made-up account #{@positions}", position: @positions,
               state: added ? "active" : "signed_out", last_verified_at: (Time.current if added) }
    transaction do
      credential = Credential.create!(**values, **columns)
      append("credential.added", subject: credential) if added
      credential
    end
  end

  # A seat, with seat.connected. A seat the app runs has a credential; the
  # provider comes from it. token: false leaves the seat without one (a seat
  # the app runs before the helper picks its token up).
  def seat(role: "builder", credential: nil, provider: nil, name: nil, model: "made-up-model", effort: "",
           strength_rank: 1, token: true, id: nil, **columns)
    token_value, digest = issue(:seat) if token
    values = { id: id || SecureRandom.uuid, workspace_id: workspace_id, role: role, credential_id: credential&.id,
               provider: credential&.provider || provider || "claude", name: name || "Made-up #{role} #{SecureRandom.hex(3)}",
               model: model, effort: effort, strength_rank: strength_rank, token_hash: digest }
    transaction do
      seat = Seat.create!(**values, **columns)
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
  # settings, users, helpers, credentials, seats and projects with their
  # ids, and the events they imply. Rules arrive in milestone 4.
  def seed(setup)
    raise ArgumentError, "rules arrive in milestone 4 (EN-4)" unless Array(setup["rules"]).empty?

    workspace.update!(setup.fetch("settings", {}))
    Array(setup["users"]).each { |user| owner(id: user.fetch("id")) }
    Array(setup["helpers"]).each { |row| helper(id: row.fetch("id"), name: row.fetch("name")) }
    Array(setup["credentials"]).each do |row|
      @positions = [ @positions, row.fetch("position") - 1 ].max
      credential(**row.transform_keys(&:to_sym).except(:state), added: row.fetch("state") == "active")
    end
    Array(setup["seats"]).each { |row| seat(**row.transform_keys(&:to_sym)) }
    Array(setup["projects"]).each { |row| project(**row.transform_keys(&:to_sym)) }
    self
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
      payload: { contract_version: 1, added_criterion_ids: criteria.map(&:id), reset_criterion_ids: [],
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
