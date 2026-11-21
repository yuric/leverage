module Leverage
  module Rules
    # Steps 2 to 5 of How a transition is gated for one request (PRD
    # L362-L366, L408-L423; milestone 4 plan §2.1 rules 1 to 8): the
    # Evaluation Transitions::Gate writes. It reads and plans; it never
    # writes.
    #
    # For each rule of the frozen set (Catalog), in Catalog's order:
    #
    #   1. A stored result for the same identity is used first
    #      (StoredResults): passed, not applicable or overridden plans
    #      nothing; failed is a failure that names the stored row; a
    #      policy's applied row gives its effect again; an error or a
    #      withdrawn check is run again as a new attempt of the same row; a
    #      row still running plans nothing more (under a blocking rule the
    #      request waits on it).
    #   2. A fixed scope that does not cover the task gets a not_applicable
    #      row and nothing else (L364); a policy that writes a row only when
    #      it changes the outcome gets none (RC-15).
    #   3. An app checker runs in the request: its row has its result and
    #      reason (DB-30). A failed gate is a failure routed by the rule
    #      (block) or a warning (warn); at task.before_claim the seat that
    #      makes the third distinct failing seat plans claim_gate_failed
    #      (SM-19). An app policy plans an applied row with its effect when
    #      it has one.
    #   4. A model checker plans a row with no result and one job for the
    #      rule's checker role (rule_check, or approval for a policy). A
    #      blocking gate makes the outcome pending (L366); a warn gate does
    #      not (RC-16). The run on a fourth distinct input plans the row
    #      with no job and a rerun_limit hold naming it, and waits (RD-45).
    #      A stored row met again is counted the same way: a retry of an
    #      input already run passes (RerunLimit.reached?), but a row held
    #      at the limit and then withdrawn never ran, and is held again.
    #
    # At action.requested the gates come first, and the approval policy is
    # planned only once every gate has a result and none failed; while a
    # gate runs it is returned in deferred_rule_ids, and after a failed
    # gate it is left out (L138). A hold's rule_check_id, like a failure's
    # rule_check_ref, is an index into the evaluation's checks for a check
    # planned here, or a rule_checks id for a stored one.
    class EvaluationBuilder
      ACTION_HOOK = "action.requested".freeze
      CLAIM_HOOK = "task.before_claim".freeze

      # Returns a Gating::Evaluation.
      def self.call(request) = new(request).call

      # The policies at the request's hook, planned on their own: what
      # reenter_action plans once an action's gates have cleared.
      #
      # Returns [checks, jobs, effects].
      def self.policies(request) = new(request).policies

      def initialize(request)
        @request = request
        @checks = []
        @jobs = []
        @failures = []
        @warnings = []
        @effects = []
        @holds = []
        @pending = false
      end

      def call
        hook!
        entries = Catalog.at(@request.workspace_id, @request.hook)
        deferred = []
        unless entries.empty?
          prepare
          if @request.hook == ACTION_HOOK
            gates, policies = entries.partition { |entry| entry.version.kind == "gate" }
            gates.each { |entry| plan_rule(entry) }
            if @failures.empty? && @pending
              deferred = policies.filter_map { |entry| entry.rule.id if covered?(entry.version) }
            elsif @failures.empty?
              policies.each { |entry| plan_rule(entry) }
            end
          else
            entries.each { |entry| plan_rule(entry) }
          end
        end
        Gating::Evaluation.new(outcome: @pending ? :pending : :completed,
          frozen_rule_version_ids: entries.map { |entry| entry.version.id }, checks: @checks, jobs: @jobs,
          failures: @failures, warnings: @warnings, effects: @effects, holds_to_open: @holds, deferred_rule_ids: deferred)
      end

      def policies
        hook!
        entries = Catalog.at(@request.workspace_id, @request.hook).select { |entry| entry.version.kind == "policy" }
        prepare unless entries.empty?
        entries.each { |entry| plan_rule(entry) }
        [ @checks, @jobs, @effects ]
      end

      private

      def hook!
        return if Contract.registry.fetch("hooks").include?(@request.hook)

        raise ArgumentError, "unknown hook #{@request.hook.inspect}"
      end

      # Hashes the inputs (raising for inputs that are not the hook's) and
      # finds the task, once, for a request that meets a rule.
      def prepare
        @input_hash = Gating.input_hash(hook: @request.hook, inputs: @request.inputs)
        @task = @request.task_id && Task.find_by(workspace_id: @request.workspace_id, id: @request.task_id)
      end

      def plan_rule(entry)
        row = StoredResults.find(**identity(entry.version))
        case StoredResults.use(row)
        when :passed, :cleared then nil
        when :applied then @effects << effect(entry, row.effect) if row.effect
        when :failed then fail!(entry, row.id, row.reason)
        when :running then @pending ||= blocking?(entry.version)
        else fresh(entry)
        end
      end

      def fresh(entry)
        version = entry.version
        if !covered?(version)
          plan(entry, result: "not_applicable") unless quiet_policy?(version)
        elsif version.checker == "model"
          plan_model(entry)
        elsif version.kind == "policy"
          plan_app_policy(entry)
        else
          plan_app_gate(entry)
        end
      end

      def covered?(version) = Scope.covers?(version, @task, @request.inputs)

      def plan_model(entry)
        version = entry.version
        if blocking?(version) && rerun_limit?(entry)
          ref = plan(entry, result: nil)
          @holds << Gating::PlannedHold.new(reason: "rerun_limit", rule_id: entry.rule.id, rule_check_id: ref)
          @pending = true
          return
        end

        ref = plan(entry, result: nil)
        @jobs << Gating::PlannedJob.new(kind: version.kind == "policy" ? "approval" : "rule_check", rule_check_ref: ref,
          seat_role: version.checker_role || "orchestrator")
        @pending ||= blocking?(version)
      end

      def plan_app_gate(entry)
        version = entry.version
        answer = AppCheckers.check(version, request: @request, task: @task)
        ref = plan(entry, result: answer.result, reason: answer.reason)
        return unless answer.result == "failed"

        fail!(entry, ref, answer.reason)
        return unless blocking?(version) && @request.hook == CLAIM_HOOK && @task
        return unless ClaimGate.reached?(@task, entry.rule.id, @request.subject_id)

        @holds << Gating::PlannedHold.new(reason: "claim_gate_failed", rule_id: entry.rule.id, rule_check_id: ref)
      end

      def plan_app_policy(entry)
        answer = AppCheckers.check(entry.version, request: @request, task: @task)
        effects = Array(answer.effect)
        return if effects.empty? && quiet_policy?(entry.version)

        # One check is recorded per rule and report. The plan can apply
        # both budget effects, with the project pause first on the row.
        plan(entry, result: "applied", effect: effects.first, reason: answer.reason)
        effects.each { |value| @effects << effect(entry, value) }
      end

      # Adds a planned row and returns its index.
      def plan(entry, result:, effect: nil, reason: nil)
        @checks << Gating::PlannedCheck.new(rule_id: entry.rule.id, rule_version_id: entry.version.id,
          hook: @request.hook, round: @request.round, subject_kind: @request.subject_kind, subject_id: @request.subject_id,
          input_hash: @input_hash, checker: entry.version.checker, result: result, effect: effect, reason: reason)
        @checks.size - 1
      end

      def fail!(entry, ref, reason)
        failure = Gating::Failure.new(rule_id: entry.rule.id, rule_check_ref: ref, reason: reason,
          route: self.class.route(entry.version))
        (blocking?(entry.version) ? @failures : @warnings) << failure
      end

      def effect(entry, value)
        Gating::Effect.new(rule_id: entry.rule.id, hook: @request.hook, effect: value)
      end

      def rerun_limit?(entry)
        return false unless @task

        RerunLimit.reached?(task: @task, rule_id: entry.rule.id, hook: @request.hook, round: @request.round,
          subject_kind: @request.subject_kind, subject_id: @request.subject_id, input_hash: @input_hash,
          owner_request: @request.requester_kind == "owner")
      end

      def identity(version)
        { task_id: @request.task_id, rule_version_id: version.id, hook: @request.hook, round: @request.round,
          subject_kind: @request.subject_kind, subject_id: @request.subject_id, input_hash: @input_hash }
      end

      def blocking?(version) = self.class.blocking?(version)

      # A policy whose hook writes a row only when it changes the outcome
      # (PRD L368, RC-15).
      def quiet_policy?(version)
        return false unless version.kind == "policy"

        Contract.hooks.fetch("hooks").find { |hook| hook["hook"] == version.hook }.fetch("policy_row") ==
          "when_it_changes_the_outcome"
      end

      class << self
        # A gate that blocks the transition when it fails or cannot run.
        def blocking?(version)
          version.kind == "gate" && version.on_fail != "warn"
        end

        # Who receives a failure: the rule's route, or, for a rule that
        # names none, the owner while no seat holds the task (ready to start,
        # an outward action) and the builder at the other moments (L464,
        # RD-24, RC-48).
        def route(version) = version.route || default_route(version.hook)

        def default_route(hook)
          %w[task.before_ready action.requested].include?(hook) ? "owner" : "builder"
        end
      end
    end
  end
end
