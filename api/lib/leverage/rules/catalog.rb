module Leverage
  module Rules
    # The rules bound to a hook (PRD L363; milestone 4 plan §2.1 rule 2,
    # RD-8): every enabled, not removed rule whose current version is at
    # the hook and whose checker can run, each with that version. The order
    # is fixed: shipped rules in shipped_rules.json's order, then custom
    # rules in the order their rule.created was written (rules.created_at is
    # the transaction's start, which two rules added in one transaction
    # share). This is the set a request freezes, and the order failures are
    # reported in. It reads only.
    module Catalog
      # A rule and the version a request uses.
      Entry = Data.define(:rule, :version)

      module_function

      # The set a request at hook freezes.
      #
      # Returns an Array of Entry.
      def at(workspace_id, hook)
        enabled(workspace_id).select { |entry| entry.version.hook == hook && AppCheckers.runs?(entry.version) }
      end

      # Every enabled, not removed rule of the workspace with its current
      # version, whatever its hook, in the fixed order.
      #
      # Returns an Array of Entry.
      def enabled(workspace_id)
        rules = Rule.where(workspace_id: workspace_id, enabled: true, removed_at: nil).to_a
        versions = RuleVersion.where(rule_id: rules.map(&:id)).index_by { |version| [ version.rule_id, version.version ] }
        ordered(rules.filter_map do |rule|
          version = versions[[ rule.id, rule.current_version ]]
          Entry.new(rule: rule, version: version) if version
        end)
      end

      # The blocking gates enabled when the action was requested. A later
      # enable or save cannot replace their frozen versions.
      def action_gate_ids(event)
        rules = {}
        versions = {}
        kinds = %w[rule.created rule.changed rule.reverted rule.enabled rule.disabled rule.removed]
        Event.where(workspace_id: event.workspace_id, type: kinds).where("seq < ?", event.seq)
          .order(:seq).pluck(:type, :subject_id, :payload).each do |type, id, payload|
          versions[id] = payload["rule_version_id"] if payload.key?("rule_version_id")
          case type
          when "rule.created" then rules[id] = payload.fetch("enabled")
          when "rule.enabled" then rules[id] = true
          when "rule.disabled", "rule.removed" then rules[id] = false
          end
        end
        ids = rules.filter_map { |id, enabled| versions[id] if enabled }
        RuleVersion.where(workspace_id: event.workspace_id, id: ids, hook: "action.requested").filter_map do |version|
          version.id if AppCheckers.runs?(version) && EvaluationBuilder.blocking?(version)
        end
      end

      # The approval policies frozen when the action was requested.
      # Saving a rule leaves that version in place. Turning a rule on again
      # after the request leaves it out of the existing action.
      def action_policies(event)
        ids = at(event.workspace_id, "action.requested").filter_map do |entry|
          next unless entry.version.kind == "policy"

          events = Event.where(workspace_id: event.workspace_id, subject_kind: "rule", subject_id: entry.rule.id)
          last_switch = events.where(type: %w[rule.created rule.enabled rule.disabled]).order(seq: :desc).pick(:seq)
          next unless last_switch && last_switch < event.seq

          events.where(type: %w[rule.created rule.changed rule.reverted]).where("seq < ?", event.seq)
            .order(seq: :desc).pick(:payload)&.fetch("rule_version_id")
        end
        versions(ids)
      end

      # The versions with these ids, each with its rule as it is now (which
      # may be switched off or removed since), in the order given: what a
      # pending transition froze.
      #
      # Returns an Array of Entry.
      def versions(ids)
        versions = RuleVersion.where(id: ids).index_by(&:id)
        rules = Rule.where(id: versions.values.map(&:rule_id)).index_by(&:id)
        ids.filter_map do |id|
          version = versions[id]
          Entry.new(rule: rules.fetch(version.rule_id), version: version) if version
        end
      end

      def ordered(entries)
        return entries if entries.empty?

        shipped = Shipped.all.map(&:key)
        created = Event.where(workspace_id: entries.first.rule.workspace_id, type: "rule.created",
          subject_id: entries.map { |entry| entry.rule.id }).pluck(:subject_id, :seq).to_h
        entries.sort_by do |entry|
          rule = entry.rule
          position = shipped.index(rule.key)
          position ? [ 0, position, 0, "" ] : [ 1, created.fetch(rule.id, 0), rule.created_at.to_f, rule.id ]
        end
      end

      private_class_method :ordered
    end
  end
end
