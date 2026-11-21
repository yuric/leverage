module Leverage
  module Reads
    # The owner sees what the orchestrator decided alone (AP-31 to AP-35).
    # An answer or approval can be replaced. The original actor, decision
    # time and any overturn come from the events; content stays on its row.
    module Decisions
      ACTION_HISTORY = %w[action.approved action.started action.stopped action.withdrawn action.overturn_recorded].freeze
      UNDOABLE_ACTION_STATES = %w[approved started].freeze

      module_function

      def call(workspace_id)
        Snapshot.call(workspace_id) do
          events = Event.where(workspace_id: workspace_id)
          decisions = decision_events(events)
          tasks = Task.where(workspace_id: workspace_id, id: decisions.map(&:task_id)).index_by(&:id)
          question_ids, action_ids = decisions.partition { |event| event.subject_kind == "question" }
            .map { |group| group.map(&:subject_id).uniq }
          questions = ::Question.where(workspace_id: workspace_id, id: question_ids).index_by(&:id)
          actions = Action.where(workspace_id: workspace_id, id: action_ids).index_by(&:id)
          overturns = events.where(type: "question.overturned", subject_kind: "question", subject_id: question_ids)
            .order(:seq).group_by(&:subject_id)
          history = events.where(type: ACTION_HISTORY, subject_kind: "action", subject_id: action_ids)
            .order(:seq).group_by(&:subject_id)

          { decisions: decisions.map do |event|
            task = tasks.fetch(event.task_id)
            id = event.subject_id
            if event.subject_kind == "question"
              answer(event, task, questions.fetch(id), overturns.fetch(id, []))
            else
              approval(event, task, actions[id], history.fetch(id))
            end
          end }
        end
      end

      def decision_events(events)
        # Job result authorization determines the actor's role when the event is written.
        events.where(actor_kind: "seat")
          .where("type = 'action.approved' OR (type = 'question.answered' AND payload->>'basis' = 'decision')")
          .order(seq: :desc).to_a
      end

      def answer(event, task, question, overturns)
        overturned = overturns.find { |candidate| candidate.seq > event.seq }
        decision(event, task).merge(kind: "question", question_id: question.id, action_id: nil,
          summary: question.text.to_s, outcome: (question.answer if question.outcome == "answered"),
          action_state: nil, started: false, overturned_at: Shapes.time(overturned&.at),
          overturn_effect: ("answer_withdrawn" if overturned),
          undoable: live?(task) && overturned.nil? && question.outcome == "answered")
      end

      def approval(event, task, action, history)
        later = history.drop_while { |candidate| candidate.seq <= event.seq }
        subsequent_approval = later.any? { |candidate| candidate.type == "action.approved" }
        same_approval = later.take_while { |candidate| !%w[action.approved action.withdrawn].include?(candidate.type) }
        overturned = same_approval.find do |candidate|
          candidate.type == "action.overturn_recorded" ||
            (candidate.type == "action.stopped" && candidate.payload["overturned"] == true)
        end
        # An edit can remove an action definition after a return for rework.
        # Its decision is still in the log, but the definition's text is gone.
        state = action&.state
        summary = action ? action_summary(action) : ""
        decision(event, task).merge(kind: "approval", action_id: event.subject_id, question_id: nil,
          summary: summary, outcome: nil, action_state: state,
          started: same_approval.any? { |candidate| candidate.type == "action.started" },
          overturned_at: Shapes.time(overturned&.at), overturn_effect: approval_effect(overturned),
          undoable: live?(task) && !subsequent_approval && overturned.nil? && UNDOABLE_ACTION_STATES.include?(state))
      end

      def action_summary(action)
        description = action.description.to_s.strip
        return description if description.match?(/\A#{Regexp.escape(action.kind)}\b/i)

        [ action.kind.capitalize, description.presence ].compact.join(" ")
      end

      def decision(event, task)
        { task_id: task.id, task_title: task.title.to_s, seat_id: event.actor_id, decided_at: Shapes.time(event.at) }
      end

      def live?(task) = !%w[done cancelled].include?(task.state)

      def approval_effect(overturned)
        case overturned&.type
        when "action.stopped" then "stopped"
        when "action.overturn_recorded" then "recorded_only"
        end
      end
    end
  end
end
