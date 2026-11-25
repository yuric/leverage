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
      # that transition is gated again (CheckReentry.after, with the
      # trigger check_finished). A contract draft's result is the Complete
      # contract command, run as the planner with this call's key
      # (Transitions.run_as, RE-6), from the result's title, details,
      # criteria and actions and the task's stored work reference, minimum
      # strength rank and budget cap, whatever the result says of those
      # three (RD-37, L539). A null or blank draft keeps the stored details.
      # When that Complete contract waits on a model check, this call is the
      # one waiting: pending? answers true.
      #
      # Refused, and nothing is written (RD-41), in precedence order:
      # task_cancelled for the job of a task cancelled while the seat held
      # the job; not_holder from a seat that did not claim the job;
      # forbidden from a seat of a role that does not claim its kind, or
      # from a seat the owner has turned off (a paused seat finishes the
      # job it holds; the refused job is left to its run timeout);
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
        BY_KIND = {
          "rule_check" => JobResults::RuleCheck,
          "contract_draft" => JobResults::ContractDraft,
          "approval" => JobResults::Approval,
          "question" => JobResults::Question
        }.freeze

        def load(ctx)
          params = ctx.request.params
          @job = Job.find_by(id: params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such job")
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = @job.task_id && Task.find_by(id: @job.task_id, workspace_id: ctx.workspace.id)
          @result = nil
          @tokens = params["tokens"]
          @spend = Costs.report_amount(@tokens, params["spend"])
          @answer = params["result"].to_h.stringify_keys

          @handler = BY_KIND.fetch(@job.kind) { raise Invalid, "No #{@job.kind} job is handed out in this milestone." }
          @handler.check_shape(@job, @answer)
        end

        def refusals(ctx)
          codes = []
          held = @job.claimed_by_seat_id == @seat.id
          codes << "task_cancelled" if held && @task&.state == "cancelled"
          codes << "not_holder" unless held
          codes << "forbidden" unless @seat.enabled && Jobs.role_matches?(@job, @seat)
          if @task&.content_deleted_at || @job.state != "claimed" || Jobs.due?(@job, :run, ctx.at)
            codes << Refusal.new(code: "invalid_state")
          end
          codes.concat(@handler.refusals(@task))
          codes << state_refusal(nil)
          codes.compact
        end

        def perform(ctx)
          Jobs.finish(ctx, @job, result: @answer, tokens: @tokens, spend: @spend)
          @outcome = @handler.perform(ctx, @job, @task, seat: @seat, answer: @answer, tokens: @tokens, spend: @spend)
        end

        # Whether the command waits: a planner's Complete contract met a
        # model-checked gate (RE-6), so this call answers 202 pending.
        def pending? = @outcome == :pending
      end
    end
  end
end
