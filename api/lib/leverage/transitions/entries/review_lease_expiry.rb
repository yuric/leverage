module Leverage
  module Transitions
    module Entries
      # The review_lease_expiry timer (PRD L90, L120-L121; timers.json;
      # state_machine.json): a reviewer's lease that has reached its due
      # time ends. The task stays In review and the review is unassigned,
      # so another reviewer can claim it; review.lease_expired is written
      # by the app, with no command_id, at the due time.
      #
      # It runs in two ways, through the same code (L118): inside another
      # command, where Timers.apply_due makes it with targets:, one review
      # of a task that command touches; or as the sweep's own command,
      # where params review_id names one review, or with none it takes the
      # workspace's due reviews, oldest due first, at most params limit
      # (default BATCH).
      #
      # Result: expired_review_ids, the reviews whose lease it ended.
      #
      # Milestone 4 (plan §2.1 rule 11): a pending pass under the review
      # whose lease ends is cancelled first with lease_expired, through
      # PendingTransitions.cancel, so that its checks and jobs are withdrawn
      # before review.lease_expired is written.
      #
      # The row's side events ("No reviewer is eligible") arrive with rules
      # in milestone 4 (SC-11).
      class ReviewLeaseExpiry < Entry
        BATCH = 100

        def initialize(command = self.class.command, targets: nil)
          super(command)
          @reviews = targets
          @named = !targets.nil?
        end

        def load(ctx)
          if @reviews.nil?
            params = ctx.request.params
            if params.key?("review_id")
              @named = true
              @reviews = [ Review.find_by(id: params["review_id"], workspace_id: ctx.workspace.id) ||
                             raise(NotFound, "no such review") ]
            else
              limit = Integer(params.fetch("limit", BATCH))
              @reviews = Timers.due_reviews(ctx.workspace.id, ctx.at, from_states, limit: limit)
            end
          end
          @tasks = Task.where(id: @reviews.map(&:task_id)).index_by(&:id)
        end

        # A named review's task must be in a state the timer has a row for.
        def refusals(_ctx)
          return [] unless @named

          [ state_refusal(@tasks.fetch(@reviews.sole.task_id).state) ].compact
        end

        def perform(ctx)
          expired = @reviews.select { |review| review.verdict.nil? && review.reviewer_seat_id && Leases.due?(review, ctx.at) }
          expired.each { |review| expire(ctx, review, @tasks.fetch(review.task_id)) }
          @result = { "expired_review_ids" => expired.map(&:id) }
        end

        private

        def expire(ctx, review, task)
          effective_at = Timers.effective_at(task, review.lease_due_at)
          pending = PendingTransitions.of(task)
          # The withdrawals are the timer's: the app's, with no key, at the
          # lease's due time (trace 18, command 45; WP5b's request 1).
          if pending
            PendingTransitions.cancel(ctx, pending, "lease_expired", effective_at: effective_at, actor_kind: "app",
              actor_id: nil, command_id: nil)
          end
          Leases.end_lease(ctx, review)
          review.update!(reviewer_seat_id: nil)
          ctx.emit("review.lease_expired", task: task, subject: review, payload: {}, actor_kind: "app", actor_id: nil,
            command_id: nil, effective_at: effective_at)
        end

        def from_states = rows.map { |row| row.fetch("from") }
      end
    end
  end
end
