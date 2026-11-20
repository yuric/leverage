module Leverage
  module Reads
    # A task's steps in order with their durations (PRD L269 to L306, L322,
    # L898; milestone 4 plan §2.3, RD-28): what the task page's Timing
    # section shows, each step a row of task_steps, the open one measured
    # to as_of.
    #
    # The steps touch end to end (L271, L276), so their seconds add up to
    # the task's lifetime: from the opening of its first step (its creation,
    # rule 1) to the end of its last, or as_of while one is open. The
    # lifetime is that sum, worked out in exact microseconds before it
    # becomes a number (the times are microseconds), so it equals the steps'
    # sum and not a float's rounding of it. An idea's time is a step like
    # any other (kind idea); the app lists it apart (L281, RD-28).
    #
    # It runs no transaction of its own: the task page calls it inside its
    # Snapshot, with that snapshot's database time.
    module TaskTimeline
      ORDER = Arel.sql("opened_at, closed_at NULLS LAST, created_at, id")

      module_function

      # The steps as TaskStep (openapi.json) with symbol keys.
      #
      # as_of: - the time the open step is measured to; nil is the
      #          database's clock.
      def call(workspace_id, task_id, as_of: nil)
        as_of ||= database_now
        TaskStep.where(workspace_id: workspace_id, task_id: task_id).order(ORDER).map { |step| shape(step, as_of) }
      end

      # The task's lifetime in seconds: the sum of its steps' seconds.
      def lifetime_seconds(steps)
        (steps.sum { |step| (step.fetch(:seconds) * 1_000_000).round } / 1_000_000r).to_f
      end

      def shape(step, as_of)
        { kind: step.kind, step_class: step.step_class, round: step.round, opened_at: Shapes.time(step.opened_at),
          closed_at: Shapes.time(step.closed_at), seconds: seconds(step.opened_at, step.closed_at || as_of),
          subject_kind: step.subject_kind, subject_id: step.subject_id, seat_id: step.seat_id,
          cause_kind: step.cause_kind, cause_rule_id: step.cause_rule_id }
      end

      # The database's clock now, read past the query cache: a cached
      # reading from earlier in the request could be older than a step this
      # read sees open.
      def database_now
        ActiveRecord::Base.uncached { ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()") }
      end

      # The seconds from one time to another, to the microsecond, never
      # less than zero (an as_of given before a step opened).
      def seconds(from, to)
        [ to.to_r - from.to_r, 0 ].max.round(6).to_f
      end
    end
  end
end
