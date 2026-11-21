module Leverage
  # A workspace's rules and their versions (PRD L342, L379, L434;
  # milestone 4 plan RD-1 to RD-7, RD-21 to RD-24, RD-45): the only writer
  # of rules and rule_versions. Writes the shipped set (Rules::Shipped),
  # adds a custom rule, saves a version, switches a rule on or off,
  # reverts a shipped rule, removes a custom one, and withdraws what a rule
  # turned off or removed has in flight (L379).
  #
  # Every save is a new immutable version (rule_versions refuses an
  # update); the rule row keeps the switch, the current version number and
  # removed_at. A rule's events have the rule as subject and no task. The
  # author of a version is the command's actor: the owner, or the app for
  # install_shipped_rules.
  #
  # The fields a command sends are checked here (RD-6, RD-21, RD-22) by
  # added_version and saved_version, which entries call in load so that a
  # field that does not fit is 422 invalid before anything is written.
  module RuleRecords
    # RD-21: the moments a custom rule may be added at in this milestone;
    # "before anything goes out" (action.requested) arrives with outward
    # actions in milestone 5.
    CUSTOM_HOOKS = (Contract.registry.fetch("custom_rule_hooks") - %w[action.requested]).freeze

    # RD-22: every task, and "let the checker decide" for a model rule.
    # Named projects and action kinds wait for milestone 5.
    SCOPES = %w[all_tasks checker_decides].freeze
    CHECKER_DECIDES = "checker_decides".freeze

    # The fields of SaveRuleRequest, all required.
    SAVE_FIELDS = %w[name instruction parameters scope on_fail route queue_timeout_seconds run_timeout_seconds].freeze
    ON_FAIL = %w[block warn].freeze
    ROUTES = Contract.list("routes").freeze

    # The holds a rule's checks open, which close when the rule is turned
    # off or removed (L162, L166, L167; state_machine.json, disable_rule
    # and remove_rule's holds_closed).
    RULE_HOLDS = %w[check_error claim_gate_failed rerun_limit].freeze
    TURN_RULE_OFF = "turn_rule_off".freeze

    # The jobs that are still waiting or running.
    LIVE_JOBS = %w[queued claimed].freeze

    module_function

    # Writes the seven shipped rules at version 1, each with rule.created
    # (create_owner, install_shipped_rules), in shipped_rules.json's order.
    # Returns the Rules.
    def install_shipped(ctx)
      Rules::Shipped.all.map do |record|
        create(ctx, key: record.key, enabled: record.enabled, columns: record.version_fields)
      end
    end

    # Adds a custom rule from fields (AddRuleRequest's): a model-checked
    # gate that blocks, keyed custom_ and its id (RD-23). Returns the Rule.
    # Raises Transitions::Invalid for fields added_version refuses.
    def add(ctx, fields)
      columns = added_version(fields)
      id = SecureRandom.uuid
      key = "custom_#{id}"
      create(ctx, id: id, key: key, enabled: true, columns: columns.merge(key: key))
    end

    # Saves fields (SaveRuleRequest's) as the rule's next version, with
    # rule.changed. The earlier versions are untouched, so a check keeps
    # the version it ran against (L911). Returns the RuleVersion. Raises
    # Transitions::Invalid for fields saved_version refuses.
    def save(ctx, rule, fields)
      write_version(ctx, rule, saved_version(rule, fields), "rule.changed")
    end

    # Turns the rule on (rule.enabled). A request already made is not
    # touched (L379, RD-3).
    def enable(ctx, rule)
      rule.update!(enabled: true, updated_at: ctx.at)
      ctx.emit("rule.enabled", subject: rule, payload: {})
      rule
    end

    # Turns the rule off (rule.disabled) and withdraws what it has in
    # flight (L379).
    def disable(ctx, rule)
      rule.update!(enabled: false, updated_at: ctx.at)
      ctx.emit("rule.disabled", subject: rule, payload: {})
      withdraw_in_flight(ctx, rule)
      rule
    end

    # Writes the shipped default as the rule's next version, with
    # rule.reverted (L342, RD-7). Shipped rules only (DB-29).
    def revert(ctx, rule)
      write_version(ctx, rule, Rules::Shipped.find(rule.key).version_fields, "rule.reverted")
    end

    # Removes a custom rule (rule.removed, DB-29) and withdraws what it has
    # in flight (L379).
    def remove(ctx, rule)
      rule.update!(removed_at: ctx.at, updated_at: ctx.at)
      ctx.emit("rule.removed", subject: rule, payload: {})
      withdraw_in_flight(ctx, rule)
      rule
    end

    # The rule's current version.
    def current_version(rule) = RuleVersion.find_by!(rule_id: rule.id, version: rule.current_version)

    # The rule's checks in flight: those with no result yet (a model check
    # queued or running, a warn rule's too, and the row held at the re-run
    # limit, which never ran, RD-45), and those that ended in error while
    # their command still waits or their check_error hold is open (L400:
    # "withdrawn because its rule was turned off"). A check the owner has
    # overridden is settled and is not among them. Oldest first.
    def in_flight(rule)
      checks = RuleCheck.where(workspace_id: rule.workspace_id, rule_id: rule.id, overridden_at: nil)
      waiting = PendingTransition.where(workspace_id: rule.workspace_id, state: "pending").select(:id)
      held = Hold.where(workspace_id: rule.workspace_id, reason: "check_error", closed_at: nil).select(:rule_check_id)
      errored = checks.where(result: "error").where(pending_transition_id: waiting).or(
        checks.where(result: "error").where(id: held))
      checks.where(result: nil).or(errored).order(:created_at, :id).to_a
    end

    # The columns of a custom rule's first version from AddRuleRequest's
    # fields (L464; RD-4, RD-21 to RD-24; DB-28, RC-7): a model gate that
    # blocks, checked by the orchestrator, its failures to the owner at
    # "ready to start" and to the builder at the other moments. Raises
    # Transitions::Invalid for a moment or a scope not offered yet, or a
    # blank name or instruction.
    def added_version(fields)
      fields = fields.to_h.stringify_keys
      name = text(fields, "name")
      instruction = text(fields, "instruction")
      hook = fields["hook"]
      unless CUSTOM_HOOKS.include?(hook)
        invalid("A rule can be added at #{CUSTOM_HOOKS.join(", ")}; #{hook.inspect} arrives in a later version")
      end

      { name: name, hook: hook, kind: "gate", checker: "model", scope_kind: scope_kind(fields, model: true),
        scope_values: [], checker_function: nil, parameters: {}, instruction: instruction,
        checker_role: "orchestrator", on_fail: "block", route: hook == "task.before_ready" ? "owner" : "builder",
        queue_timeout_seconds: nil, run_timeout_seconds: nil, origin: "custom" }
    end

    # The columns of a rule's next version from SaveRuleRequest's fields
    # (RD-6): the hook, the kind, the checker, its function and role, the
    # key and the origin stay the current version's; the rest is the
    # request's. Raises Transitions::Invalid when a field does not fit the
    # rule: a missing field; a shipped rule's name changed; an instruction
    # on an app rule or none on a model rule (the approvals rule, whose
    # instruction milestone 5 writes, may keep none); parameters that do
    # not fit the function's schema in shipped_rules.json; a scope not
    # offered (RD-22); block or warn missing on a gate or given on a policy
    # (RC-10); a route missing on a gate, given on a policy, or not one of
    # the three (RD-24); a timeout below 1.
    def saved_version(rule, fields)
      fields = fields.to_h.stringify_keys
      missing = SAVE_FIELDS - fields.keys
      invalid("Every field of the rule is sent; missing: #{missing.join(", ")}") if missing.any?

      current = current_version(rule)
      model = current.checker == "model"
      gate = current.kind == "gate"
      name = text(fields, "name")
      invalid("A shipped rule keeps its name") if current.origin == "shipped" && name != current.name

      current.attributes.symbolize_keys.slice(*Rules::Shipped::VERSION_COLUMNS).merge(
        name: name, instruction: saved_instruction(current, fields["instruction"], model),
        parameters: saved_parameters(rule, current, fields["parameters"], model),
        scope_kind: scope_kind(fields, model: model), scope_values: [],
        on_fail: gate_only(fields["on_fail"], ON_FAIL, gate, "block or warn"),
        route: gate_only(fields["route"], ROUTES, gate, "a route"),
        queue_timeout_seconds: timeout(fields["queue_timeout_seconds"]),
        run_timeout_seconds: timeout(fields["run_timeout_seconds"]))
    end

    # --- writing --------------------------------------------------------------

    def create(ctx, key:, enabled:, columns:, id: SecureRandom.uuid)
      rule = Rule.create!(id: id, workspace_id: ctx.workspace.id, key: key, enabled: enabled, current_version: 1,
        created_at: ctx.at, updated_at: ctx.at)
      version = RuleVersion.create!(workspace_id: ctx.workspace.id, rule_id: rule.id, version: 1, **columns,
        **author(ctx), created_at: ctx.at)
      ctx.emit("rule.created", subject: rule, payload: { rule_version_id: version.id, version: 1, enabled: enabled })
      rule
    end

    def write_version(ctx, rule, columns, type)
      number = rule.current_version + 1
      version = RuleVersion.create!(workspace_id: rule.workspace_id, rule_id: rule.id, version: number, **columns,
        **author(ctx), created_at: ctx.at)
      rule.update!(current_version: number, updated_at: ctx.at)
      ctx.emit(type, subject: rule, payload: { rule_version_id: version.id, version: number })
      version
    end

    def author(ctx)
      kind, id = ctx.actor
      { author_kind: kind, author_id: id }
    end

    # L379, RD-45 (state_machine.json, disable_rule and remove_rule): each
    # check in flight is withdrawn (check.finished, result withdrawn) and
    # its live job with it (job.withdrawn); the rule's check_error,
    # claim_gate_failed and rerun_limit holds close with their items
    # (turn_rule_off); then each command that waited on a withdrawn check
    # and still waits is gated again (rule 9), unless another hold is open
    # on its task, whose lifting gates it again (L378). Its completion's
    # events are its requester's (RE-3), written by PendingTransitions.
    def withdraw_in_flight(ctx, rule)
      checks = in_flight(rule)
      checks.each do |check|
        RuleChecks.withdraw(ctx, check)
        live_jobs(check).each { |job| Jobs.withdraw(ctx, job) }
      end
      rule_holds(rule, checks).each do |hold|
        Holds.close(ctx, hold: hold, task: Task.find(hold.task_id), choice: TURN_RULE_OFF)
      end
      reenter_waiting(ctx, checks)
    end

    def live_jobs(check)
      ids = RuleCheckAttempt.where(rule_check_id: check.id).where.not(job_id: nil).select(:job_id)
      Job.where(id: ids, state: LIVE_JOBS).order(:queued_at, :id).to_a
    end

    # The open holds the rule caused: named by its id, or by one of the
    # checks being withdrawn. In the order they opened.
    def rule_holds(rule, checks)
      open = Hold.where(workspace_id: rule.workspace_id, reason: RULE_HOLDS, closed_at: nil)
      open.where(rule_id: rule.id).or(open.where(rule_check_id: checks.map(&:id))).order(:opened_at, :id).to_a
    end

    def reenter_waiting(ctx, checks)
      checks.select(&:pending_transition_id).group_by(&:pending_transition_id).each do |pending_id, withdrawn|
        pending = PendingTransition.find_by(id: pending_id, state: "pending")
        next unless pending
        next if Holds.held?(Task.find(pending.task_id))

        trigger = Gating::Trigger.new(kind: :rule_switched_off, rule_check_id: withdrawn.last.id)
        PendingTransitions.reenter(ctx, pending, trigger)
      end
    end

    # --- checking fields -------------------------------------------------------

    def invalid(message) = raise(Transitions::Invalid, message)

    def text(fields, name)
      value = fields[name]
      invalid("The rule's #{name} is text") unless value.is_a?(String) && !value.strip.empty?
      value
    end

    # RD-22: every task, or "let the checker decide" for a model rule, with
    # neither project ids nor action kinds.
    def scope_kind(fields, model:)
      scope = fields["scope"]
      invalid("The rule's scope is an object") unless scope.is_a?(Hash)
      scope = scope.stringify_keys
      kind = scope["kind"]
      offered = model ? SCOPES : SCOPES - [ CHECKER_DECIDES ]
      invalid("A rule's scope is one of #{offered.join(", ")} in this version") unless offered.include?(kind)
      if Array(scope["project_ids"]).any? || Array(scope["action_kinds"]).any?
        invalid("The scope #{kind} names no projects and no action kinds")
      end

      kind
    end

    def saved_instruction(current, instruction, model)
      unless model
        return instruction.nil? ? nil : invalid("An app-checked rule has no instruction: its sentence comes from its parameters")
      end
      # The shipped approvals rule has no instruction until milestone 5
      # writes it (shipped_rules.json's placeholder); it may keep none.
      return nil if instruction.nil? && current.instruction.nil?
      unless instruction.is_a?(String) && !instruction.strip.empty?
        invalid("A model-checked rule's instruction is text")
      end

      instruction
    end

    # An app rule's parameters fit its function's schema in
    # shipped_rules.json: every parameter, each an integer at or above its
    # minimum. A model rule has none ({} or null, stored as {}).
    def saved_parameters(rule, current, parameters, model)
      if model || current.origin != "shipped"
        return {} if parameters.nil? || parameters == {}

        invalid("A model-checked rule has no parameters")
      end
      schema = Rules::Shipped.find(rule.key).parameter_schema
      parameters = {} if parameters.nil? && schema.empty?
      invalid("The rule's parameters are an object") unless parameters.is_a?(Hash)
      parameters = parameters.stringify_keys
      unless parameters.keys.sort == schema.keys.sort
        invalid("The rule's parameters are #{schema.keys.join(", ").presence || "none"}")
      end
      parameters.each do |name, value|
        field = schema.fetch(name)
        unless field.fetch("type") == "integer" && value.is_a?(Integer) && value >= field.fetch("minimum", value)
          invalid("#{name} is a whole number of at least #{field.fetch("minimum", 0)}")
        end
      end
      parameters
    end

    # on_fail and route: one of the values on a gate, none on a policy.
    def gate_only(value, values, gate, what)
      if gate
        invalid("A gate rule has #{what}: #{values.join(", ")}") unless values.include?(value)
      elsif !value.nil?
        invalid("A policy rule has no #{what}")
      end
      value
    end

    def timeout(value)
      return nil if value.nil?

      invalid("A timeout is a whole number of seconds, at least 1") unless value.is_a?(Integer) && value >= 1
      value
    end

    private_class_method :create, :write_version, :author, :withdraw_in_flight, :live_jobs, :rule_holds,
      :reenter_waiting, :invalid, :text, :scope_kind, :saved_instruction, :saved_parameters, :gate_only, :timeout
  end
end
