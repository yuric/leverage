module Leverage
  # Holds and their Needs you items (PRD L150-L201; registry hold_reasons,
  # needs_you.json).
  #
  # First version, by WP1 (milestone 2 plan §4): open writes the hold row,
  # hold.opened, the Needs you row and inbox.opened; close writes their
  # counterparts. Neither touches a lease clock. WP4 owns this file from
  # here on (the oldest open hold, the pause and restart of both lease
  # clocks).
  module Holds
    module_function

    # Opens a hold on a task, and its Needs you item when the reason has
    # one. The app opens it unless an actor is named.
    #
    # Returns the Hold.
    def open(ctx, task:, reason:, cause_id: nil, facts: {}, rule_id: nil, credential_id: nil, actor_kind: "app",
             actor_id: nil, round: task.round)
      hold = Hold.create!(workspace_id: task.workspace_id, task_id: task.id, project_id: task.project_id, reason: reason,
        rule_id: rule_id, credential_id: credential_id, opened_at: ctx.at, opened_by_kind: actor_kind,
        opened_by_id: actor_id)
      opened = ctx.emit("hold.opened", task: task, round: round, subject: hold, cause_id: cause_id, actor_kind: actor_kind,
        actor_id: actor_id, payload: { reason: reason, rule_id: rule_id, credential_id: credential_id })
      item = needs_you_item(reason)
      if item
        inbox = InboxItem.create!(workspace_id: task.workspace_id, kind: item.fetch("item"), about_kind: "task",
          about_id: task.id, hold_id: hold.id, credential_id: credential_id, facts: facts, opened_at: ctx.at,
          choices: item.fetch("choices").map { |choice| choice.fetch("choice") })
        ctx.emit("inbox.opened", task: task, round: round, subject: inbox, cause_id: opened.id, actor_kind: actor_kind,
          actor_id: actor_id, payload: { kind: inbox.kind })
      end
      hold
    end

    # Closes a hold and resolves its open Needs you item with the owner's
    # choice (nil when it closes on its own). The request's caller closes
    # it unless an actor is named. lease_seat_id names the builder the
    # closing gives a fresh lease, if any.
    #
    # Returns the Hold.
    def close(ctx, hold:, task:, choice: nil, lease_seat_id: nil, wait_cause: nil, cause_id: nil,
              actor_kind: ctx.actor.first, actor_id: ctx.actor.last, round: task.round)
      hold.update!(closed_at: ctx.at, closed_by_kind: actor_kind, closed_by_id: actor_id)
      ctx.emit("hold.closed", task: task, round: round, subject: hold, cause_id: cause_id, actor_kind: actor_kind,
        actor_id: actor_id, payload: { reason: hold.reason, rule_id: hold.rule_id, credential_id: hold.credential_id,
                                       lease_seat_id: lease_seat_id, wait_cause: wait_cause })
      InboxItem.where(hold_id: hold.id, state: "open").order(:opened_at).each do |inbox|
        inbox.update!(state: "resolved", resolved_by_kind: actor_kind, resolved_by_id: actor_id, resolved_at: ctx.at)
        ctx.emit("inbox.resolved", task: task, round: round, subject: inbox, actor_kind: actor_kind, actor_id: actor_id,
          payload: { choice: choice })
      end
      hold
    end

    # The needs_you.json item a hold reason opens, or nil.
    def needs_you_item(reason)
      entry = Contract.registry.fetch("hold_reasons").find { |candidate| candidate.fetch("reason") == reason }
      raise ArgumentError, "unknown hold reason #{reason.inspect}" unless entry

      kind = entry.fetch("needs_you_item")
      kind && Contract.needs_you.fetch("items").find { |item| item.fetch("item") == kind }
    end
  end
end
