require_relative "entries/call_spy"

# What WP4's tests share (milestone 4 plan §4, WP4): the gate is tested
# against Gating::StandIn worlds; Jobs is WP6's, brought into the
# worktree before the code was finished.
#
# - gating(rules): sets Leverage::Gating.implementation to a RowGating
#   with a StandIn rule list built from Rule rows (each rule's current
#   version), so the rows the gate writes name real rules. reenter reads
#   the pending transition's checks from their rows.
# - with_jobs { }: records the calls of Jobs.queue and Jobs.withdraw
#   (WP6's) in @job_calls, as [name, keywords with job: the positional
#   job], and runs them.
# - command(...): one command through Transitions.apply.
module GateSupport
  include CallSpy

  T = Leverage::Transitions

  # A StandIn whose reenter reads the transition's checks from the rows,
  # so the test needs no second world.
  class RowGating < Leverage::Gating::StandIn
    attr_accessor :changed, :held

    def initialize(rules: [], **world)
      super
      @reasons = rules.to_h { |rule| [ rule[:id], rule[:reason] ] }.compact
    end

    # The StandIn's plan, with a rule's made-up reason (rule[:reason]) on
    # its row and its failure, as a checker gives one.
    def evaluate(request)
      planned = super
      planned.with(checks: planned.checks.map { |check| check.with(reason: @reasons[check.rule_id]) },
        failures: planned.failures.map { |failure| failure.with(reason: @reasons[failure.rule_id]) })
    end

    def reenter(pending_transition_id:, trigger:)
      pending = PendingTransition.find(pending_transition_id)
      checks = RuleCheck.where(pending_transition_id: pending.id).order(:created_at).map do |check|
        { id: check.id, rule_id: check.rule_id, result: check.result, overridden: !check.overridden_at.nil? }
      end
      @transitions[pending.id] = { task_id: pending.task_id, held: held, inputs_changed: changed, checks: checks }
      super
    end
  end

  # rules: [[Rule, overrides]] or Rules; each becomes a StandIn rule from
  # its current version (kind, checker, on_fail, route), "covers" scope.
  def gating(*rules)
    world = rules.map do |rule, overrides|
      version = @scenario.current_version(rule)
      { id: rule.id, version_id: version.id, version: version.version, hook: version.hook, kind: version.kind,
        checker: version.checker, on_fail: version.on_fail, route: version.route || "builder", enabled: rule.enabled,
        scope: "covers" }.merge(overrides || {})
    end
    Leverage::Gating.implementation = RowGating.new(rules: world)
  end

  # A custom rule at hook: a blocking model gate unless fields say.
  def custom_rule(hook, **fields)
    @scenario.rule(hook: hook, **fields)
  end

  # An app gate (it has a function, so a StandIn app_result decides).
  def app_rule(hook, **fields)
    @scenario.rule(hook: hook, checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => 1 }, **fields)
  end

  def with_jobs
    @job_calls = []
    calls = @job_calls
    jobs = Leverage::Jobs
    saved = %i[queue withdraw].to_h { |name| [ name, jobs.method(name) ] }
    saved.each do |name, original|
      jobs.define_singleton_method(name) do |*arguments, **keywords|
        calls << [ name, keywords.merge(job: arguments[1]) ]
        original.call(*arguments, **keywords)
      end
    end
    yield
  ensure
    saved&.each { |name, method| jobs.define_singleton_method(name, method) }
  end

  def command(name, caller, params = {}, key: "key-#{SecureRandom.hex(6)}")
    @key = key
    T.apply(T::Request.new(command: name, workspace_id: @scenario.workspace_id, caller_kind: caller.is_a?(Seat) ? "seat" : "owner",
      caller_id: caller.id, key: key, request_hash: "hash-#{key}", params: params))
  end

  # The model's rows of this test's workspace: a committing test of the
  # same worker leaves rows of its own in the tables.
  def mine(model) = model.where(workspace_id: @scenario.workspace_id)

  # The events a key wrote, in order.
  def written(key = @key)
    Event.where(workspace_id: @scenario.workspace_id, command_id: key).order(:seq).to_a
  end

  def types(key = @key) = written(key).map(&:type)

  # A Complete contract body for task.
  def contract_params(task, details: "Made-up details.")
    { "id" => task.id, "title" => task.title, "details" => details,
      "criteria" => [ { "text" => "Made-up build criterion.", "kind" => "build" },
                      { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }
  end

  # A Working task held by builder, its briefing acknowledged and every
  # build criterion passed with evidence: ready to submit.
  def ready_to_submit(builder)
    task = @scenario.task(state: "working", builder: builder)
    command("acknowledge_briefing", builder, { "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: builder) })
    Criterion.where(task_id: task.id, kind: "build").each do |criterion|
      command("pass_criterion", builder, { "id" => task.id, "cid" => criterion.id,
        "evidence" => { "kind" => "link", "value" => "https://example.test/made-up-proof" } })
    end
    task.reload
  end

  def submit_params(task, note: "A made-up handoff note.")
    { "id" => task.id, "handoff_note" => note, "work_reference" => nil }
  end

  # An In review task with its review claimed by reviewer and the review
  # briefing acknowledged: ready for a verdict.
  def ready_for_verdict(builder, reviewer)
    task = @scenario.task(state: "in_review", builder: builder)
    review = @scenario.review(task, reviewer: reviewer)
    command("acknowledge_review_briefing", reviewer, { "id" => review.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: reviewer, review: review) })
    [ task.reload, review.reload ]
  end

  def pass_params(review)
    { "id" => review.id, "verdict" => "passed", "failed_criteria" => [], "notes" => "Made-up notes.", "tokens" => 10,
      "spend" => 0 }
  end
end
