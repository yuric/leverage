module Leverage
  # The timers (PRD L118-L120; timers.json): which are due for a task, a
  # seat or a workspace, applied each through its own entry before a
  # command's own work (milestone 2 plan §2.1 step 3, EN-14, EN-17).
  #
  # Milestone 2 has the two lease timers and command_key_retention;
  # milestone 3 adds the credential hold release (a task timer, due as rule
  # 8 of its plan's §2.1 and HE-23 say) and seat_run_placement (a workspace
  # timer, HD-4). Milestone 4 adds the four job timers (JOB_TIMERS: a rule
  # check's attempt or a contract draft not claimed, or not finished, in
  # time) and two workspace timers, orchestrator_offline and
  # reviewer_eligibility. The workspace timers are fired by the sweep
  # (Sweep), never by a command.
  #
  # A job timer's events are the app's, with no key, effective at its due
  # time, also when a writer of another package (Jobs, RuleChecks,
  # PendingTransitions, Holds) writes them: the timer runs it inside
  # as_timer, a TimerContext whose actor, key and effective time are the
  # timer's, so a writer that keeps the context's defaults, and dates the
  # rows it changes with ctx.effective_at, records the miss at the due
  # time (milestone 4 plan WP7; trace 07).
  module Timers
    # The task timers a command applies first, by the subject whose due
    # time they read (timers.json).
    BUILDER_LEASE = "builder_lease_expiry".freeze
    REVIEW_LEASE = "review_lease_expiry".freeze
    CREDENTIAL_HOLD = "credential_hold_release".freeze
    # The workspace timer the sweep fires on every run (HD-4).
    SEAT_RUN_PLACEMENT = "seat_run_placement".freeze
    # The hold reasons the credential timer closes (state_machine.json,
    # credential_hold_release's holds_closed).
    CREDENTIAL_REASONS = %w[credential_limit credential_signed_out].freeze

    # The params a path or a body names a task or a review by: /v1/tasks/{id}
    # and /v1/owner/tasks/{id} name a task, /v1/reviews/{id} a review.
    TARGET_PARAMS = %w[id task_id review_id].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # Every timer of timers.json, task and workspace, those of later
    # milestones among them: a timer's own command applies no timer first.
    TIMER_COMMANDS = Contract.timers.fetch("timers").map { |timer| timer.fetch("timer") }.freeze

    # What Timers.apply_workspace runs (milestone 4 plan §0.1 fact 6,
    # RD-2): the workspace timers of timers.json, and the commands the app
    # runs on a workspace with no state (every state_machine.json row of
    # the command is the app's and reads no state: install_shipped_rules).
    WORKSPACE_COMMANDS = begin
      timers = Contract.timers.fetch("timers").select { |timer| timer.fetch("scope") == "workspace" }
      rows = Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }.group_by { |row| row.fetch("command") }
      app_commands = rows.select do |command, command_rows|
        !TIMER_COMMANDS.include?(command) && command_rows.all? { |row| row.fetch("who") == [ "app" ] && row.fetch("from").nil? }
      end
      (timers.map { |timer| timer.fetch("timer") } + app_commands.keys).freeze
    end

    # The param Timers.apply_workspace hands the time in by; Context reads
    # it as the command's effective_at.
    EFFECTIVE_AT = "effective_at".freeze

    # Approval jobs and ordinary rule checks share the check timers and
    # the attempt's rule-version timeouts.
    CHECK_JOB_KINDS = Contract.jobs.fetch("jobs").filter_map do |job|
      job.fetch("kind") if job.fetch("queue_timer") == "check_queue_timeout"
    end.freeze

    # The kinds, active state and deadline each served job timer reads.
    JOB_TIMERS = {
      "check_queue_timeout" => { kinds: CHECK_JOB_KINDS, state: "queued", due: :queue }.freeze,
      "check_run_timeout" => { kinds: CHECK_JOB_KINDS, state: "claimed", due: :run }.freeze,
      "question_job_queue_timeout" => { kinds: %w[question].freeze, state: "queued", due: :queue }.freeze,
      "question_job_run_timeout" => { kinds: %w[question].freeze, state: "claimed", due: :run }.freeze,
      "contract_draft_job_queue_timeout" => { kinds: %w[contract_draft].freeze, state: "queued", due: :queue }.freeze,
      "contract_draft_job_run_timeout" => { kinds: %w[contract_draft].freeze, state: "claimed", due: :run }.freeze
    }.freeze

    # Use the same check-attempt and workspace timeouts as job_due_at.
    CHECK_DUE_SQL = {
      queue: "rule_check_attempts.queued_at + COALESCE(rule_versions.queue_timeout_seconds, " \
             "workspaces.check_queue_timeout_seconds) * interval '1 second'",
      run: "rule_check_attempts.started_at + COALESCE(rule_versions.run_timeout_seconds, " \
           "workspaces.check_run_timeout_seconds) * interval '1 second'"
    }.freeze
    WORKSPACE_JOB_DUE_SQL = {
      queue: "jobs.queued_at + workspaces.check_queue_timeout_seconds * interval '1 second'",
      run: "jobs.claimed_at + workspaces.check_run_timeout_seconds * interval '1 second'"
    }.freeze
    JOB_DUE_SQL = CHECK_JOB_KINDS.index_with(CHECK_DUE_SQL)
      .merge(%w[question contract_draft].index_with(WORKSPACE_JOB_DUE_SQL)).freeze
    CHECK_JOINS = "JOIN rule_check_attempts ON rule_check_attempts.job_id = jobs.id " \
                  "JOIN rule_checks ON rule_checks.id = rule_check_attempts.rule_check_id " \
                  "JOIN rule_versions ON rule_versions.id = rule_checks.rule_version_id".freeze

    # A command's Context for one timer applied inside it (as_timer): the
    # app's, with no key and the timer's effective time, on the command's
    # workspace, clock and lock. Each event it appends is also the
    # command's, so the command sees it in ctx.events and commits it.
    class TimerContext < Transitions::Context
      def initialize(parent, command, effective_at)
        request = Transitions::Request.new(command: command, workspace_id: parent.workspace.id, caller_kind: nil,
          caller_id: nil, key: nil, request_hash: nil, params: { EFFECTIVE_AT => effective_at.utc.iso8601(6) })
        super(request: request, workspace: parent.workspace, at: parent.at)
        @parent = parent
      end

      def appended(event, seconds)
        super
        @parent.appended(event, seconds)
      end
    end

    # The workspace's timeout of each due time kind (timers.json).
    WORKSPACE_TIMEOUTS = { queue: :check_queue_timeout_seconds, run: :check_run_timeout_seconds }.freeze
    # A rule version's own timeout of each, which wins when it is set.
    VERSION_TIMEOUTS = { queue: :queue_timeout_seconds, run: :run_timeout_seconds }.freeze

    module_function

    # Runs a workspace timer, or a command the app runs on a workspace
    # (WORKSPACE_COMMANDS), as the sweep does (Sweep.timer: as the app,
    # with no key and no commands row), with at as the effective time of
    # what it writes: Context#effective_at, which emit gives every event
    # that names none. at is never later than the command's own clock,
    # read under the lock, and the events' at is that clock (milestone 4
    # plan §0.1 fact 6; WP1's choice, in its notes). The sweep's timers
    # (WP7), the reviewer_eligibility timer (WP9) and the install task
    # (WP8, RD-2) run through it.
    #
    # workspace - a Workspace or its id.
    # name      - a WORKSPACE_COMMANDS name.
    # at:       - a Time.
    #
    # Returns the command's Outcome. Raises ArgumentError for any other
    # name.
    def apply_workspace(workspace, name, at:)
      raise ArgumentError, "#{name.inspect} is not a workspace timer or an app command" unless WORKSPACE_COMMANDS.include?(name.to_s)

      workspace_id = workspace.respond_to?(:id) ? workspace.id : workspace
      Sweep.timer(workspace_id, name.to_s, EFFECTIVE_AT => at.utc.iso8601(6))
    end

    # A job's due time (timers.json): kind :queue is when it must have
    # been claimed, :run when its result must have arrived. A job that
    # runs a rule check's attempt is due from the attempt's queued or
    # started time plus the rule version's own timeout, or the workspace's
    # when the version has none; any other job (a contract draft, a
    # question) from its own queued or claimed time plus the workspace's
    # (DB-31). nil for :run while the job has not started.
    #
    # Raises ArgumentError for another kind.
    def job_due_at(job, kind)
      raise ArgumentError, "kind is :queue or :run, not #{kind.inspect}" unless WORKSPACE_TIMEOUTS.key?(kind)

      workspace = Workspace.find(job.workspace_id)
      attempt = job.id && RuleCheckAttempt.find_by(job_id: job.id)
      if attempt
        from = kind == :queue ? attempt.queued_at : attempt.started_at
        version = RuleVersion.joins("JOIN rule_checks ON rule_checks.rule_version_id = rule_versions.id")
          .find_by("rule_checks.id = ?", attempt.rule_check_id)
        seconds = version&.public_send(VERSION_TIMEOUTS.fetch(kind))
      else
        from = kind == :queue ? job.queued_at : job.claimed_at
      end
      from && from + (seconds || workspace.public_send(WORKSPACE_TIMEOUTS.fetch(kind)))
    end

    # Applies every timer due on the request's target task (or the task of
    # its target review, job or rule check) and on every task or review the
    # calling seat holds, and the task of the job it holds, with effective_at
    # the due time, actor app, no command_id, and seq before the command's
    # own events: the leases, the credential hold release and the job timers
    # (test 7, whoever the caller is). A timer's own command (the sweep's)
    # applies itself and gets nothing here, and so does a command with no
    # workspace yet (create_owner).
    #
    # ctx - the command's Transitions::Context.
    #
    # Returns the Events it wrote.
    def apply_due(ctx)
      return [] if ctx.workspace.nil? || timer_command?(ctx.request.command)

      apply_task_timers(ctx, due_candidates(ctx))
    end

    # Whether the command is a timer's own: any timer of timers.json.
    def timer_command?(command) = TIMER_COMMANDS.include?(command.to_s)

    # Applies the due lease timers on every task and review a seat holds,
    # as apply_due does for the caller: for a command that decides by what
    # another seat holds (fail_review asks whether the failed review's
    # builder is free). A lease ends at its due time (L120, EN-14), so the
    # answer must not depend on whether the sweep has run. Returns the
    # Events it wrote.
    def apply_held_by(ctx, seat)
      return [] unless seat

      workspace_id = ctx.workspace.id
      held_reviews = Review.where(workspace_id: workspace_id, reviewer_seat_id: seat.id, verdict: nil).select(:task_id)
      tasks = Task.where(workspace_id: workspace_id, holder_seat_id: seat.id)
        .or(Task.where(workspace_id: workspace_id, id: held_reviews)).order(:id).to_a
      apply_task_timers(ctx, tasks)
    end

    # Runs the task timers due on each task, each in the order of its due
    # time, so effective times never go backwards (L120): on each task the
    # credential hold release when it is due no later than the builder's
    # lease, the lease (whose end closes a credential hold still open,
    # SM-15) and the job timers, by due time; then the review lease timer
    # of each of their due reviews; then the job timers due after a review
    # lease of their task. Each timer runs at most once in a command.
    # Returns the Events written.
    def apply_task_timers(ctx, tasks)
      written = ctx.events.size
      applied = Set.new
      tasks.each { |task| apply_before_reviews(ctx, task, applied) }
      due_reviews_of(ctx, tasks.map(&:id)).each do |review|
        apply(ctx, Transitions::Entries::ReviewLeaseExpiry.new(REVIEW_LEASE, targets: [ review ]))
      end
      tasks.each do |task|
        due_job_timers(ctx, task, applied).each { |_due, timer, job| apply_job_timer(ctx, timer, job, applied) }
      end
      ctx.events.drop(written)
    end

    # One task's credential hold release, builder lease and job timers, the
    # earliest due first (a tie: the hold, then the lease, then the jobs),
    # leaving the job timers due after one of the task's review leases to
    # apply_task_timers.
    def apply_before_reviews(ctx, task, applied)
      review_due = due_reviews_of(ctx, [ task.id ]).map(&:lease_due_at).min
      loop do
        task = Task.find(task.id)
        due = []
        due << [ credential_hold_due_at(task), 0, :credential ] if !applied.include?([ :credential, task.id ]) &&
          credential_hold_first?(task, ctx.at)
        due << [ task.lease_due_at, 1, :lease ] if !applied.include?([ :lease, task.id ]) && Leases.due?(task, ctx.at)
        due_job_timers(ctx, task, applied).each do |time, timer, job|
          due << [ time, 2, [ timer, job ] ] unless review_due && time > review_due
        end
        break if due.empty?

        _time, _rank, what = due.each_with_index.min_by { |(time, rank, _what), index| [ time, rank, index ] }.first
        case what
        when :credential
          applied << [ :credential, task.id ]
          apply(ctx, Transitions::Table.entry_for(CREDENTIAL_HOLD).new(CREDENTIAL_HOLD, targets: [ task ]))
        when :lease
          applied << [ :lease, task.id ]
          apply(ctx, Transitions::Entries::BuilderLeaseExpiry.new(BUILDER_LEASE, targets: [ task ]))
        else
          apply_job_timer(ctx, *what, applied)
        end
      end
    end

    def apply_job_timer(ctx, timer, job, applied)
      applied << job.id
      entry = Transitions::Table.entry_for(timer).new(timer, targets: [ job ])
      apply(ctx, entry)
    end

    # Applies the due lease timers a claim would otherwise find in its way:
    # for :task (claim), every builder lease of the workspace past its due
    # time (its task goes back to Ready), for :review (claim_review) every
    # review lease (the review loses its reviewer), so what was due is
    # claimable now, after its lease_expired event at the due time. A job
    # claim applies only the timers of the job its seat holds (apply_due):
    # it never takes a job past its due time (Jobs.claimable), and the
    # sweep times those out. Returns the Events it wrote. Raises
    # ArgumentError for any other kind.
    def apply_claimable(ctx, kind)
      raise ArgumentError, "kind is :task or :review, not #{kind.inspect}" unless %i[task review].include?(kind)

      workspace_id = ctx.workspace.id
      tasks = if kind == :review
        due = Review.where(workspace_id: workspace_id, verdict: nil, lease_time_left_while_paused: nil)
          .where.not(reviewer_seat_id: nil).where(lease_due_at: ..ctx.at).select(:task_id)
        Task.where(workspace_id: workspace_id, id: due)
      else
        Task.where(workspace_id: workspace_id, lease_time_left_while_paused: nil).where(lease_due_at: ..ctx.at)
      end
      apply_lease_timers(ctx, tasks.order(:id).to_a)
    end

    # Runs the builder lease timer of each task whose lease is due, then
    # the review lease timer of each of their due reviews. Returns the
    # Events written.
    def apply_lease_timers(ctx, tasks)
      written = ctx.events.size
      tasks.each do |task|
        apply(ctx, Transitions::Entries::BuilderLeaseExpiry.new(BUILDER_LEASE, targets: [ task ])) if Leases.due?(task, ctx.at)
      end
      due_reviews_of(ctx, tasks.map(&:id)).each do |review|
        apply(ctx, Transitions::Entries::ReviewLeaseExpiry.new(REVIEW_LEASE, targets: [ review ]))
      end
      ctx.events.drop(written)
    end

    # Runs one timer entry inside the current command: its refusals (the
    # state table's), then perform. Finishing receives its own app context
    # so lease grants caused by a timer carry no caller key. Returns
    # whether the timer ran.
    def apply(ctx, entry)
      entry.load(ctx)
      refused = Transitions::Precedence.first(entry.refusals(ctx))
      unless refused
        Transitions::Gate.call(ctx, entry)
        entry.perform(ctx)
      end
      as_timer(ctx, entry.command, ctx.at) { |timer_ctx| Finishing.after_command(timer_ctx) }
      !refused
    end

    # The tasks a command touches: the one its params name (directly or
    # through a review) and those whose task or review the calling seat
    # holds. In id order, so two timers in one command come in a fixed
    # order.
    def due_candidates(ctx)
      workspace_id = ctx.workspace.id
      ids = target_ids(ctx.request.params)
      return [] if ids.empty? && ctx.request.caller_kind != "seat"

      targets = [ Review, Job, RuleCheck ]
      targets << Question if %w[answer_question overturn_answer].include?(ctx.request.command)
      task_ids = ids.empty? ? [] : ids + targets.flat_map { |model| model.where(workspace_id: workspace_id, id: ids).pluck(:task_id) }
      scope = Task.where(workspace_id: workspace_id, id: task_ids.compact)
      if ctx.request.caller_kind == "seat"
        seat_id = ctx.request.caller_id
        held_reviews = Review.where(workspace_id: workspace_id, reviewer_seat_id: seat_id, verdict: nil).select(:task_id)
        held_jobs = Job.where(workspace_id: workspace_id, claimed_by_seat_id: seat_id, state: "claimed").select(:task_id)
        scope = scope.or(Task.where(workspace_id: workspace_id, holder_seat_id: seat_id))
          .or(Task.where(workspace_id: workspace_id, id: held_reviews))
          .or(Task.where(workspace_id: workspace_id, id: held_jobs))
      end
      scope.order(:id).to_a
    end

    # The open reviews of these tasks whose lease is due at ctx.at.
    def due_reviews_of(ctx, task_ids)
      return [] if task_ids.empty?

      Review.where(workspace_id: ctx.workspace.id, task_id: task_ids, verdict: nil).where.not(reviewer_seat_id: nil)
        .order(:id).to_a.select { |review| Leases.due?(review, ctx.at) }
    end

    # The tasks of a workspace whose builder lease is due at the given
    # time, in a state the timer has a row for, oldest due first.
    def due_tasks(workspace_id, at, from_states, limit:)
      Task.where(workspace_id: workspace_id, state: from_states, lease_time_left_while_paused: nil)
        .where(lease_due_at: ..at).order(:lease_due_at, :id).limit(limit).to_a
    end

    # The open reviews of a workspace whose lease is due at the given time,
    # on a task in a state the timer has a row for, oldest due first.
    def due_reviews(workspace_id, at, from_states, limit:)
      Review.joins("JOIN tasks ON tasks.id = reviews.task_id")
        .where(workspace_id: workspace_id, verdict: nil, lease_time_left_while_paused: nil)
        .where.not(reviewer_seat_id: nil).where(lease_due_at: ..at).where(tasks: { state: from_states })
        .order(:lease_due_at, :id).limit(limit).to_a
    end

    # The time a timer's events carry: its due time, or the latest
    # effective time the task's events already have when that is later, so
    # effective times never go backwards within a task (L120) and no step
    # closes before it opened. In a real run the due time is always the
    # later one: a lease is granted by an event and every command on the
    # task applies its timer first. A test that puts a due time in the
    # past with Scenario#make_due (EN-18) can make it the earlier one.
    def effective_at(task, due_at)
      latest = Event.where(workspace_id: task.workspace_id, task_id: task.id).maximum(:effective_at)
      latest && latest > due_at ? latest : due_at
    end

    # --- the job timers (milestone 4 plan WP7; timers.json) ---

    # The job timer that reads this job now (its kind and state), or nil.
    def job_timer_for(job)
      JOB_TIMERS.find { |_timer, spec| spec.fetch(:kinds).include?(job.kind) && spec.fetch(:state) == job.state }&.first
    end

    # The job's due time for this timer (job_due_at), or nil.
    def job_timer_due_at(job, timer) = job_due_at(job, JOB_TIMERS.fetch(timer).fetch(:due))

    # Whether the timer is due on the job at at: the job is of the timer's
    # kind and in its state, and its due time has come.
    def job_timer_due?(job, timer, at)
      return false unless job_timer_for(job) == timer

      due = job_timer_due_at(job, timer)
      !due.nil? && due <= at
    end

    # Whether a job's miss is its second (L399, DB-31): a draft or question
    # job has its own attempt_number; a check's attempt is
    # the second try of a miss when the attempt before it was queued once
    # more (job.requeued on its job). An attempt the owner ran again, or
    # one run again after a withdrawal or an error, misses for the first
    # time (WP7's reading; trace 18, command 13).
    def check_job?(job) = CHECK_JOB_KINDS.include?(job.kind)

    def second_miss?(job)
      return job.attempt_number >= 2 unless check_job?(job)

      attempt = RuleCheckAttempt.find_by(job_id: job.id)
      previous = attempt && RuleCheckAttempt.find_by(rule_check_id: attempt.rule_check_id,
        attempt_number: attempt.attempt_number - 1)
      return false unless previous&.job_id

      Event.where(workspace_id: job.workspace_id, type: "job.requeued", subject_kind: "job", subject_id: previous.job_id)
        .exists?
    end

    # Runs the block with a TimerContext for timer at effective_at, inside
    # the command whose Context is ctx. Returns the block's value.
    def as_timer(ctx, timer, effective_at)
      yield TimerContext.new(ctx, timer, [ effective_at, ctx.at ].min)
    end

    # The jobs of scope the timer is due on at at, each with its due time
    # (timer_due_at), oldest due first.
    def job_timer_scope(scope, timer, at)
      spec = JOB_TIMERS.fetch(timer)
      kinds = spec.fetch(:kinds)
      due = JOB_DUE_SQL.fetch(kinds.first).fetch(spec.fetch(:due))
      scope = scope.joins("JOIN workspaces ON workspaces.id = jobs.workspace_id")
      scope = scope.joins(CHECK_JOINS) if CHECK_JOB_KINDS.include?(kinds.first)
      scope.where(kind: kinds, state: spec.fetch(:state)).where("#{due} <= ?", at)
        .select("jobs.*, #{due} AS timer_due_at").order(Arel.sql("timer_due_at, jobs.id"))
    end

    # The job timers due on one task at ctx.at that have not run in this
    # command, as [due, timer, job], oldest due first.
    def due_job_timers(ctx, task, applied)
      jobs = Job.where(workspace_id: ctx.workspace.id, task_id: task.id)
      return [] unless jobs.where(state: %w[queued claimed]).exists?

      JOB_TIMERS.keys.flat_map do |timer|
        job_timer_scope(jobs, timer, ctx.at).reject { |job| applied.include?(job.id) }.map { |job| [ job.timer_due_at, timer, job ] }
      end.sort_by { |time, _timer, job| [ time, job.id ] }
    end

    # What the sweep's run of a job timer takes: the workspace's jobs it is
    # due on, oldest due first, at most limit of them. A job whose task has
    # a lease due earlier is left until that lease has ended, as a command
    # would order them (apply_task_timers): the sweep runs the job timers
    # before the leases and again after them.
    def due_jobs(workspace_id, at, timer, limit:)
      job_timer_scope(Job.where(workspace_id: workspace_id), timer, at).to_a
        .reject { |job| behind_lease?(job, job.timer_due_at, at) }.first(limit)
    end

    # Whether the job's task has a builder or review lease due at at and
    # earlier than due.
    def behind_lease?(job, due, at)
      task = job.task_id && Task.find_by(id: job.task_id, workspace_id: job.workspace_id)
      return false unless task
      return true if Leases.due?(task, at) && task.lease_due_at < due

      Review.where(workspace_id: task.workspace_id, task_id: task.id, verdict: nil).where.not(reviewer_seat_id: nil)
        .any? { |review| Leases.due?(review, at) && review.lease_due_at < due }
    end

    # --- the credential hold release (milestone 3 plan §2.1 rules 7, 8) ---

    # The task's oldest open credential hold (credential_limit or
    # credential_signed_out), or nil.
    def credential_hold(task)
      Holds.open_holds(task).find { |hold| CREDENTIAL_REASONS.include?(hold.reason) }
    end

    # Rule 8 (HE-23): the due time of the task's credential hold, or nil
    # when it has none or none of its seat's candidates has a reset time.
    # It is read from the credentials as they are now, as of the task's last
    # effective time: the time the task has waited since. At once (that
    # time) when one of the seat's candidates that may take the task was
    # available then; otherwise the earliest reset among its signed-in
    # candidates, never before that time. A candidate whose reset has passed
    # since is not "available at once": the hold was due at its reset
    # (trace 11: due at 2400, swept at 2430). Nothing is stored, so a change
    # of credentials needs no write (timers.json).
    #
    # The seat is the one that holds the task: a credential hold is bound to
    # it and closes when it loses the task (SM-15).
    def credential_hold_due_at(task)
      return nil unless task.holder_seat_id && credential_hold(task)

      seat = Seat.find_by(id: task.holder_seat_id, workspace_id: task.workspace_id)
      last = Event.where(workspace_id: task.workspace_id, task_id: task.id).maximum(:effective_at)
      seat && last && Candidates.due_at(seat, task, last)
    end

    # Whether the task's credential hold is due at at.
    def credential_hold_due?(task, at)
      due = credential_hold_due_at(task)
      !due.nil? && due <= at
    end

    # The time the release's events carry: the due time, never before the
    # task's latest event (effective_at).
    def credential_hold_effective_at(task)
      due = credential_hold_due_at(task)
      due && effective_at(task, due)
    end

    # Whether a command applies the credential timer before the builder's
    # lease timer: its hold is due at at, and no later than a lease that is
    # also due. A lease due earlier ends first and its end closes the hold.
    def credential_hold_first?(task, at)
      due = credential_hold_due_at(task)
      return false unless due && due <= at

      !Leases.due?(task, at) || due <= task.lease_due_at
    end

    # The tasks of a workspace in from_states whose credential hold is due
    # at at, oldest due first, at most limit of them: what the sweep's run
    # of the credential timer takes. A task whose builder lease is due
    # earlier than its hold is left to the lease timer, which closes the
    # hold. Read in batches; the due time is computed for each.
    def due_credential_holds(workspace_id, at, from_states, limit:)
      held = Hold.where(workspace_id: workspace_id, closed_at: nil, reason: CREDENTIAL_REASONS).select(:task_id)
      due = []
      Task.where(workspace_id: workspace_id, state: from_states, id: held).find_each(batch_size: 100) do |task|
        due << [ credential_hold_due_at(task), task ] if credential_hold_first?(task, at)
      end
      due.sort_by { |time, task| [ time, task.id ] }.first(limit).map(&:last)
    end

    def target_ids(params)
      TARGET_PARAMS.filter_map { |name| params[name] }.select { |value| value.is_a?(String) && UUID.match?(value) }.uniq
    end
  end
end
