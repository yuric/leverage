module Leverage
  module Transitions
    module Entries
      # The orchestrator_offline timer (PRD L401, L402; timers.json;
      # state_machine.json; needs_you.json; milestone 4 plan §2.1, The
      # orchestrator's presence and its item, RD-15 to RD-20, SM-39, RC-37;
      # traces 07 and 19): a workspace timer the sweep fires on every run,
      # through Timers.apply_workspace. It reads RolePresence and writes only
      # when the role's state has changed:
      #
      #   offline, no item open,  opens the workspace's one Orchestrator
      #   and a check waits       offline item (inbox.opened), effective at
      #                           the later of the time the role went
      #                           offline and the time the oldest waiting
      #                           check began to wait (trace 07: 30; trace
      #                           19: 1220). A check waits when its job is
      #                           queued or it is held with check_error
      #                           (RD-16, RD-18); with no orchestrator seat
      #                           at all too. Its facts: the role, the count
      #                           then, and the account that is the cause
      #                           (RolePresence.cause_credential), else null.
      #
      #   online again            resolves the item (inbox.resolved, no
      #                           choice), effective when the role came back
      #                           (its poll, or its account's reset), and
      #                           in the same run every errored check held
      #                           with check_error gets a new attempt
      #                           (RuleChecks.queue_attempt) but an
      #                           errored task.before_claim check, whose hold
      #                           only closes (RC-37, L392). A check still
      #                           queued keeps its job and its timers
      #                           (RD-19). The hold of a check queued again
      #                           closes when its result arrives (L403).
      #
      # While online with no item open, an errored check that has no task
      # item of its own is one that erred while the orchestrator was
      # offline (its item opens only while the orchestrator is online,
      # SM-39) and came back before a sweep could open the workspace item:
      # it is queued again, or its claim hold closed, the same way. A check
      # that erred while the orchestrator was online has its item and stays
      # with the owner.
      #
      # It never opens an item for the planner (RD-20).
      class OrchestratorOffline < Entry
        ROLE = "orchestrator".freeze
        ITEM = "orchestrator_offline".freeze
        CLAIM_HOOK = "task.before_claim".freeze
        CHECK_ERROR = "check_error".freeze

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          item = InboxItem.find_by(workspace_id: ctx.workspace.id, kind: ITEM, state: "open")
          if RolePresence.online?(ctx.workspace, ROLE, ctx.at)
            back(ctx, item)
          elsif item.nil?
            open(ctx)
          end
          @result = nil
        end

        private

        def open(ctx)
          since = waiting_since(ctx.workspace.id)
          return unless since

          effective = [ RolePresence.offline_since(ctx.workspace, ROLE, ctx.at), since ].max
          cause = RolePresence.cause_credential(ctx.workspace, ROLE, ctx.at)
          Timers.as_timer(ctx, command, effective) do |timer_ctx|
            inbox = InboxItem.create!(workspace_id: ctx.workspace.id, kind: ITEM, about_kind: "workspace", about_id: ctx.workspace.id,
              credential_id: cause&.id, choices: [], opened_at: ctx.at,
              facts: { role: ROLE, waiting_checks: waiting_count(ctx.workspace.id), credential_id: cause&.id })
            timer_ctx.emit("inbox.opened", subject: inbox, payload: { kind: ITEM })
          end
        end

        def back(ctx, item)
          returning = errored_held(ctx.workspace.id).select { |_hold, _check, has_item| item || !has_item }
          return if item.nil? && returning.empty?

          came_back = [ RolePresence.online_since(ctx.workspace, ROLE, ctx.at), item && opened_at(item) ].compact.max
          Timers.as_timer(ctx, command, came_back) { |timer_ctx| resolve(timer_ctx, item) } if item
          returning.each do |hold, check, _has_item|
            task = Task.find(hold.task_id)
            Timers.as_timer(ctx, command, Timers.effective_at(task, came_back)) do |timer_ctx|
              check.hook == CLAIM_HOOK ? close(timer_ctx, hold, task) : run_again(timer_ctx, check)
            end
          end
        end

        def resolve(ctx, item)
          item.update!(state: "resolved", resolved_by_kind: "app", resolved_by_id: nil, resolved_at: ctx.at)
          ctx.emit("inbox.resolved", subject: item, payload: { choice: nil })
        end

        # RC-37: the errored claim check is not queued again; the next claim
        # checks afresh.
        def close(ctx, hold, task)
          Holds.close(ctx, hold: hold, task: task, effective_at: ctx.effective_at, command_id: nil)
        end

        # A new attempt of the errored check on a job of its own, written
        # by RuleChecks.queue_attempt in the traces' order (check.queued
        # naming the job, then job.queued; trace 19, command 31), as Run it
        # again writes it.
        def run_again(ctx, check)
          RuleChecks.queue_attempt(ctx, check, seat_role: ROLE)
        end

        # The open check_error holds whose check ended in error, oldest
        # first, each as [hold, check, whether its task item is open]. A
        # hold's check is the one it names (holds.rule_check_id), else its
        # rule's latest check on the task.
        def errored_held(workspace_id)
          ::Hold.where(workspace_id: workspace_id, reason: CHECK_ERROR, closed_at: nil).order(:opened_at, :id).filter_map do |hold|
            check = hold.rule_check_id && RuleCheck.find_by(id: hold.rule_check_id, workspace_id: workspace_id)
            check ||= RuleCheck.where(workspace_id: workspace_id, task_id: hold.task_id, rule_id: hold.rule_id)
              .order(:updated_at, :id).last
            next unless check&.result == "error"

            [ hold, check, InboxItem.where(hold_id: hold.id, state: "open").exists? ]
          end
        end

        def queued_checks(workspace_id) = Job.where(workspace_id: workspace_id, kind: "rule_check", state: "queued")

        # RD-18: rule checks queued and not claimed, plus those held with
        # check_error.
        def waiting_count(workspace_id)
          queued_checks(workspace_id).distinct.count(:target_id) + errored_held(workspace_id).size
        end

        # When the oldest waiting check began to wait: its job's queued time,
        # or its check_error hold's effective time. nil when none waits.
        def waiting_since(workspace_id)
          held = errored_held(workspace_id).map do |hold, _check, _has_item|
            Event.where(workspace_id: workspace_id, type: "hold.opened", subject_kind: "hold", subject_id: hold.id)
              .pick(:effective_at) || hold.opened_at
          end
          [ queued_checks(workspace_id).minimum(:queued_at), *held ].compact.min
        end

        def opened_at(item)
          Event.where(workspace_id: item.workspace_id, type: "inbox.opened", subject_kind: "inbox_item", subject_id: item.id)
            .pick(:effective_at)
        end
      end
    end
  end
end
