require "test_helper"

module Leverage
  module Rules
    # What the tests of lib/leverage/rules/ share (milestone 4 plan WP3): a
    # Scenario, the engine set as the gating, and the Gating::Request a
    # command at a hook would send, its inputs read through HookInputs as
    # Transitions::Gate reads them. Every value is made up.
    module TestSupport
      def self.included(base)
        base.setup do
          @scenario = Scenario.new
          Leverage::Gating.implementation = Leverage::Rules::Engine.new
        end
      end

      attr_reader :scenario

      # The request a command at hook sends for task. subject: the Seat or
      # Review the hook is about (the claimant at task.before_claim, the
      # reviewer at review.assign, the review at task.before_done);
      # requester: a Seat or the owner's User (default the owner).
      def request_for(task, hook, params: {}, subject: nil, requester: nil, inputs: nil, round: nil)
        requester ||= scenario.owner
        seat = subject if subject.is_a?(Seat)
        inputs ||= Leverage::HookInputs.for(hook: hook, task: task, params: params, seat: seat,
          review: (subject if subject.is_a?(Review)))
        Leverage::Gating::Request.new(workspace_id: task.workspace_id, task_id: task.id, project_id: task.project_id,
          hook: hook, round: round || task.round, subject_kind: subject && Leverage::EventLog.kind_of(subject),
          subject_id: subject&.id, requester_kind: requester.is_a?(User) ? "owner" : "seat", requester_id: requester.id,
          command_key: "made-up-key-#{SecureRandom.hex(4)}", inputs: inputs)
      end

      # The input hash of hook for task, as the request above would carry it.
      def hash_for(task, hook, params: {}, subject: nil)
        Leverage::Gating.input_hash(hook: hook, inputs: request_for(task, hook, params: params, subject: subject).inputs)
      end

      # The params of a Complete contract with criteria of the given kinds.
      def contract_params(kinds = %w[build review], goal: "A made-up goal.", details: "Made-up details.", actions: [])
        { "goal" => goal, "details" => details, "actions" => actions,
          "criteria" => kinds.each_with_index.map { |kind, index| { "text" => "Made-up criterion #{index + 1}.", "kind" => kind } } }
      end

      # A rule check marked overridden by the owner.
      def override(check, reason: "A made-up reason.")
        check.update!(overridden_by_user_id: scenario.owner.id, overridden_at: scenario.database_now, override_reason: reason)
        check
      end

      # A custom gate at hook checked by the app with checker_function.
      def app_gate(hook, function, parameters: {}, route: "owner", on_fail: "block", **fields)
        scenario.rule(hook: hook, checker: "app", checker_function: function, parameters: parameters, route: route,
          on_fail: on_fail, **fields)
      end

      # A custom model gate at hook (Scenario's default rule moved there).
      def model_gate(hook, on_fail: "block", route: "builder", **fields)
        scenario.rule(hook: hook, on_fail: on_fail, route: route, **fields)
      end

      # An outward action of task (milestone 5 makes them; the gating
      # interface plans for them already).
      def action(task, kind: "publish", description: "Publish the made-up page.", state: "contracted", position: 1)
        Action.create!(workspace_id: task.workspace_id, task_id: task.id, position: position, kind: kind,
          description: description, state: state)
      end

      # Opens a hold on task with no item, as the app.
      def open_hold(task, reason, rule: nil, check: nil)
        Hold.create!(workspace_id: task.workspace_id, task_id: task.id, reason: reason, rule_id: rule&.id,
          rule_check_id: check&.id, opened_at: scenario.database_now, opened_by_kind: "app")
      end

      def trigger(kind = :check_finished, check = nil)
        Leverage::Gating::Trigger.new(kind: kind, rule_check_id: check&.id)
      end
    end
  end
end
