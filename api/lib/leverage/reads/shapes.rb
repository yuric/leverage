module Leverage
  module Reads
    # The JSON of one row, as openapi.json shapes it (milestone 2 plan MA-20,
    # IN-33, IN-35). Every owner read builds its answer from these, so a row
    # is rendered one way wherever it appears: times with microseconds (a
    # caller that passes an updated_at back must get the same instant),
    # decimal money as a number, an empty model or effort as null. Pure
    # functions of the rows they are given: no statement is run here.
    module Shapes
      module_function

      # An ISO 8601 UTC time with microseconds, or nil.
      def time(value)
        value&.utc&.iso8601(6)
      end

      # A PostgreSQL interval as whole seconds, or nil.
      def seconds(value)
        return nil if value.nil?

        value = ActiveSupport::Duration.parse(value) if value.is_a?(String)
        value.to_i
      end

      # Decimal money as a JSON number.
      def number(value)
        value&.to_f
      end

      def task_summary(task)
        row = { id: task.id, project_id: task.project_id, title: task.title.to_s, details: task.details,
          state: task.state, round: task.round, holder_seat_id: task.holder_seat_id, builder_seat_id: task.builder_seat_id,
          lease_due_at: time(task.lease_due_at), lease_time_left_while_paused: seconds(task.lease_time_left_while_paused),
          minimum_strength_rank: task.minimum_strength_rank, contract_version: task.contract_version,
          budget_cap: number(task.budget_cap), spent: number(task.spent), work_reference: task.work_reference,
          priority: task.priority }
        if task.imaginarium_entry_id
          row[:imaginarium_entry_id] = task.imaginarium_entry_id
          row[:imaginarium_catalog_version] = task.imaginarium_catalog_version
        end
        row
      end

      def criterion(criterion, evidence)
        { id: criterion.id, task_id: criterion.task_id, position: criterion.position, text: criterion.text.to_s,
          kind: criterion.kind, state: criterion.state, passed_at: time(criterion.passed_at),
          passed_by_seat_id: criterion.passed_by_seat_id, evidence: evidence.map { |row| evidence_row(row) } }
      end

      def evidence_row(evidence)
        { id: evidence.id, criterion_id: evidence.criterion_id, kind: evidence.kind, value: evidence.value.to_s }
      end

      def action(action)
        { id: action.id, task_id: action.task_id, kind: action.kind, description: action.description.to_s,
          state: action.state, approved_by_kind: action.approved_by_kind, approved_by_id: action.approved_by_id }
      end

      def question(question)
        { id: question.id, task_id: question.task_id, asking_seat_id: question.asking_seat_id, text: question.text.to_s,
          assumption: question.assumption.to_s, blocking: question.blocking, outcome: question.outcome,
          answer: question.answer, basis: question.basis, answered_by_kind: question.answered_by_kind,
          answered_by_id: question.answered_by_id }
      end

      def hold(hold)
        { id: hold.id, task_id: hold.task_id, project_id: hold.project_id, reason: hold.reason, rule_id: hold.rule_id,
          credential_id: hold.credential_id, opened_at: time(hold.opened_at), closed_at: time(hold.closed_at) }
      end

      def review(review)
        { id: review.id, task_id: review.task_id, round: review.round, reviewer_seat_id: review.reviewer_seat_id,
          lease_due_at: time(review.lease_due_at), verdict: review.verdict, failed_criteria: Array(review.failed_criteria),
          notes: review.notes }
      end

      # opened_seq is the seq of the item's inbox.opened event.
      def inbox_item(item, opened_seq)
        { id: item.id, kind: item.kind, about_kind: item.about_kind, about_id: item.about_id, hold_id: item.hold_id,
          credential_id: item.credential_id, choices: item.choices, facts: item.facts, state: item.state,
          opened_at: time(item.opened_at), opened_seq: opened_seq, resolved_by_kind: item.resolved_by_kind,
          resolved_by_id: item.resolved_by_id, resolved_at: time(item.resolved_at) }
      end

      # The event as the contract has it. Its columns xact_id and created_at
      # are the database's own and are not part of it.
      def event(event)
        { id: event.id, workspace_id: event.workspace_id, seq: event.seq, at: time(event.at),
          effective_at: time(event.effective_at), type: event.type, schema_version: event.schema_version,
          actor_kind: event.actor_kind, actor_id: event.actor_id, project_id: event.project_id, task_id: event.task_id,
          round: event.round, subject_kind: event.subject_kind, subject_id: event.subject_id, cause_id: event.cause_id,
          command_id: event.command_id, payload: event.payload }
      end

      # An empty model or effort means the tool's default: null (IN-29).
      def seat(seat)
        { id: seat.id, name: seat.name, provider: seat.provider, model: seat.model.presence, effort: seat.effort.presence,
          role: seat.role, strength_rank: seat.strength_rank, credential_id: seat.credential_id, enabled: seat.enabled,
          paused: seat.paused, last_polled_at: time(seat.last_polled_at), run_state: seat.run_state,
          removed_at: time(seat.removed_at), wanted_running: seat.wanted_running,
          run_credential_id: seat.run_credential_id, run_stop_reason: seat.run_stop_reason }
      end

      def credential(credential)
        { id: credential.id, kind: credential.kind, provider: credential.provider, name: credential.name,
          masked_label: credential.masked_label, plan: credential.plan, account_email: credential.account_email,
          state: credential.state, limited_until: time(credential.limited_until), limited_since: time(credential.limited_since),
          position: credential.position,
          model: credential.model, effort: credential.effort, strength_rank: credential.strength_rank,
          last_verified_at: time(credential.last_verified_at) }
      end

      # What the server wants done on the Mac, with each check's progress. It
      # holds no token and no credential name (IN-22, IN-23).
      def helper_request(request)
        { id: request.id, kind: request.kind, seat_id: request.seat_id, credential_id: request.credential_id,
          state: request.state, requested_at: time(request.requested_at), picked_up_at: time(request.picked_up_at),
          finished_at: time(request.finished_at), result: request.result, params: request.params,
          progress: request.progress, updated_at: time(request.updated_at) }
      end
    end
  end
end
