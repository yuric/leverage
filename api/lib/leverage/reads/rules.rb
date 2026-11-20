module Leverage
  module Reads
    # list_rules (Settings, Rules; openapi.json RulesList; PRD L342 to L346,
    # L395, L423; milestone 4 plan §2.3, RD-8, RD-26, RD-62): every rule of
    # the workspace that is not removed, switched on or off, each with its
    # current version, the moment it runs at, its one sentence when an app
    # checks it, whether it acts in this version of leverage, and its
    # counts. One Snapshot, so the rules and their counts are one moment of
    # the log.
    #
    # Order: the shipped rules in shipped_rules.json's order, then the
    # custom rules as they were added (rules.created_at, then id).
    #
    # The counts (RuleStats, RD-26): checks are the rule's rows whose result
    # is neither not_applicable nor withdrawn, a row still running among
    # them; average_seconds is queue plus run, which is end minus queued,
    # over the finished attempts of those rows (RuleTiming's arithmetic),
    # null when none finished; tokens and spend are its jobs' results
    # (L317); overrides are its rows the owner let through.
    #
    # What a version says in one sentence and whether it acts are the rules
    # engine's (Rules::Sentences, RD-62; Rules::AppCheckers, RD-8), asked
    # through
    #
    #   words.sentence(version)  the sentence of an app-checked version
    #   words.acts?(version)     whether the version acts now
    #
    # and with_collaborators puts a double in place for a test. A model
    # rule's text is its instruction (L344), so its sentence is null and the
    # engine is not asked for one.
    module Rules
      # The rows a rule's "how often it ran" leaves out (RD-26).
      NOT_RUN = %w[not_applicable withdrawn].freeze

      # The rules engine's two answers about a version (WP3's files).
      module EngineWords
        module_function

        def sentence(version) = Leverage::Rules::Sentences.for(version)
        def acts?(version) = Leverage::Rules::AppCheckers.acts?(version)
      end

      @collaborators = {}

      class << self
        # { rules: [RuleWithVersion] }. Raises ActiveRecord::RecordNotFound
        # for an unknown workspace.
        def call(workspace_id)
          Snapshot.call(workspace_id) do |_as_of_seq|
            rules = ordered(Rule.where(workspace_id: workspace_id, removed_at: nil).to_a)
            versions = RuleVersion.where(rule_id: rules.map(&:id)).index_by { |version| [ version.rule_id, version.version ] }
            stats = stats(workspace_id, rules.map(&:id))
            { rules: rules.map { |rule| entry(rule, versions.fetch([ rule.id, rule.current_version ]), stats[rule.id]) } }
          end
        end

        # Tests only: answers what the rules engine says of a version from
        # words inside the block.
        def with_collaborators(words: nil)
          saved = @collaborators
          @collaborators = saved.merge({ words: words }.compact)
          yield
        ensure
          @collaborators = saved
        end

        # Rules in Settings' order: shipped in shipped_rules.json's order,
        # then custom by creation.
        def ordered(rules)
          shipped = Leverage::Rules::Shipped.all.map(&:key)
          rules.sort_by do |rule|
            position = shipped.index(rule.key)
            position ? [ 0, position, "", "" ] : [ 1, 0, rule.created_at.utc.iso8601(6), rule.id ]
          end
        end

        # The moment name of a hook (hooks.json), which the owner sees
        # instead of the hook (L464).
        def moment_name(hook)
          @moment_names ||= Contract.hooks.fetch("hooks").to_h { |entry| [ entry.fetch("hook"), entry.fetch("moment_name") ] }
          @moment_names.fetch(hook)
        end

        # A rule_versions row as openapi.json's RuleVersion.
        def version_shape(version)
          { id: version.id, rule_id: version.rule_id, version: version.version, key: version.key, name: version.name,
            hook: version.hook, scope: scope(version), kind: version.kind, checker: version.checker,
            on_fail: version.on_fail, route: version.route, queue_timeout_seconds: version.queue_timeout_seconds,
            run_timeout_seconds: version.run_timeout_seconds, instruction: version.instruction,
            parameters: version.parameters, origin: version.origin, author_kind: version.author_kind,
            author_id: version.author_id, created_at: Shapes.time(version.created_at) }
        end

        private

        def words = @collaborators[:words] || EngineWords

        def entry(rule, version, stats)
          { rule: { id: rule.id, key: rule.key, enabled: rule.enabled, current_version: rule.current_version },
            version: version_shape(version), sentence: (words.sentence(version) if version.checker == "app"),
            moment_name: moment_name(version.hook), acts: words.acts?(version),
            stats: stats || { checks: 0, average_seconds: nil, tokens: 0, spend: 0.0, overrides: 0 } }
        end

        # RuleScope: project_ids for named_projects, action_kinds for
        # action_kinds, neither for the other kinds.
        def scope(version)
          values = Array(version.scope_values)
          { kind: version.scope_kind, project_ids: (values if version.scope_kind == "named_projects"),
            action_kinds: (values if version.scope_kind == "action_kinds") }
        end

        # rule id => RuleStats for the rules that have a check.
        def stats(workspace_id, rule_ids)
          checks = RuleCheck.where(workspace_id: workspace_id, rule_id: rule_ids).to_a
          attempts = RuleTiming.attempts(checks.map(&:id))
          checks.group_by(&:rule_id).transform_values do |rows|
            ran = rows.reject { |check| NOT_RUN.include?(check.result) }
            finished = ran.flat_map { |check| attempts.fetch(check.id, []) }.filter_map do |attempt|
              RuleTiming.span(attempt.queued_at, attempt.ended_at)
            end
            jobs = rows.flat_map { |check| attempts.fetch(check.id, []) }
            { checks: ran.size, average_seconds: (RuleTiming.number(finished.sum(0r) / finished.size) if finished.any?),
              tokens: jobs.sum { |attempt| attempt.tokens.to_i }, spend: RuleTiming.number(jobs.sum(0r) { |attempt| attempt.spend.to_r }),
              overrides: rows.count(&:overridden_at) }
          end
        end
      end
    end
  end
end
