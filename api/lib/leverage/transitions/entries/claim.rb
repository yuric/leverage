module Leverage
  module Transitions
    module Entries
      # claim (PRD Lifecycle L83, L492, L544-L545; milestone 2 plan EN-7,
      # EN-8, EN-23): a builder seat claims the next eligible Ready task
      # (Eligibility.next_task) at task.before_claim. The task goes to
      # Working; the seat is its holder and builder; the task records the
      # seat's credential; the lease runs one lease length. task.claimed
      # carries the seat, the credential (null for a seat that connects on
      # its own) and the model (null when the seat's is empty).
      #
      # Refused not_eligible when the seat may not claim or nothing is left
      # (RC-50). The claim names no task, so no other refusal can apply:
      # the task it picks is Ready, unheld and held by nobody.
      #
      # Result: ClaimTaskResult.
      class Claim < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          # A builder lease past its due time has ended (EN-14): its timer
          # runs first, so its task is back in Ready and claimable now.
          Timers.apply_claimable(ctx, :task)
          @task = Eligibility.next_task(@seat)
        end

        def refusals(_ctx)
          return [ "not_eligible" ] unless @task

          [ state_refusal(@task.state) ].compact
        end

        def gate_request_fields(_ctx)
          super.merge(task_id: @task.id, project_id: @task.project_id, round: @task.round)
        end

        def perform(ctx)
          @task.update!(state: "working", holder_seat_id: @seat.id, builder_seat_id: @seat.id,
            credential_id: @seat.credential_id, resume_pending_since: nil)
          Leases.grant(ctx, @task)
          model = @seat.model.presence
          ctx.emit("task.claimed", task: @task,
            payload: { seat_id: @seat.id, credential_id: @seat.credential_id, model: model })
          @result = {
            "task" => self.class.summary(@task.reload),
            "lease" => { "seat_id" => @seat.id, "lease_due_at" => @task.lease_due_at.utc.iso8601(6) },
            "briefing" => Briefing.for(@task, seat: @seat),
            "work_reference" => @task.work_reference,
            "credential_id" => @seat.credential_id,
            "model" => model
          }
        end

        # A task row in the contract's TaskSummary shape.
        def self.summary(task)
          {
            "id" => task.id, "project_id" => task.project_id, "title" => task.title.to_s, "goal" => task.goal.to_s,
            "details" => task.details, "state" => task.state, "round" => task.round,
            "holder_seat_id" => task.holder_seat_id, "builder_seat_id" => task.builder_seat_id,
            "lease_due_at" => task.lease_due_at&.utc&.iso8601(6),
            "lease_time_left_while_paused" => task.lease_time_left_while_paused&.to_i,
            "minimum_strength_rank" => task.minimum_strength_rank, "contract_version" => task.contract_version,
            "budget_cap" => task.budget_cap&.to_f, "spent" => task.spent.to_f, "work_reference" => task.work_reference,
            "priority" => task.priority
          }
        end
      end
    end
  end
end
