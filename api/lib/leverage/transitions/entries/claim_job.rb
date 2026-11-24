module Leverage
  module Transitions
    module Entries
      # claim_job (PRD L540, L545, L872; milestone 4 plan RD-34 to RD-36,
      # RD-40, IF-13; traces 16 and 19): an orchestrator or a planner claims
      # the oldest job its role takes (Jobs.next_for), or gets the one it
      # holds again, which writes nothing (RD-40: a run moved to another
      # credential continues it). A new claim writes job.claimed with the
      # credential and the model (Jobs.claim), and a check job's attempt
      # starts (RuleChecks.start, check.started).
      #
      # Refused not_eligible when the seat may not claim or nothing is left,
      # as the other claims are (RC-50): the claim names no job, so no other
      # refusal can apply.
      #
      # Result: ClaimJobResult, with the job's input and its material
      # (JobInputs, RD-30), the credential and the model its claim recorded,
      # and run_due_at, the time after which its result is refused
      # (Timers.job_due_at, RD-34).
      class ClaimJob < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @job = Jobs.next_for(@seat, at: ctx.at)
        end

        def refusals(_ctx)
          return [ "not_eligible" ] unless @job

          [ state_refusal(nil) ].compact
        end

        def perform(ctx)
          unless @job.state == "claimed"
            Jobs.claim(ctx, @job, @seat)
            if Timers.check_job?(@job)
              check = RuleCheck.find_by!(id: @job.target_id, workspace_id: @job.workspace_id)
              RuleChecks.start(ctx, check, job: @job, seat: @seat)
            end
          end
          @job.reload
          @result = {
            "job_id" => @job.id, "kind" => @job.kind, "input" => JobInputs.for(@job, seat: @seat),
            "credential_id" => @job.credential_id, "model" => Jobs.model_of(@job, @seat),
            "run_due_at" => Timers.job_due_at(@job, :run)&.utc&.iso8601(6)
          }
        end
      end
    end
  end
end
