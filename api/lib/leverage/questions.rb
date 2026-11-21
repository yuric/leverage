module Leverage
  # Questions and their answers (DB-21, AP-2 to AP-8). Only a pass-on
  # opens a Needs you item, and only a blocking question pauses the lease.
  module Questions
    OWNER_HOLD = "owner_question".freeze

    module_function

    def ask(ctx, task, text:, assumption:, blocking:)
      question = Question.create!(workspace_id: task.workspace_id, task_id: task.id, asking_seat_id: ctx.request.caller_id,
        text: text, assumption: assumption, blocking: blocking, asked_at: ctx.at)
      ctx.emit("question.asked", task: task, subject: question, payload: { blocking: blocking })
      question
    end

    def route(ctx, question, effect)
      if effect == "to_orchestrator"
        task = task_of(question)
        Jobs.queue(ctx, kind: "question", task: task, target: question, seat_role: "orchestrator",
          input: { "question_id" => question.id, "task_id" => task.id, "project_id" => task.project_id })
      else
        asked = ctx.events.find { |event| event.type == "question.asked" && event.subject_id == question.id }
        pass_on(ctx, question, cause_id: asked&.id)
      end
    end

    def answer(ctx, question, by:, text:, basis:)
      task = task_of(question)
      kind, id = by
      question.update!(outcome: "answered", answer: text, basis: basis, answered_by_kind: kind, answered_by_id: id,
        answered_at: ctx.at, read_at: nil)
      ctx.emit("question.answered", task: task, subject: question, actor_kind: kind, actor_id: id, payload: { basis: basis })
      resolve_item(ctx, task, question) if kind == "owner"
    end

    def pass_on(ctx, question, cause_id: nil)
      task = task_of(question)
      question.update!(outcome: "passed_on")
      facts = { question_id: question.id }
      if question.blocking
        Holds.open(ctx, task: task, reason: OWNER_HOLD, facts: facts, cause_id: cause_id)
      else
        definition = Holds.needs_you_item(OWNER_HOLD)
        inbox = InboxItem.create!(workspace_id: task.workspace_id, kind: definition.fetch("item"), about_kind: "task",
          about_id: task.id, facts: facts, opened_at: ctx.at, choices: definition.fetch("choices").pluck("choice"))
        ctx.emit("inbox.opened", task: task, subject: inbox, actor_kind: "app", actor_id: nil,
          cause_id: cause_id, payload: { kind: inbox.kind })
      end
    end

    def overturn(ctx, question)
      question.update!(outcome: "overturned", read_at: nil)
      ctx.emit("question.overturned", task: task_of(question), subject: question, payload: {})
    end

    def for_job(job)
      Question.find_by!(id: job.target_id, task_id: job.task_id, workspace_id: job.workspace_id)
    end

    def miss_job(ctx, job, due_kind)
      Jobs.time_out(ctx, job, due_kind)
      if Timers.second_miss?(job)
        pass_on(ctx, for_job(job))
      else
        Jobs.requeue(ctx, job)
      end
    end

    def task_of(question) = Task.find_by!(id: question.task_id, workspace_id: question.workspace_id)

    def resolve_item(ctx, task, question)
      kind = Holds.needs_you_item(OWNER_HOLD).fetch("item")
      item = InboxItem.where(workspace_id: task.workspace_id, about_kind: "task", about_id: task.id, kind: kind, state: "open")
        .find_by("facts ->> 'question_id' = ?", question.id)
      return unless item

      if item.hold_id
        hold = Holds.open_holds(task).find { |open| open.id == item.hold_id && open.reason == OWNER_HOLD }
        Holds.close(ctx, hold: hold, task: task, choice: "answer") if hold
      else
        actor_kind, actor_id = ctx.actor
        item.update!(state: "resolved", resolved_by_kind: actor_kind, resolved_by_id: actor_id, resolved_at: ctx.at)
        ctx.emit("inbox.resolved", task: task, subject: item, payload: { choice: "answer" })
      end
    end

    private_class_method :task_of, :resolve_item
  end
end
