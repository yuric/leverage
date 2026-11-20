module Leverage
  module Transitions
    module Entries
      # claim_review (PRD Lifecycle L89, L506, L667, L690; milestone 2 plan
      # EN-7, EN-23; DB-20; milestone 3 plan HD-4, HE-5): a reviewer seat
      # claims the oldest open review it may take (Eligibility.next_review)
      # at review.assign. The seat becomes the review's reviewer and the
      # review lease runs one lease length; the task stays In review. The
      # review records the credential that does it: the seat's first
      # available candidate, on which its run is (HD-4). review.started
      # carries that credential and the model a run on it uses
      # (Candidates.model_for, HE-5; null when none is set).
      #
      # Refused not_eligible when the seat may not claim or no review is
      # left (RC-50).
      #
      # The hook is about the seat: its subject is the seat and the seat's
      # id is what it hashes (hooks.json). Claim-next skips a review the
      # provider rule keeps from the seat (Eligibility.review_and_skipped,
      # which reads the account the review would run on, milestone 4 plan
      # RD-50). For each review it skips before the one it takes, or before
      # it finds none, gating is asked at review.assign about this seat on
      # that review's task, and what it plans (the applied row with effect
      # refused, RC-15) is written by RuleChecks, check.finished with it:
      # the row's side event, which the waiting step takes as its cause
      # (RD-11). It is written in load, so a claim refused not_eligible
      # commits it too (RD-12, RE-7), and once per reviewer and round: a
      # review that already has a review.assign row for this seat in this
      # round is not asked about again.
      #
      # Result: ClaimReviewResult, with the reviewer's briefing.
      class ClaimReview < Entry
        HOOK = "review.assign".freeze

        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          # A review whose lease is past its due time has no reviewer
          # (EN-14): its timer runs first, so it is claimable now.
          Timers.apply_claimable(ctx, :review)
          @review, skipped = Eligibility.review_and_skipped(@seat, at: ctx.at)
          @task = @review && Task.find_by!(id: @review.task_id, workspace_id: ctx.workspace.id)
          skipped.each { |review| record_skip(ctx, review) }
        end

        def refusals(_ctx)
          return [ "not_eligible" ] unless @review

          [ state_refusal(@task.state) ].compact
        end

        def gate_request_fields(_ctx)
          { task_id: @task.id, project_id: @task.project_id, round: @task.round, subject_kind: "seat", subject_id: @seat.id,
            inputs: HookInputs.for(hook: HOOK, task: @task, params: {}, seat: @seat) }
        end

        def perform(ctx)
          credential = @seat.credential_id && Candidates.first_available(@seat, @review, ctx.at)
          model = Candidates.model_for(@seat, credential)
          @review.update!(reviewer_seat_id: @seat.id, credential_id: credential&.id)
          Leases.grant(ctx, @review)
          ctx.emit("review.started", task: @task, subject: @review, payload: { credential_id: credential&.id, model: model })
          @review.reload
          @result = {
            "review" => self.class.summary(@review),
            "lease" => { "seat_id" => @seat.id, "lease_due_at" => @review.lease_due_at.utc.iso8601(6) },
            "briefing" => Briefing.for(@task, seat: @seat, review: @review),
            "work_reference" => @task.work_reference,
            "credential_id" => credential&.id,
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

        private

        # Asks gating at review.assign about the seat on a review it skips,
        # and has the plan written, unless this seat already has a row there
        # in the review's round.
        def record_skip(ctx, review)
          task = Task.find_by!(id: review.task_id, workspace_id: ctx.workspace.id)
          return if RuleCheck.exists?(workspace_id: ctx.workspace.id, task_id: task.id, hook: HOOK, round: review.round,
            subject_kind: "seat", subject_id: @seat.id)

          kind, id = ctx.actor
          request = Gating::Request.new(workspace_id: ctx.workspace.id, task_id: task.id, project_id: task.project_id,
            hook: HOOK, round: review.round, subject_kind: "seat", subject_id: @seat.id, requester_kind: kind,
            requester_id: id, command_key: ctx.request.key, inputs: HookInputs.for(hook: HOOK, task: task, params: {}, seat: @seat))
          evaluation = Gating.evaluate(request)
          RuleChecks.write(ctx, evaluation, task: task) unless evaluation.checks.empty?
        end
      end
    end
  end
end
