require_relative "handoff_support"
require_relative "call_spy"

# What the tests of the job entries and of Jobs share (milestone 4 plan
# WP6): a seat's request through the real pipeline, the two job roles with
# a login, a model check waiting on its job, and the seams of other
# packages this package only calls (RuleChecks, PendingTransitions,
# Transitions.run_as: WP4's), each spied on or answered for the block. A
# test holds that it called a seam with the right arguments, not what the
# finished seam does (milestone 4 plan §4, Shared run rules). Every value is
# made up.
module JobsSupport
  include HandoffSupport
  include CallSpy

  # A Request as the agent controllers build it: params is the checked body
  # plus the path's id.
  def seat_request(seat, command, params = {}, key: new_key)
    request(command, params, key: key, caller_kind: "seat", caller_id: seat.id, scenario: scenario)
  end

  def seat_command(seat, command, params = {}, key: new_key) = T.apply(seat_request(seat, command, params, key: key))

  def claim_job(seat, key: new_key) = seat_command(seat, "claim_job", {}, key: key)

  # The body of POST /v1/jobs/{id}/result plus the path's id.
  def result_params(job, result, tokens: 400, spend: 0)
    { "id" => job.id, "result" => result, "tokens" => tokens, "spend" => spend }
  end

  def submit_result(seat, job, result, key: new_key, **options)
    seat_command(seat, "submit_job_result", result_params(job, result, **options), key: key)
  end

  # A model rule at hook, on: blocking (the default) or warn; scope
  # all_tasks unless named.
  def model_rule(hook: "task.before_ready", on_fail: "block", scope_kind: "all_tasks", **fields)
    scenario.rule(name: "Made-up model rule", hook: hook, on_fail: on_fail, scope_kind: scope_kind, **fields)
  end

  # The request a Complete contract sends (CompleteContractRequest).
  def contract_body(goal: "Made-up goal.", details: "Made-up details.", criteria: nil)
    { "title" => "A made-up task", "goal" => goal, "details" => details,
      "criteria" => criteria || [ { "text" => "Made-up build criterion.", "kind" => "build" },
                                  { "text" => "A reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }
  end

  # A Backlog task whose Complete contract waits on rule's model check, as
  # trace 16 command 2 leaves it: the pending transition with the owner's
  # request, and the check with its first attempt's job queued. Returns
  # [task, pending, check].
  def waiting_contract(rule, task: nil, body: contract_body)
    task ||= scenario.task(state: "backlog", criteria: [])
    pending = scenario.pending_transition(task, command: "complete_contract", requester: scenario.owner,
      params: body.merge("id" => task.id), frozen_rule_version_ids: [ scenario.current_version(rule).id ])
    check = scenario.rule_check(task, rule: rule, pending: pending)
    [ task, pending, check ]
  end

  # The job that runs the latest attempt of check.
  def job_of(check)
    attempt = RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last
    Job.find(attempt.job_id)
  end

  # Replaces mod.name for the block with one that records each call and
  # answers what impl answers (nil without impl). Returns the calls.
  def answering(mod, name, impl = nil)
    calls = []
    original = mod.method(name)
    mod.define_singleton_method(name) do |*arguments, **keywords, &block|
      calls << CallSpy::Call.new(arguments: arguments, keywords: keywords)
      impl&.call(*arguments, **keywords, &block)
    end
    yield
    calls
  ensure
    mod.define_singleton_method(name, original) if original
  end

  # RuleChecks.start as WP4 writes it would, for a test that needs the
  # attempt's started time (Timers.job_due_at reads it): the attempt the
  # job runs starts at ctx.at with the seat.
  def starting_attempts(&block)
    start = lambda do |ctx, _check, job:, seat:|
      RuleCheckAttempt.where(job_id: job.id).update_all(started_at: ctx.at, checker_seat_id: seat.id)
      nil
    end
    answering(Leverage::RuleChecks, :start, start, &block)
  end

  # The event types written in the block, with the seq order kept.
  def types(events) = events.map(&:type)
end
