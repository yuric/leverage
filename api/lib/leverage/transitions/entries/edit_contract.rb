module Leverage
  module Transitions
    module Entries
      # edit_contract (PRD Lifecycle L81, L82, Contract edits L205; milestone
      # 3 plan HE-25, HE-29; SC-3). The criteria keep their identity by
      # position and kind (ContractDiff): an unchanged criterion keeps its
      # state and evidence, one whose text changed is reset to open. The
      # contract version goes up by one, and the round is kept (HE-25 (ii)).
      #
      # In the Backlog: task.contract_changed alone. From Ready, Working and
      # In review (HE-25 (iv)): the builder's lease and any review lease end
      # with no event of their own, the task has no holder and no builder
      # and an open review no reviewer, so both seats are free at once and
      # the builder's next call is not_holder (HE-25 (vi));
      # task.contract_changed then task.returned are written and the task is
      # in the Backlog. Then the holds a contract edit answers close, oldest
      # first (the row's holds_closed: contract_incomplete in the Backlog,
      # rounds_exceeded, claim_gate_failed, rerun_limit), each item resolved
      # with the choice edit_contract where the item offers it (HE-29); then
      # the seat-bound holds, through Holds.close_seat_bound, caused by
      # task.returned. An owner_hold stays open: only Resume closes it
      # (L176).
      #
      # A pending transition, in any state, is cancelled first, with
      # invalid_state (L377; milestone 4 plan §2.1 rule 11): its checks and
      # jobs are withdrawn, and the check_error or rerun_limit hold one of
      # them opened is closed, by PendingTransitions.cancel, before the
      # holds this edit answers are read. A check_error hold closes only
      # with the check it is about, which is why the edit does not close it
      # itself. Costs applies any change to the task's budget cap (AE-12).
      #
      # Ideas, Finishing, Done and Cancelled have no row: invalid_state
      # (HE-25 (v)). As in Complete contract, criteria must end with the one
      # review, and work references cannot carry sign-in details (L533).
      #
      # Params: id, and the CompleteContractRequest body.
      class EditContract < Entry
        CHOICE = "edit_contract".freeze

        # The holds a task loses with its seat (plan SM-15), closed by
        # Holds.close_seat_bound; and check_error, which closes only with
        # the check the edit withdraws (PendingTransitions.cancel).
        SEAT_BOUND = %w[seat_paused credential_limit credential_signed_out].freeze
        WITH_A_CHECK = %w[check_error].freeze

        def load(ctx)
          @params = ctx.request.params
          @task = Task.find_by(id: @params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")

          kinds = Array(@params["criteria"]).map { |criterion| criterion["kind"] }
          unless kinds.last == "review" && kinds.count("review") == 1
            raise Invalid, "The last criterion, and only the last, is the independent review."
          end

          problem = LinkRules.work_reference_problem(@params["work_reference"])
          raise Invalid, problem if problem
        end

        def refusals(_ctx) = [ state_refusal(@task.state) ].compact

        def perform(ctx)
          pending = PendingTransitions.of(@task)
          PendingTransitions.cancel(ctx, pending, "invalid_state") if pending
          active = @task.state != "backlog"
          answered = answered_holds
          free_seats(ctx) if active
          written = ContractDiff.write(@task, Array(@params["criteria"]), at: ctx.at)
          actions = Actions.create_for(@task, Array(@params["actions"]))
          @task.update!(title: @params.fetch("title", @task.title),
            details: @params["details"], work_reference: @params["work_reference"].presence,
            minimum_strength_rank: @params["minimum_strength_rank"], budget_cap: @params["budget_cap"],
            contract_version: @task.contract_version + 1, state: "backlog")
          ctx.emit("task.contract_changed", task: @task,
            payload: { contract_version: @task.contract_version, minimum_strength_rank: @task.minimum_strength_rank,
                       added_criterion_ids: written.added_ids, reset_criterion_ids: written.reset_ids,
                       removed_criterion_ids: written.removed_ids, added_action_ids: actions.added_ids,
                       removed_action_ids: actions.removed_ids })
          returned = ctx.emit("task.returned", task: @task, payload: {}) if active
          answered.each { |hold| Holds.close(ctx, hold: hold, task: @task, choice: choice_for(hold)) }
          Holds.close_seat_bound(ctx, @task, cause: returned, wait_cause: nil) if active
          Costs.cap_changed(ctx, @task)
          @result = nil
        end

        private

        # The open holds this edit answers, oldest first: the row's
        # holds_closed apart from seat-bound holds, check_error and budget.
        def answered_holds
          reasons = @row.fetch("holds_closed") - SEAT_BOUND - WITH_A_CHECK - [ "budget" ]
          Holds.open_holds(@task).select { |hold| reasons.include?(hold.reason) }
        end

        # The builder's lease and any review lease end, with no event of
        # their own; the task has no holder or builder, an open review no
        # reviewer (PRD L782: task.returned clears them).
        def free_seats(ctx)
          Leases.end_lease(ctx, @task)
          Review.where(workspace_id: @task.workspace_id, task_id: @task.id, verdict: nil).find_each do |review|
            Leases.end_lease(ctx, review)
            review.update!(reviewer_seat_id: nil)
          end
          @task.update!(holder_seat_id: nil, builder_seat_id: nil, resume_pending_since: nil)
        end

        # edit_contract when the hold's item offers it, else nil (HE-29).
        def choice_for(hold)
          item = Holds.needs_you_item(hold.reason)
          item && item.fetch("choices").any? { |choice| choice.fetch("choice") == CHOICE } ? CHOICE : nil
        end
      end
    end
  end
end
