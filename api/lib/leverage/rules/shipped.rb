module Leverage
  module Rules
    # The seven shipped rules (PRD, Shipped rules, L434, L342; milestone 4
    # plan §2.1): each as the version fields a workspace's records are
    # written with, read once from shipped_rules.json. create_owner and
    # install_shipped_rules write them as version 1 (RuleRecords), and
    # Revert to default writes them as a new version.
    #
    # A version's parameters are the defaults of the file's parameter
    # schemas ({"minimum_count" => 1}); the schemas are parameter_schema.
    # A model rule whose instruction is still a placeholder
    # ({"to_be_written_in": ...}) has no instruction yet: nil.
    module Shipped
      # The rule_versions columns a shipped record fills.
      VERSION_COLUMNS = %i[key name hook kind checker scope_kind scope_values checker_function parameters instruction
                           checker_role on_fail route queue_timeout_seconds run_timeout_seconds origin].freeze

      # One shipped rule. enabled and version are what it ships with.
      Record = Data.define(:key, :name, :hook, :kind, :checker, :scope_kind, :scope_values, :checker_function,
                           :parameters, :parameter_schema, :instruction, :superseded_instructions, :checker_role, :on_fail, :route,
                           :queue_timeout_seconds, :run_timeout_seconds, :origin, :enabled, :version) do
        # The columns of a rule_versions row written from it, symbol keys.
        def version_fields = VERSION_COLUMNS.to_h { |column| [ column, public_send(column) ] }

        def superseded_version?(version)
          fields = VERSION_COLUMNS - [ :instruction ]
          superseded_instructions.include?(version.instruction) &&
            version.attributes.symbolize_keys.slice(*fields) == version_fields.slice(*fields)
        end
      end

      module_function

      # The seven, in shipped_rules.json's order.
      def all
        @all ||= Contract.shipped_rules.fetch("rules").map { |rule| record(rule) }.freeze
      end

      # The record of a shipped key. Raises KeyError for any other key.
      def find(key)
        all.find { |record| record.key == key.to_s } || raise(KeyError, "#{key.inspect} is not a shipped rule")
      end

      def record(rule)
        schema = rule.fetch("parameters")
        instruction = rule.fetch("instruction")
        Record.new(key: rule.fetch("key"), name: rule.fetch("name"), hook: rule.fetch("hook"), kind: rule.fetch("kind"),
          checker: rule.fetch("checker"), scope_kind: rule.dig("scope", "kind"), scope_values: rule.dig("scope", "values"),
          checker_function: rule.fetch("checker_function"),
          parameters: schema.transform_values { |parameter| parameter.fetch("default") }.freeze, parameter_schema: schema,
          instruction: instruction.is_a?(String) ? instruction : nil,
          superseded_instructions: rule.fetch("superseded_instructions", []).freeze, checker_role: rule.fetch("checker_role"),
          on_fail: rule.fetch("on_fail"), route: rule.fetch("route"),
          queue_timeout_seconds: rule.fetch("queue_timeout_seconds"), run_timeout_seconds: rule.fetch("run_timeout_seconds"),
          origin: rule.fetch("origin"), enabled: rule.fetch("enabled"), version: rule.fetch("version"))
      end

      private_class_method :record
    end
  end
end
