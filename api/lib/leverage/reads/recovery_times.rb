module Leverage
  module Reads
    # Recovery times (PRD L65, L319, L703, test 11; milestone 3 plan HE-17,
    # HE-18): the intervals between an interruption and the event that ends
    # it, of one task or of the whole workspace, computed from events only.
    # Each is a RecoveryTime of openapi.json.
    #
    # A start is a credential.limit_reached, or a credential.signed_out
    # whose payload names a seat (a sign-out found by Verify starts
    # nothing), on a task. Its work is the review its payload names, or else
    # the task's build work. Each start is paired on its own, so two starts
    # may share one end:
    #
    #   handoff        the command that wrote the start (same command_id and
    #                  at) also wrote a credential.switched for the same work:
    #                  another credential took over at once, and the
    #                  interval ends there, 0 seconds.
    #   seat_event     otherwise the first later event of that task, written
    #                  by a seat, of a type that belongs to the work (BUILD,
    #                  REVIEW). A credential.switched the app writes later
    #                  (a hold closes, a login is verified) ends nothing: no
    #                  run exists yet then (HE-21). A heartbeat and a read
    #                  write no event, so neither can end it.
    #   not_recovered  the task was done or cancelled before any end: no
    #                  length.
    #   nil            still open: measured to now (L322).
    #
    # seconds is the interval between the two events' effective_at, rounded
    # up to a whole second, so a bar is never passed by rounding down.
    module RecoveryTimes
      STARTS = { "credential.limit_reached" => "limit", "credential.signed_out" => "signed_out" }.freeze
      SWITCHED = "credential.switched".freeze
      # A seat's events that continue a task's build work.
      BUILD = %w[task.claimed task.briefing_acknowledged criterion.started criterion.passed task.submitted
                 task.released].freeze
      # A seat's events that continue a review, each about that review.
      REVIEW = %w[review.started task.briefing_acknowledged review.passed review.failed review.released].freeze
      ENDED = %w[task.done task.cancelled].freeze

      module_function

      # workspace_id - the workspace.
      # task_id:     - one task's intervals, or nil for every task's.
      # now:         - the time an open interval is measured to; nil is
      #                the database's clock.
      #
      # Returns an Array of Hashes with string keys, in the order of the
      # starts.
      def call(workspace_id, task_id: nil, now: nil)
        scope = Event.where(workspace_id: workspace_id).where.not(task_id: nil)
        scope = scope.where(task_id: task_id) if task_id
        task_ids = scope.where(type: STARTS.keys).distinct.pluck(:task_id)
        return [] if task_ids.empty?

        now ||= Event.connection.select_value("SELECT clock_timestamp()")
        Event.where(workspace_id: workspace_id, task_id: task_ids).order(:seq).to_a.group_by(&:task_id)
          .flat_map { |_task, events| of_task(events, now) }
          .sort_by { |item, seq| [ item.fetch("started_at"), seq ] }
          .map(&:first)
      end

      # [item, seq of its start] for each start among one task's events.
      def of_task(events, now)
        events.each_with_index.filter_map do |event, index|
          next unless start?(event)

          [ interval(event, events.drop(index + 1), now), event.seq ]
        end
      end

      def start?(event)
        kind = STARTS[event.type]
        kind == "limit" || (kind == "signed_out" && (event.payload || {})["seat_id"].present?)
      end

      def interval(start, later, now)
        review_id = (start.payload || {})["review_id"]
        item = { "kind" => STARTS.fetch(start.type), "credential_id" => start.subject_id, "review_id" => review_id,
                 "started_at" => time(start.effective_at), "ended_at" => nil, "seconds" => nil, "ended_by" => nil }
        handoff = later.find { |event| handoff?(start, event, review_id) }
        return close(item, start, handoff, "handoff") if handoff

        later.each do |event|
          return close(item, start, event, "seat_event") if continues?(event, review_id)
          return item.merge("ended_by" => "not_recovered") if ENDED.include?(event.type)
        end
        item.merge("seconds" => seconds(start.effective_at, now))
      end

      # The credential.switched the start's own command wrote for its work.
      def handoff?(start, event, review_id)
        event.type == SWITCHED && start.command_id && event.command_id == start.command_id && event.at == start.at &&
          (event.payload || {})["review_id"] == review_id
      end

      # A seat's event of the start's work.
      def continues?(event, review_id)
        return false unless event.actor_kind == "seat"

        if review_id
          REVIEW.include?(event.type) && event.subject_kind == "review" && event.subject_id == review_id
        else
          BUILD.include?(event.type) && !(event.type == "task.briefing_acknowledged" && event.subject_kind == "review")
        end
      end

      def close(item, start, ending, by)
        item.merge("ended_at" => time(ending.effective_at), "seconds" => seconds(start.effective_at, ending.effective_at),
          "ended_by" => by)
      end

      def seconds(from, to) = [ (to.to_r - from.to_r).ceil, 0 ].max

      def time(value) = value.utc.iso8601(6)
    end
  end
end
