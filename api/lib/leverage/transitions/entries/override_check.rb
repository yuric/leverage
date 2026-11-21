module Leverage
  module Transitions
    module Entries
      # override_check (PRD L162 to L167, L380 to L383, L423, L910;
      # milestone 4 plan RD-45, RD-47, RD-48): "Let it through once", for one
      # failed or errored check, or one held at the re-run limit, which never
      # ran. RuleChecks.override stores who, when and why and writes
      # check.overridden; the hold the check caused closes with its item
      # (override_once): check_error, rerun_limit, or the rule's
      # claim_gate_failed, "Refused for every agent", for a failed claim
      # check (RD-47). Then:
      #
      #   - a command still waiting on the check is gated again (rule 9), so
      #     it completes in place (L382, RD-45), unless another hold is open
      #     on its task, whose lifting gates it again (L378);
      #   - otherwise the override completes nothing by itself (L380): a
      #     command the check refused is marked notify, so GET /v1/next
      #     answers command for its key and its requester sends it again.
      #     A command that completed (Complete contract under
      #     contract_incomplete, a pass that became a failed review) is left
      #     as it is: the Mac app sends Complete contract again (RD-48).
      #
      # An override can approve the action stopped by this exact failed
      # gate, or let an action waiting on this errored gate be checked again.
      # An already overridden, final approval, or cancelled check is refused.
      #
      # Params: id (the rule check), reason.
      class OverrideCheck < Entry
        OVERRIDABLE = %w[failed error].freeze
        ANSWERED = %w[check_error claim_gate_failed rerun_limit].freeze
        CLAIM_HOOK = "task.before_claim".freeze
        ACTION_HOOK = "action.requested".freeze
        OVERRIDE_ONCE = "override_once".freeze

        def load(ctx)
          @check = RuleCheck.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such rule check")
          @task = @check.task_id && Task.find(@check.task_id)
          @reason = ctx.request.params["reason"]
          raise Invalid, "An override says why" unless @reason.is_a?(String) && !@reason.strip.empty?
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) unless overridable?
          causes.compact
        end

        def perform(ctx)
          user = User.find_by!(id: ctx.caller_id, workspace_id: ctx.workspace.id)
          RuleChecks.override(ctx, @check, user: user, reason: @reason)
          if @check.hook == ACTION_HOOK
            override_action(ctx)
            return
          end
          answered_holds.each { |hold| Holds.close(ctx, hold: hold, task: @task, choice: OVERRIDE_ONCE) }
          pending = PendingTransition.find_by(id: @check.pending_transition_id, state: "pending")
          if pending
            trigger = Gating::Trigger.new(kind: :check_overridden, rule_check_id: @check.id)
            CheckReentry.after(ctx, @check, trigger) unless Holds.held?(@task)
          else
            notify_refused_command(ctx)
          end
          @result = nil
        end

        private

        def overridable?
          return false if @check.overridden_at || @task.nil? || @task.state == "cancelled"
          if @check.hook == ACTION_HOOK
            return false unless @task.state == "finishing" && !Gate.approval_check?(@check) && action
            return @check.result == "failed" if stopped_hold

            return action.state == "requested" && @check.result == "error"
          end
          return true if OVERRIDABLE.include?(@check.result)

          @check.result.nil? && answered_holds.any? { |hold| hold.reason == "rerun_limit" }
        end

        def override_action(ctx)
          if (hold = stopped_hold)
            approved = Actions.approve(ctx, action, by: ctx.actor, rule_check: @check)
            Holds.close(ctx, hold: hold, task: @task, choice: OVERRIDE_ONCE)
            Finishing.settle(ctx, @task.reload, by: approved)
          else
            trigger = Gating::Trigger.new(kind: :check_overridden, rule_check_id: @check.id)
            CheckReentry.after(ctx, @check, trigger)
          end
          @result = nil
        end

        def action
          return unless @check.subject_kind == "action"

          @action ||= Actions.for_task(@task).find_by(id: @check.subject_id)
        end

        def stopped_hold
          return unless action&.state == "stopped"

          @stopped_hold ||= Actions.holds_for(action, "action_stopped").find { |hold| hold.rule_check_id == @check.id }
        end

        # The open holds on the task the override answers, in the order they
        # opened.
        def answered_holds
          @answered_holds ||= Holds.open_holds(@task).select { |hold| ANSWERED.include?(hold.reason) && answers?(hold) }
        end

        # A hold names the check it is about (holds.rule_check_id); one that
        # names none is matched by its rule and what the check is.
        def answers?(hold)
          return true if hold.rule_check_id == @check.id
          return false unless hold.rule_id == @check.rule_id

          case hold.reason
          when "check_error" then hold.rule_check_id.nil? && @check.result == "error"
          when "rerun_limit" then hold.rule_check_id.nil? && @check.result.nil?
          when "claim_gate_failed" then @check.hook == CLAIM_HOOK && @check.result == "failed"
          else false
          end
        end

        # L380: the requester's refused command is raised again as the
        # command kind of GET /v1/next (DB-34: notify until it is read).
        def notify_refused_command(ctx)
          row = requester_command
          row.update!(notify: true, read_at: nil, updated_at: ctx.at) if row&.outcome == "refused"
        end

        # The commands row of the command the check was made for: the
        # pending transition's requester and key, or, for a check made and
        # finished inside its command (an app check), the caller and key of
        # its first event.
        def requester_command
          pending = @check.pending_transition_id && PendingTransition.find_by(id: @check.pending_transition_id)
          caller_kind, caller_id, key =
            if pending
              [ pending.requester_kind, pending.requester_id, pending.command_key ]
            else
              event = Event.where(workspace_id: @check.workspace_id, subject_kind: "rule_check", subject_id: @check.id)
                .where.not(command_id: nil).order(:seq).first
              event && [ event.actor_kind, event.actor_id, event.command_id ]
            end
          key && Command.find_by(workspace_id: @check.workspace_id, caller_kind: caller_kind, caller_id: caller_id, key: key)
        end
      end
    end
  end
end
