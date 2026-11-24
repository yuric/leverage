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
      #                           retries checks a counting seat can take
      #                           (GA-6), or closes their holds for an
      #                           errored task.before_claim check (RC-37).
      #                           Other errors go to the owner. Checks
      #                           still queued keep their jobs and timers.
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

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          item = InboxItem.find_by(workspace_id: ctx.workspace.id, kind: ITEM, state: "open")
          waiting = RolePresence.waiting_checks(ctx.workspace)
          online = RolePresence.online_seats(ctx.workspace, ROLE, ctx.at, waiting: waiting)
          if online.any?
            back(ctx, item, waiting, online)
          elsif item.nil? && !waiting.empty?
            open(ctx, waiting)
          end
          @result = nil
        end

        private

        def open(ctx, waiting)
          effective = [ RolePresence.offline_since(ctx.workspace, ROLE, ctx.at, waiting: waiting), waiting.since ].max
          cause = RolePresence.cause_credential(ctx.workspace, ROLE, ctx.at)
          Timers.as_timer(ctx, command, effective) do |timer_ctx|
            inbox = InboxItem.create!(workspace_id: ctx.workspace.id, kind: ITEM, about_kind: "workspace", about_id: ctx.workspace.id,
              credential_id: cause&.id, choices: [], opened_at: ctx.at,
              facts: { role: ROLE, waiting_checks: waiting.count, credential_id: cause&.id })
            timer_ctx.emit("inbox.opened", subject: inbox, payload: { kind: ITEM })
          end
        end

        def back(ctx, item, waiting, online)
          returning = waiting.errored.select { |entry| item || !InboxItem.exists?(hold_id: entry.hold.id, state: "open") }
          return if item.nil? && returning.empty?

          came_back = [ RolePresence.online_since(ctx.workspace, ROLE, ctx.at, waiting: waiting), item && opened_at(item) ].compact.max
          retry_ids = retryable_ids(online, returning, ctx.at)
          Timers.as_timer(ctx, command, came_back) { |timer_ctx| resolve(timer_ctx, item) } if item
          returning.each do |entry|
            task = Task.find(entry.hold.task_id)
            Timers.as_timer(ctx, command, Timers.effective_at(task, came_back)) do |timer_ctx|
              recover_check(timer_ctx, entry, task, retry_ids.include?(entry.check.id))
            end
          end
        end

        def retryable_ids(online, returning, at)
          return [] if returning.empty?
          return returning.map { |entry| entry.check.id } if online.any? { |seat| seat.role == ROLE }

          attempts = returning.map { |entry| entry.next_attempt(at) }
          online.filter_map do |seat|
            job = Jobs.next_for(seat, at: at, additional: attempts)
            job.target_id if job&.new_record?
          end
        end

        def recover_check(ctx, entry, task, retryable)
          check = entry.check
          if !retryable
            cause = Event.find_by(workspace_id: entry.hold.workspace_id, type: "hold.opened", subject_id: entry.hold.id)
            Holds.open_item(ctx, entry.hold, task: task, facts: { rule_id: check.rule_id, rule_check_id: check.id }, cause_id: cause&.id)
          elsif check.hook == CLAIM_HOOK
            close(ctx, entry.hold, task)
          else
            run_again(ctx, check)
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
          Gate.requeue_check(ctx, check, seat_role: ROLE)
        end

        def opened_at(item)
          Event.where(workspace_id: item.workspace_id, type: "inbox.opened", subject_kind: "inbox_item", subject_id: item.id)
            .pick(:effective_at)
        end
      end
    end
  end
end
