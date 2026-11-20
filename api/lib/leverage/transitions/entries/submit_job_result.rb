module Leverage
  module Transitions
    module Entries
      # submit_job_result (PRD L399, L428, L512, L514, L539; milestone 4 plan
      # RE-3, RE-6, RE-8, RD-37, RD-41; traces 16 and 19): the job's seat
      # sends its result, with the tokens and spend it used.
      #
      # Accepted, in this order (trace 16 commands 4 and 11; WP0T's choice
      # 4): job.finished (Jobs.finish, the result on the row); for a rule
      # check, its result (RuleChecks.finish: check.finished); cost.reported
      # about the job, whose spend adds to the task's project and never to
      # the task (RE-8); then, for a rule check that a transition waits on,
      # that transition is gated again (PendingTransitions.reenter, with the
      # trigger check_finished). A contract draft's result is the Complete
      # contract command, run as the planner with this call's key
      # (Transitions.run_as, RE-6), from the result's title, goal, details,
      # criteria and actions and the task's stored work reference, minimum
      # strength rank and budget cap, whatever the result says of those
      # three (RD-37, L539). When that Complete contract waits on a model
      # check, this call is the one waiting: pending? answers true.
      #
      # Refused, and nothing is written (RD-41), in precedence order:
      # task_cancelled for the job of a task cancelled while the seat held
      # the job; not_holder from a seat that did not claim the job;
      # forbidden from a seat of a role that does not claim its kind;
      # invalid_state for a job that is not claimed (timed out, withdrawn or
      # finished), whose run time has passed (L399: a result after its
      # timeout is discarded), or a draft whose task has left Backlog.
      #
      # 422 invalid: a result that is not of the job's kind's shape, or
      # not_applicable from a rule that is not "let the checker decide"
      # (RC-33). 404: a job outside the caller's workspace.
      #
      # Params: "id" (the job, from the path) and the JobResultRequest body:
      # result, tokens, spend.
      class SubmitJobResult < Entry
        # The results a checker may give (RuleCheckJobResult).
        CHECK_RESULTS = %w[passed failed not_applicable].freeze

        def load(ctx)
          params = ctx.request.params
          @job = Job.find_by(id: params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such job")
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = @job.task_id && Task.find_by(id: @job.task_id, workspace_id: ctx.workspace.id)
          @result = nil
          @tokens = params["tokens"]
          @spend = params["spend"]
          @answer = params["result"].to_h.stringify_keys
          check_shape
        end

        def refusals(ctx)
          codes = []
          held = @job.claimed_by_seat_id == @seat.id
          codes << "task_cancelled" if held && @task&.state == "cancelled"
          codes << "not_holder" unless held
          codes << "forbidden" unless @seat.role == @job.seat_role
          codes << Refusal.new(code: "invalid_state") unless @job.state == "claimed" && !Jobs.due?(@job, :run, ctx.at)
          codes << Refusal.new(code: "invalid_state") if @job.kind == "contract_draft" && @task&.state != "backlog"
          codes << state_refusal(nil)
          codes.compact
        end

        def perform(ctx)
          Jobs.finish(ctx, @job, result: @answer, tokens: @tokens, spend: @spend)
          @job.kind == "rule_check" ? perform_check(ctx) : perform_draft(ctx)
        end

        # Whether the command waits: a planner's Complete contract met a
        # model-checked gate (RE-6), so this call answers 202 pending.
        def pending? = @outcome == :pending

        private

        def perform_check(ctx)
          check = RuleCheck.find_by!(id: @job.target_id, workspace_id: @job.workspace_id)
          RuleChecks.finish(ctx, check, result: @answer.fetch("result"), reason: @answer.fetch("reason"), tokens: @tokens,
            spend: @spend)
          report_cost(ctx)
          pending = check.pending_transition_id &&
            PendingTransition.find_by(id: check.pending_transition_id, workspace_id: @job.workspace_id, state: "pending")
          return unless pending

          PendingTransitions.reenter(ctx, pending, Gating::Trigger.new(kind: :check_finished, rule_check_id: check.id))
        end

        def perform_draft(ctx)
          report_cost(ctx)
          contract = @answer.slice("title", "goal", "details", "criteria", "actions")
          stored = { "work_reference" => @task.work_reference, "minimum_strength_rank" => @task.minimum_strength_rank,
                     "budget_cap" => @task.budget_cap&.to_f }
          @outcome = Transitions.run_as(ctx, "complete_contract", requester: @seat, key: ctx.request.key,
            params: contract.merge(stored).merge("id" => @task.id))
        end

        # cost.reported about the job (RE-8): the spend adds to the task's
        # project, never to the task's own spent (L446).
        def report_cost(ctx)
          ctx.emit("cost.reported", task: @task, subject: @job, payload: { tokens: @tokens, spend: @spend })
          return unless @task&.project_id

          project = Project.find_by!(id: @task.project_id, workspace_id: @job.workspace_id)
          project.update!(spent: project.spent + BigDecimal(@spend.to_s))
        end

        # The result must be of the job's kind's shape (RC-33): a rule
        # check's verdict, with not_applicable only for a "let the checker
        # decide" rule; a contract draft's Complete contract body.
        def check_shape
          raise Invalid, "tokens and spend are numbers of at least 0" unless counted?

          case @job.kind
          when "rule_check" then check_verdict
          when "contract_draft"
            unless @answer.key?("goal") && @answer["criteria"].is_a?(Array)
              raise Invalid, "A contract draft's result is a contract."
            end
          else raise Invalid, "No #{@job.kind} job is handed out in this milestone."
          end
        end

        def check_verdict
          unless CHECK_RESULTS.include?(@answer["result"]) && @answer["reason"].is_a?(String)
            raise Invalid, "A rule check's result is passed, failed or not_applicable, with a reason."
          end
          return unless @answer["result"] == "not_applicable"

          check = RuleCheck.find_by!(id: @job.target_id, workspace_id: @job.workspace_id)
          version = RuleVersion.find_by!(id: check.rule_version_id, workspace_id: @job.workspace_id)
          raise Invalid, "Only a rule that lets the checker decide may not apply." unless version.scope_kind == "checker_decides"
        end

        def counted?
          @tokens.is_a?(Integer) && @tokens >= 0 && @spend.is_a?(Numeric) && @spend >= 0
        end
      end
    end
  end
end
