module Leverage
  # The hashed inputs of each hook (PRD L410-L417; hooks.json hashed_inputs;
  # milestone 4 plan §2.1 rule 1): the one reading of what a rule check's
  # input hash covers, used by Transitions::Gate to ask and by
  # rules/reentry.rb to compare. It reads only.
  #
  # For a command not yet performed, what it asks to change comes from its
  # request (params): at task.before_ready the requested contract, not the
  # stored one; at task.before_submit the requested handoff note; at
  # task.before_done the requested verdict and notes. What the request does
  # not change comes from the task's rows: the contract version, and each
  # live criterion's state and evidence in order. The shapes are those of
  # the contract's golden vectors (test/contract/gating_test.rb):
  #
  #   task.before_ready   goal, details, criteria [{text, kind}], actions
  #                       [{kind, description}], each list in request order
  #   task.before_claim   contract_version, seat_id
  #   task.before_submit  contract_version, handoff_note, criteria [{id,
  #                       state, evidence [[kind, value], ...]}] of every
  #                       live criterion by position
  #   task.before_done    contract_version, verdict, notes, evidence {id =>
  #                       [[kind, value], ...]} of every live criterion that
  #                       has evidence
  #   action.requested    contract_version, action_kind, action_description
  #                       of the action params names (aid, or action_id)
  #   review.assign       seat_id
  #   review.failed       review_id
  #   question.asked      question (the request's text)
  #   cost.reported       event_id (params' event_id: the cost.reported
  #                       event the hook is about)
  #
  # The app-only policy hooks hash the subject's id (RC-26). Evidence is in
  # the order it was attached (created_at, then id).
  module HookInputs
    module_function

    # The hashed inputs of hook for a command on task, a Hash with exactly
    # the keys hooks.json names, in values Gating.input_hash accepts.
    #
    # hook:   - a registry hook.
    # task:   - the Task the command is about.
    # params: - the command's request (string keys), or {}.
    # seat:   - the Seat the hook is about (task.before_claim, review.assign).
    # review: - the Review the hook is about (review.failed).
    #
    # Raises ArgumentError for an unknown hook, or a seat, review or action
    # the hook needs and is not given.
    def for(hook:, task:, params:, seat: nil, review: nil)
      params = (params || {}).to_h.stringify_keys
      case hook
      when "task.before_ready" then ready(params)
      when "task.before_claim" then { "contract_version" => task.contract_version, "seat_id" => required(seat, hook).id }
      when "task.before_submit"
        { "contract_version" => task.contract_version, "criteria" => criteria_states(task),
          "handoff_note" => params["handoff_note"] }
      when "task.before_done"
        { "contract_version" => task.contract_version, "verdict" => params["verdict"], "notes" => params["notes"],
          "evidence" => evidence_by_criterion(task) }
      when "action.requested" then requested(task, params)
      when "review.assign" then { "seat_id" => required(seat, hook).id }
      when "review.failed" then { "review_id" => required(review, hook).id }
      when "question.asked" then { "question" => params["text"] }
      when "cost.reported" then { "event_id" => params["event_id"] }
      else raise ArgumentError, "unknown hook #{hook.inspect}"
      end
    end

    # The contract a Complete contract asks for (PRD L80): its goal,
    # details, criteria and outward actions. Title, work reference, minimum
    # strength rank and budget cap are not hashed (L411).
    def ready(params)
      criteria = Array(params["criteria"]).map(&:to_h).map(&:stringify_keys)
      actions = Array(params["actions"]).map(&:to_h).map(&:stringify_keys)
      { "goal" => params["goal"], "details" => params["details"],
        "criteria" => criteria.map { |criterion| { "text" => criterion["text"], "kind" => criterion["kind"] } },
        "actions" => actions.map { |action| { "kind" => action["kind"], "description" => action["description"] } } }
    end

    def criteria_states(task)
      by_criterion = evidence_of(task)
      live_criteria(task).map do |criterion|
        { "id" => criterion.id, "state" => criterion.state, "evidence" => by_criterion.fetch(criterion.id, []) }
      end
    end

    def evidence_by_criterion(task)
      by_criterion = evidence_of(task)
      live_criteria(task).each_with_object({}) do |criterion, evidence|
        evidence[criterion.id] = by_criterion[criterion.id] if by_criterion.key?(criterion.id)
      end
    end

    def requested(task, params)
      action_id = params["aid"] || params["action_id"]
      action = action_id && Action.find_by(id: action_id, task_id: task.id)
      raise ArgumentError, "action.requested needs an action of the task" unless action

      { "contract_version" => task.contract_version, "action_kind" => action.kind,
        "action_description" => action.description }
    end

    def live_criteria(task)
      Criterion.where(task_id: task.id, removed_at: nil).order(:position).to_a
    end

    # Each live criterion's evidence as [kind, value] pairs, in the order
    # it was attached.
    def evidence_of(task)
      Evidence.where(criterion_id: Criterion.where(task_id: task.id, removed_at: nil).select(:id))
        .order(:created_at, :id).pluck(:criterion_id, :kind, :value)
        .each_with_object({}) { |(criterion_id, kind, value), pairs| (pairs[criterion_id] ||= []) << [ kind, value ] }
    end

    def required(row, hook)
      row || raise(ArgumentError, "#{hook} hashes the #{hook == "review.failed" ? "review" : "seat"} it is about")
    end

    private_class_method :ready, :criteria_states, :evidence_by_criterion, :requested, :live_criteria, :evidence_of,
      :required
  end
end
