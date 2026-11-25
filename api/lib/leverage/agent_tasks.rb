module Leverage
  # Reads the history under the workspace lock so simultaneous adds share the
  # same rate, lineage and open-task limits (UX-14).
  module AgentTasks
    RATE = 20
    CAP = 50
    CAP_REASON = "Agents have added #{CAP} open tasks in this workspace.".freeze
    CLAIMS = %w[task.claimed review.started job.claimed].freeze
    CAP_ITEM = "agent_tasks_at_limit".freeze

    module_function

    def held_work(seat, at:)
      Task.find_by(workspace_id: seat.workspace_id, holder_seat_id: seat.id) ||
        Review.find_by(workspace_id: seat.workspace_id, reviewer_seat_id: seat.id, verdict: nil) ||
        Jobs.held(seat, at)
    end

    def task_of(work)
      return work if work.is_a?(Task)

      Task.find_by(id: work.task_id, workspace_id: work.workspace_id) if work&.task_id
    end

    def limit(seat, work, at:)
      created = creations(seat.workspace_id)
      return CAP_REASON if at_cap?(seat.workspace_id)
      if created.where(actor_id: seat.id).where("at > ?", at - 1.hour).limit(RATE).count >= RATE
        return "This seat has added #{RATE} tasks in the last hour."
      end

      origin = if work
        task_of(work)&.id
      else
        Event.where(workspace_id: seat.workspace_id, actor_kind: "seat", actor_id: seat.id, type: CLAIMS).order(seq: :desc).pick(:task_id)
      end
      "The task of this seat's work was itself added by an agent." if origin && created.exists?(task_id: origin)
    end

    def creations(workspace_id) = Event.where(workspace_id: workspace_id, type: "task.created", actor_kind: "seat")

    def at_cap?(workspace_id)
      Task.where(workspace_id: workspace_id, id: creations(workspace_id).select(:task_id))
        .where.not(state: %w[done cancelled]).limit(CAP).count >= CAP
    end

    def contract_incomplete(ctx, task, hold, opened)
      seat_id = creations(task.workspace_id).where(task_id: task.id).pick(:actor_id)
      return unless seat_id

      definition = Contract.needs_you.fetch("items").find { |item| item.fetch("item") == "agent_task_incomplete" }
      item = InboxItem.create!(workspace_id: task.workspace_id, kind: definition.fetch("item"), about_kind: "task",
        about_id: task.id, hold_id: hold.id, facts: { seat_id: seat_id }, opened_at: ctx.at,
        choices: definition.fetch("choices").pluck("choice"))
      ctx.emit("inbox.opened", task: task, subject: item, cause_id: opened.id, actor_kind: "app", actor_id: nil,
        payload: { kind: item.kind })
    end

    # The refusal itself must be the workspace cap, after refusal precedence.
    # A terminal move or the sweep can close the workspace item.
    def after_command(ctx, outcome)
      return unless ctx.workspace

      if outcome.refusal&.code == "add_task_limit" && outcome.refusal.reason == CAP_REASON
        return if cap_items(ctx).exists?

        item = InboxItem.create!(workspace_id: ctx.workspace.id, kind: CAP_ITEM, about_kind: "workspace",
          about_id: ctx.workspace.id, facts: {}, choices: [], opened_at: ctx.at)
        ctx.emit("inbox.opened", subject: item, actor_kind: "app", actor_id: nil, payload: { kind: item.kind })
      elsif ctx.request.command == "reviewer_eligibility" || ctx.events.any? { |event| %w[task.done task.cancelled].include?(event.type) }
        item = cap_items(ctx).first
        if item && !at_cap?(ctx.workspace.id)
          item.update!(state: "resolved", resolved_by_kind: "app", resolved_at: ctx.at)
          ctx.emit("inbox.resolved", subject: item, actor_kind: "app", actor_id: nil, payload: { choice: nil })
        end
      end
    end

    def cap_items(ctx) = InboxItem.where(workspace_id: ctx.workspace.id, kind: CAP_ITEM, state: "open")

    private_class_method :creations, :at_cap?, :cap_items
  end
end
