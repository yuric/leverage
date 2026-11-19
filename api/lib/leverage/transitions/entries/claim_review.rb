module Leverage
  module Transitions
    module Entries
      # claim_review (PRD Lifecycle L89, L506; milestone 2 plan EN-7, EN-23;
      # DB-20): a reviewer seat claims the oldest open review it may take
      # (Eligibility.next_review) at review.assign. The seat becomes the
      # review's reviewer, the review records the seat's credential, and the
      # review lease runs one lease length; the task stays In review.
      # review.started carries the credential and the model (null when the
      # seat's is empty).
      #
      # Refused not_eligible when the seat may not claim or no review is
      # left (RC-50).
      #
      # Result: ClaimReviewResult, with the reviewer's briefing.
      class ClaimReview < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          # A review whose lease is past its due time has no reviewer
          # (EN-14): its timer runs first, so it is claimable now.
          Timers.apply_claimable(ctx, :review)
          @review = Eligibility.next_review(@seat)
          @task = @review && Task.find_by!(id: @review.task_id, workspace_id: ctx.workspace.id)
        end

        def refusals(_ctx)
          return [ "not_eligible" ] unless @review

          [ state_refusal(@task.state) ].compact
        end

        def gate_request_fields(_ctx)
          super.merge(task_id: @task.id, project_id: @task.project_id, round: @task.round, subject_kind: "review",
            subject_id: @review.id)
        end

        def perform(ctx)
          @review.update!(reviewer_seat_id: @seat.id, credential_id: @seat.credential_id)
          Leases.grant(ctx, @review)
          model = @seat.model.presence
          ctx.emit("review.started", task: @task, subject: @review,
            payload: { credential_id: @seat.credential_id, model: model })
          @review.reload
          @result = {
            "review" => self.class.summary(@review),
            "lease" => { "seat_id" => @seat.id, "lease_due_at" => @review.lease_due_at.utc.iso8601(6) },
            "briefing" => Briefing.for(@task, seat: @seat, review: @review),
            "work_reference" => @task.work_reference,
            "credential_id" => @seat.credential_id,
            "model" => model
          }
        end

        # A review row in the contract's Review shape.
        def self.summary(review)
          {
            "id" => review.id, "task_id" => review.task_id, "round" => review.round,
            "reviewer_seat_id" => review.reviewer_seat_id, "lease_due_at" => review.lease_due_at&.utc&.iso8601(6),
            "verdict" => review.verdict, "failed_criteria" => Array(review.failed_criteria), "notes" => review.notes
          }
        end
      end
    end
  end
end
