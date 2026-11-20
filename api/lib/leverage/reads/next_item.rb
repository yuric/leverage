module Leverage
  module Reads
    # What GET /v1/next tells a seat (PRD L514-L529; IF-7, IF-34; milestone 2
    # plan WP8): the first true row of the precedence table, as the
    # contract's NextItem, `{ "kind", "id", "review_id" }`. Nothing is
    # consumed and nothing is written: the same item repeats until the seat
    # acts.
    #
    # Milestone 4 serves eight kinds, in the table's order: command,
    # briefing_changed, resume, rework, review, job, task and none. `answer`
    # and `action` need a question or an outward action, milestone 5's, so
    # no branch asks for them.
    #
    #   command           a command this seat sent waited on a check and is
    #                     no longer pending, or a check that refused it was
    #                     overridden: its commands row is marked notify with
    #                     an outcome the seat has not read (RE-3, DB-34;
    #                     L381, L382). id is the command's key, the oldest
    #                     such row's first. Told whatever else is true, a
    #                     hold on the seat's task included: it is the first
    #                     row of the table.
    #   briefing_changed  the seat holds a task or a review, acknowledged its
    #                     briefing under this lease, and the briefing's hash
    #                     is not the one it acknowledged. id is the task;
    #                     review_id the review, when the seat holds one.
    #   resume            a hold on the seat's task has closed
    #                     (tasks.resume_pending_since, DB-35).
    #   rework            a failed review gave the seat a fresh lease on its
    #                     task (review.failed names it in lease_seat_id) and
    #                     it has not acknowledged the briefing under it.
    #   review, task      Eligibility has a review or a task for a seat that
    #                     holds none (EN-23): the review claim-next would
    #                     take, so never one the claim filter leaves out for
    #                     the seat (L526, milestone 4 plan RD-12).
    #   job               Jobs has a job for an orchestrator or a planner
    #                     (L527): the one claim-next would give it.
    #   none              nothing above is true.
    #
    # While a hold is open on the seat's task the answer is none (EN-13),
    # unless a command outcome waits; a lease past its due time counts as
    # ended, with nothing written (EN-14).
    #
    # What a seat may claim is Eligibility's and Jobs', and what the
    # briefing's hash is, Briefing's (milestone 2 plan WP3). This read asks
    # them through
    #
    #   eligibility.next_task(seat)    a Task, or nil
    #   eligibility.next_review(seat)  a Review, or nil
    #   jobs.next_for(seat)            a Job, or nil
    #   briefing.hash_for(subject, seat)  the hash of the briefing the seat
    #                                  would read now (subject: Task or Review)
    #
    # and with_collaborators puts doubles in place for a test.
    module NextItem
      NONE = { "kind" => "none", "id" => nil, "review_id" => nil }.freeze

      # A lease that has not passed its due time, or is paused (no due time).
      LIVE = "lease_due_at IS NULL OR lease_due_at > clock_timestamp()".freeze

      @collaborators = {}

      class << self
        # The item for the seat, a Hash with string keys.
        def call(seat)
          command = command_item(seat)
          return command if command

          task = held_task(seat)
          review = held_review(seat)
          item = (task && task_item(seat, task)) || (review && review_item(seat, review))
          return item if item
          return NONE.dup if task || review

          waiting(seat) || NONE.dup
        end

        # Tests only: answers eligibility and briefing from these objects
        # inside the block.
        def with_collaborators(eligibility: nil, briefing: nil, jobs: nil)
          saved = @collaborators
          @collaborators = saved.merge({ eligibility: eligibility, briefing: briefing, jobs: jobs }.compact)
          yield
        ensure
          @collaborators = saved
        end

        private

        def eligibility = @collaborators[:eligibility] || Leverage::Eligibility
        def briefing = @collaborators[:briefing] || Leverage::Briefing
        def jobs = @collaborators[:jobs] || Leverage::Jobs

        def item(kind, id = nil, review_id = nil) = { "kind" => kind, "id" => id, "review_id" => review_id }

        # The oldest outcome of the seat's that it has not read since its
        # transition ended (DB-34): the writer marks the row notify when the
        # outcome changes, and reading it sets read_at.
        def command_item(seat)
          key = Command.where(workspace_id: seat.workspace_id, caller_kind: "seat", caller_id: seat.id, notify: true,
            read_at: nil).where.not(outcome: "pending").order(:updated_at, :created_at, :id).pick(:key)
          key && item("command", key)
        end

        def held_task(seat)
          Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id, state: "working").where(LIVE).take
        end

        def held_review(seat)
          Review.where(workspace_id: seat.workspace_id, reviewer_seat_id: seat.id, verdict: nil).where(LIVE).take
        end

        def task_item(seat, task)
          return nil if Hold.where(task_id: task.id, closed_at: nil).exists?

          lease = builder_lease_event(task, seat)
          acknowledged = acknowledgement(seat, task, nil, lease)
          if acknowledged && acknowledged.briefing_hash != briefing.hash_for(task, seat)
            item("briefing_changed", task.id)
          elsif task.resume_pending_since
            item("resume", task.id)
          elsif lease&.type == "review.failed" && acknowledged.nil?
            item("rework", task.id)
          end
        end

        def review_item(seat, review)
          lease = Event.where(task_id: review.task_id, subject_kind: "review", subject_id: review.id, type: "review.started")
            .order(seq: :desc).take
          acknowledged = acknowledgement(seat, nil, review, lease)
          return nil unless acknowledged && acknowledged.briefing_hash != briefing.hash_for(review, seat)

          item("briefing_changed", review.task_id, review.id)
        end

        # The event that gave the seat its lease on the task: task.claimed
        # names it in seat_id, every event that grants a fresh lease in
        # lease_seat_id (the Leases module's reading of builder_lease).
        def builder_lease_event(task, seat)
          Event.where(workspace_id: task.workspace_id, task_id: task.id)
            .where("(type = 'task.claimed' AND payload->>'seat_id' = :seat) OR payload->>'lease_seat_id' = :seat",
              seat: seat.id)
            .order(seq: :desc).take
        end

        # The seat's latest acknowledgement under the lease, or nil.
        def acknowledgement(seat, task, review, lease)
          return nil unless lease

          BriefingAcknowledgement.where(seat_id: seat.id, task_id: task&.id || review.task_id, review_id: review&.id,
            lease_event_id: lease.id).order(acknowledged_at: :desc).take
        end

        # Whether Eligibility has a review (a reviewer) or a task (a
        # builder), or Jobs a job (an orchestrator or a planner), waiting
        # for a seat that holds nothing. The claims ask them the same, so
        # this never offers what a claim refuses: for a seat the app runs,
        # only work its run is placed for (milestone 3 plan HD-4).
        def waiting(seat)
          case seat.role
          when "builder" then item("task") if eligibility.next_task(seat)
          when "reviewer" then item("review") if eligibility.next_review(seat)
          when "orchestrator", "planner" then item("job") if jobs.next_for(seat)
          end
        end
      end
    end
  end
end
