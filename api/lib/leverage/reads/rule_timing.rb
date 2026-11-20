module Leverage
  module Reads
    # The timing questions of PRD L315 to L318, per rule (milestone 4 plan
    # §2.1, RD-26): how long each rule takes to check, how long it held
    # tasks up, what it cost in tokens and spend, and how often it applied,
    # stopped something or was overridden. Read-only queries (L323), printed
    # by leverage:rule_timing; Settings, Rules shows a few of them through
    # Reads::Rules, which takes its attempt arithmetic from here.
    #
    # An attempt's times (L315): queue time is started minus queued, run
    # time is finished minus started. An attempt that never started waited
    # in the queue until it ended: its own finished time, or its job's when
    # the job timed out or was withdrawn (DB-31: one job per attempt). With
    # as_of, an interval still open is measured to it (L322); without, it
    # has no length yet.
    #
    # How long a rule held tasks up (L316), in seconds:
    #
    # - each of its checks that blocked a transition (a blocking gate's row
    #   with a pending transition), from its first attempt's queued time to
    #   its last attempt's end, less the part of that interval its task
    #   spent in a wait_owner step; when one transition waited on several
    #   checks, only the check that ended last is credited (its check step
    #   is that check's);
    # - the wait_owner steps of a hold that a failed or errored check of
    #   the rule opened: contract_incomplete, claim_gate_failed and
    #   check_error, each naming the rule or a check of it;
    # - the wait_review steps that name the rule as their cause (RD-11).
    #
    # Tokens and spend are its jobs' results (L317). Its rows are counted
    # by result, a row with none yet as "unfinished" (L318), and its
    # overrides by overridden_at. A removed rule is answered too: its checks
    # still ran. Ids and figures only: no rule text, which is the owner's.
    module RuleTiming
      # One attempt with the end of its job. ended_at is the attempt's
      # finished time, or its job's.
      Attempt = Data.define(:rule_check_id, :attempt_number, :queued_at, :started_at, :ended_at, :tokens, :spend)

      # The holds a failed or errored check opens (Holds table, L162 to
      # L167).
      CHECK_HOLDS = %w[contract_incomplete check_error claim_gate_failed].freeze

      module_function

      # One Hash per rule (string keys), in Settings' order (Rules.ordered).
      # rule_id: - one rule's answer, or nil for every rule's.
      # as_of:   - the time open intervals are measured to; nil is the
      #            database's clock. Raises ActiveRecord::RecordNotFound for
      #            an unknown workspace.
      def call(workspace_id, rule_id: nil, as_of: nil)
        Snapshot.call(workspace_id) do |_as_of_seq|
          as_of ||= database_now
          scope = Rule.where(workspace_id: workspace_id)
          scope = scope.where(id: rule_id) if rule_id
          rules = Rules.ordered(scope.to_a)
          checks = RuleCheck.where(workspace_id: workspace_id, rule_id: rules.map(&:id)).order(:created_at, :id).to_a
          attempts = attempts(checks.map(&:id))
          held = held_up(workspace_id, rules.map(&:id), checks, attempts, as_of)
          by_rule = checks.group_by(&:rule_id)
          rules.map { |rule| row(rule, by_rule.fetch(rule.id, []), attempts, held.fetch(rule.id, 0r), as_of) }
        end
      end

      # The attempts of the checks, rule_check_id => [Attempt] in attempt
      # order.
      def attempts(check_ids)
        RuleCheckAttempt.where(rule_check_id: check_ids).joins("LEFT JOIN jobs ON jobs.id = rule_check_attempts.job_id")
          .order(:rule_check_id, :attempt_number)
          .pluck(:rule_check_id, :attempt_number, :queued_at, :started_at, Arel.sql("COALESCE(rule_check_attempts.finished_at, jobs.finished_at)"),
            Arel.sql("jobs.tokens"), Arel.sql("jobs.spend"))
          .map { |values| Attempt.new(*values) }
          .group_by(&:rule_check_id)
      end

      # Queue seconds of an attempt: started minus queued, or its end
      # minus queued when it never started; to as_of while it waits; nil
      # with no as_of.
      def queue_seconds(attempt, as_of = nil)
        span(attempt.queued_at, attempt.started_at || attempt.ended_at || as_of)
      end

      # Run seconds of an attempt: its end minus started; to as_of while it
      # runs; nil when it never started, or with no as_of.
      def run_seconds(attempt, as_of = nil)
        attempt.started_at && span(attempt.started_at, attempt.ended_at || as_of)
      end

      # Seconds between two times as an exact Rational, never negative;
      # nil when either is missing.
      def span(from, to)
        from && to && [ to.to_r - from.to_r, 0 ].max
      end

      def number(value) = value&.round(6)&.to_f

      def row(rule, checks, attempts, held, as_of)
        mine = checks.flat_map { |check| attempts.fetch(check.id, []) }
        queues = mine.filter_map { |attempt| queue_seconds(attempt, as_of) }
        runs = mine.filter_map { |attempt| run_seconds(attempt, as_of) }
        { "rule_id" => rule.id, "key" => rule.key, "removed" => !rule.removed_at.nil?, "attempts" => mine.size,
          "queue_seconds" => number(queues.sum(0r)), "run_seconds" => number(runs.sum(0r)),
          "average_queue_seconds" => (number(queues.sum(0r) / queues.size) if queues.any?),
          "average_run_seconds" => (number(runs.sum(0r) / runs.size) if runs.any?),
          "held_up_seconds" => number(held), "tokens" => mine.sum { |attempt| attempt.tokens.to_i },
          "spend" => number(mine.sum(0r) { |attempt| attempt.spend.to_r }),
          "results" => checks.group_by { |check| check.result || "unfinished" }.transform_values(&:size),
          "overrides" => checks.count(&:overridden_at) }
      end

      # rule_id => Rational seconds the rule held tasks up (L316).
      def held_up(workspace_id, rule_ids, checks, attempts, as_of)
        held = Hash.new(0r)
        blocked_checks(checks, attempts, as_of).each do |check, (from, to)|
          held[check.rule_id] += to - from - owner_wait(check.task_id, from, to, as_of)
        end
        hold_rules = hold_rules(workspace_id, rule_ids, checks)
        TaskStep.where(workspace_id: workspace_id, kind: "wait_owner", subject_kind: "hold", subject_id: hold_rules.keys)
          .each { |step| held[hold_rules.fetch(step.subject_id)] += step_seconds(step, as_of) }
        TaskStep.where(workspace_id: workspace_id, kind: "wait_review", cause_kind: "rule", cause_rule_id: rule_ids)
          .each { |step| held[step.cause_rule_id] += step_seconds(step, as_of) }
        held
      end

      # The checks credited with blocking a transition, each with its
      # interval [first queued, last end or as_of] as Rationals: per
      # transition, the blocking check that ended last.
      def blocked_checks(checks, attempts, as_of)
        versions = RuleVersion.where(id: checks.map(&:rule_version_id).uniq).index_by(&:id)
        blocking = checks.select do |check|
          version = versions.fetch(check.rule_version_id)
          check.pending_transition_id && version.kind == "gate" && version.on_fail == "block"
        end
        intervals = blocking.to_h { |check| [ check, interval(check, attempts.fetch(check.id, []), as_of) ] }
        blocking.group_by(&:pending_transition_id).values.to_h do |group|
          last = group.max_by { |check| [ intervals.fetch(check).last, check.created_at, check.id ] }
          [ last, intervals.fetch(last) ]
        end
      end

      def interval(check, list, as_of)
        from = (list.first&.queued_at || check.created_at).to_r
        [ from, [ (list.last&.ended_at || as_of).to_r, from ].max ]
      end

      # The part of [from, to] the task spent in wait_owner steps.
      def owner_wait(task_id, from, to, as_of)
        TaskStep.where(task_id: task_id, kind: "wait_owner").sum(0r) do |step|
          start = [ step.opened_at.to_r, from ].max
          stop = [ (step.closed_at || as_of).to_r, to ].min
          [ stop - start, 0 ].max
        end
      end

      # hold id => rule id, for the holds a failed or errored check of one
      # of these rules opened: the hold names the rule, or a check of it.
      def hold_rules(workspace_id, rule_ids, checks)
        check_rules = checks.to_h { |check| [ check.id, check.rule_id ] }
        Hold.where(workspace_id: workspace_id, reason: CHECK_HOLDS).pluck(:id, :rule_id, :rule_check_id)
          .filter_map do |id, rule_id, rule_check_id|
            rule = rule_id || check_rules[rule_check_id]
            [ id, rule ] if rule && rule_ids.include?(rule)
          end.to_h
      end

      def step_seconds(step, as_of) = span(step.opened_at, step.closed_at || as_of)

      def database_now = ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
    end
  end
end
