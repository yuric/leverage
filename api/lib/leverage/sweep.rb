module Leverage
  # The sweep (PRD L118, L404, L822; timers.json trigger; milestone 2 plan
  # EN-22; milestone 3 plan HD-4, HE-23): a second program from the API's image, bin/sweep, that applies
  # the due task timers to tasks no command has touched and fires the
  # workspace timers, through the same entries a command applies first. It
  # is not a timer and writes no event of its own: each workspace's run
  # leaves one sweep_runs row, the proof it is alive (L404), written under
  # the workspace lock like every other write.
  #
  # Milestone 4 (its plan WP7): the sweep also applies the job timers
  # (Timers::JOB_TIMERS) to jobs no command has touched, and fires
  # orchestrator_offline and reviewer_eligibility on every run through
  # Timers.apply_workspace, at the run's own time.
  #
  # A pass goes through every workspace. In each, every timer runs as its
  # own command through Transitions.apply, by the app, in bounded batches:
  # one batch is one transaction under the workspace lock, so a command
  # never waits long behind the sweep. bin/sweep loops, a pass every
  # INTERVAL seconds; bin/sweep --once makes one pass and exits.
  module Sweep
    # PRD L822 says at least every 30 seconds; EN-22 runs it every 15.
    INTERVAL = 15
    # command_key_retention purges in a scan of the workspace's commands,
    # so the loop runs it once an hour, and a single pass always.
    PURGE_EVERY = 3600
    BATCH = 100
    LOG = "leverage.sweep".freeze
    # The workspace timers of milestone 4, fired after seat_run_placement:
    # orchestrator_offline then sees the checks this run's timers erred.
    WORKSPACE_TIMERS = %w[orchestrator_offline reviewer_eligibility].freeze

    module_function

    # One pass over every workspace. Returns how many it swept.
    def pass(purge: true, batch: BATCH)
      count = 0
      Workspace.in_batches(of: BATCH) do |workspaces|
        workspaces.pluck(:id).each do |workspace_id|
          sweep_workspace(workspace_id, purge: purge, batch: batch)
          count += 1
        end
      end
      count
    end

    # Applies the due task timers of one workspace, batch by batch: the
    # credential hold release first (a hold due before its task's lease;
    # milestone 3 plan rule 8, HE-23); the job timers due before any lease
    # of their task; the two leases, whose end closes a credential hold due
    # later; then the job timers the leases left (Timers.due_jobs). Then it
    # fires seat_run_placement, which runs on every sweep (HD-4), and the two
    # workspace timers of milestone 4, purges the old command keys when
    # purge is true, and records the run. Returns the SweepRun.
    def sweep_workspace(workspace_id, purge: false, batch: BATCH)
      touched = []
      touched += repeat(workspace_id, Timers::CREDENTIAL_HOLD, "released_task_ids", batch)
      touched += job_timers(workspace_id, batch)
      touched += repeat(workspace_id, Timers::BUILDER_LEASE, "expired_task_ids", batch)
      expired_reviews = repeat(workspace_id, Timers::REVIEW_LEASE, "expired_review_ids", batch)
      touched += Review.where(id: expired_reviews).pluck(:task_id) unless expired_reviews.empty?
      touched += job_timers(workspace_id, batch)
      timer(workspace_id, Timers::SEAT_RUN_PLACEMENT)
      fired = 1
      WORKSPACE_TIMERS.each do |name|
        Timers.apply_workspace(workspace_id, name, at: database_now)
        fired += 1
      end
      if purge
        loop { break unless timer(workspace_id, "command_key_retention", "limit" => batch * 10).result.fetch("more") }
        fired += 1
      end
      record(workspace_id, tasks_touched: touched.uniq.size, workspace_timers_fired: fired)
    end

    # Writes the run's sweep_runs row. Like every write (PRD L217), in a
    # transaction whose first statement takes the workspace lock; ran_at is
    # the lock's clock reading.
    def record(workspace_id, **counts)
      ActiveRecord::Base.transaction(requires_new: true) do
        _workspace, at = WorkspaceLock.take(workspace_id)
        SweepRun.create!(workspace_id: workspace_id, ran_at: at, **counts)
      end
    end

    # Runs the sweep until stop answers true: a pass every interval
    # seconds, purging on the first pass and then once every purge_every
    # seconds. A pass that fails is logged and the next one runs on time.
    # The clock, the sleeper, stop and the sweeper are parameters, so the
    # loop is tested without waiting.
    def run(interval: INTERVAL, purge_every: PURGE_EVERY, clock: -> { monotonic }, sleeper: nil, stop: -> { false },
            sweeper: self)
      sleeper ||= ->(seconds) { pause(seconds, stop) }
      next_purge = clock.call
      until stop.call
        started = clock.call
        purge = started >= next_purge
        next_purge = started + purge_every if purge
        begin
          sweeper.pass(purge: purge)
        rescue StandardError => error
          Rails.logger.error("#{LOG} failed=#{error.class} message=#{error.message.inspect}")
        end
        sleeper.call(interval) unless stop.call
      end
    end

    # Runs one timer as the app's own command and returns its Outcome.
    def timer(workspace_id, command, params = {})
      Transitions.apply(Transitions::Request.new(command: command, workspace_id: workspace_id, caller_kind: nil,
        caller_id: nil, key: nil, request_hash: nil, params: params))
    end

    # Runs each job timer until a batch comes back short; returns the tasks
    # of the jobs they timed out.
    def job_timers(workspace_id, batch)
      jobs = Timers::JOB_TIMERS.keys.flat_map { |command| repeat(workspace_id, command, "timed_out_job_ids", batch) }
      jobs.empty? ? [] : Job.where(id: jobs).where.not(task_id: nil).pluck(:task_id)
    end

    # Runs a task timer until a batch comes back short; returns the ids its
    # result lists in field. No lock is taken when nothing is due.
    def repeat(workspace_id, command, field, batch)
      ids = []
      while due?(workspace_id, command)
        done = Array((timer(workspace_id, command, "limit" => batch).result || {})[field])
        ids.concat(done)
        break if done.size < batch
      end
      ids
    end

    # Whether the timer has anything due now, read without the lock; the
    # timer reads it again under the lock.
    def due?(workspace_id, command)
      at = database_now
      states = Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
        .select { |row| row.fetch("command") == command }.map { |row| row.fetch("from") }
      case command
      when Timers::BUILDER_LEASE then Timers.due_tasks(workspace_id, at, states, limit: 1).any?
      when Timers::CREDENTIAL_HOLD then Timers.due_credential_holds(workspace_id, at, states, limit: 1).any?
      when *Timers::JOB_TIMERS.keys then Timers.due_jobs(workspace_id, at, command, limit: 1).any?
      else Timers.due_reviews(workspace_id, at, states, limit: 1).any?
      end
    end

    def database_now
      ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Sleeps up to seconds, waking early once stop answers true.
    def pause(seconds, stop)
      deadline = monotonic + seconds
      sleep([ 0.25, deadline - monotonic ].min) while !stop.call && monotonic < deadline
    end
  end
end
