module Leverage
  module Transitions
    module Entries
      # claim (PRD Lifecycle L83, L492, L544-L545, L667, L690; milestone 2
      # plan EN-7, EN-23; milestone 3 plan HD-4, HE-5): a builder seat
      # claims the next eligible Ready task (Eligibility.next_task) at
      # task.before_claim. The task goes to Working; the seat is its holder
      # and builder; the lease runs one lease length. The task records the
      # credential that does the work: the seat's first available candidate,
      # on which Eligibility has checked its run is (HD-4). task.claimed
      # carries the seat, that credential (null for a seat that connects on
      # its own) and the model a run on it uses (Candidates.model_for, HE-5:
      # the seat's within its provider group, the credential's in another;
      # null when that one is empty).
      #
      # Refused not_eligible when the seat may not claim or nothing is left
      # (RC-50). The claim names no task, so no other refusal can apply:
      # the task it picks is Ready, unheld and held by nobody. A claim that
      # waited on its check is gated again when the check settles; by then
      # the seat may have been paused, or its run's login limited or signed
      # out, so it is refused not_eligible unless the seat is still enabled,
      # not paused and not removed, and placed for the task (HD-4;
      # Eligibility.placed_for?, not may_claim?, which the reservation
      # itself makes false). Re-entry reads that as invalid_state and the
      # reservation lapses (milestone 4 review, finding 7).
      #
      # Result: ClaimTaskResult.
      #
      # Gated at task.before_claim, about the seat (milestone 4 plan §2.1,
      # RE-5, SM-14). A model check makes the claim provisional (wait): the
      # seat holds the Ready task with no lease, no event and no briefing,
      # so nobody else is offered it, until the check passes and the claim
      # completes as the seat, with its key; then task.claimed, the lease
      # and the briefing come. The claim a pending transition stores names
      # no task: its key finds the task it reserved
      # (PendingTransitions.for_request).
      class Claim < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          reserved = PendingTransitions.for_request(ctx.request)
          if reserved && reserved.command == command
            @task = Task.find_by!(id: reserved.task_id, workspace_id: ctx.workspace.id)
            @reserved = true
            return
          end

          # A builder lease past its due time has ended (EN-14): its timer
          # runs first, so its task is back in Ready and claimable now.
          Timers.apply_claimable(ctx, :task)
          @task = Eligibility.next_task(@seat, at: ctx.at)
        end

        def refusals(ctx)
          return [ "not_eligible" ] unless @task
          return [ "not_eligible" ] if @reserved && !still_eligible?(ctx)

          [ state_refusal(@task.state) ].compact
        end

        def gate_request_fields(_ctx)
          super.merge(task_id: @task.id, project_id: @task.project_id, round: @task.round, subject_kind: "seat",
            subject_id: @seat.id)
        end

        # The claim waits on a model check: provisional (RE-5).
        def wait(_ctx, _pending)
          @task.update!(holder_seat_id: @seat.id)
        end

        def perform(ctx)
          credential = @seat.credential_id && Candidates.first_available(@seat, @task, ctx.at)
          model = Candidates.model_for(@seat, credential)
          @task.update!(state: "working", holder_seat_id: @seat.id, builder_seat_id: @seat.id,
            credential_id: credential&.id, resume_pending_since: nil)
          Leases.grant(ctx, @task)
          ctx.emit("task.claimed", task: @task, payload: { seat_id: @seat.id, credential_id: credential&.id, model: model })
          @result = {
            "task" => self.class.summary(@task.reload),
            "lease" => { "seat_id" => @seat.id, "lease_due_at" => @task.lease_due_at.utc.iso8601(6) },
            "briefing" => Briefing.for(@task, seat: @seat),
            "work_reference" => @task.work_reference,
            "credential_id" => credential&.id,
            "model" => model
          }
        end

        # The reserving seat may still claim the task it reserved.
        def still_eligible?(ctx)
          @seat.reload
          @seat.enabled && !@seat.paused && @seat.removed_at.nil? &&
            Finishing.waiting_for(@seat).empty? && Eligibility.placed_for?(@seat, @task, ctx.at)
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
