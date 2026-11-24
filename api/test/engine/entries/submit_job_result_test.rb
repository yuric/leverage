require "test_helper"
require_relative "jobs_support"

# submit_job_result (PRD L399, L428, L512, L514, L539; milestone 4 plan
# RE-3, RE-6, RE-8, RD-37, RD-41; traces 16 and 19): the job's seat sends
# its result. Accepted: job.finished, then for a rule check its result
# (RuleChecks.finish, WP4's), cost.reported about the job, and the pending
# transition gated again (PendingTransitions.reenter, WP4's); for a contract
# draft, Complete contract run as the planner with this call's key
# (Transitions.run_as, RE-6), from the result's contract and the task's
# three stored values. Refused, and nothing written: a job that timed out
# or was withdrawn (invalid_state), a cancelled task's job
# (task_cancelled), another seat (not_holder).
class SubmitJobResultTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @project = scenario.project
    @codex = scenario.credential(provider: "codex", model: nil)
    @claude = scenario.credential(provider: "claude", model: nil)
    @orchestrator = scenario.orchestrator(credential: @codex, model: "codex-model-1")
    @planner = scenario.planner(credential: @claude, model: "claude-model-1")
  end

  FAILED = { "result" => "failed", "reason" => "The details do not say which prices change." }.freeze
  PASSED = { "result" => "passed", "reason" => "The details name the page and the prices." }.freeze

  # A model check waiting on its job, claimed by seat (the orchestrator
  # unless named), which must hold no other job.
  def claimed_check(rule = model_rule, seat: @orchestrator)
    task = scenario.task(state: "backlog", criteria: [], project: @project)
    task, pending, check = waiting_contract(rule, task: task)
    starting_attempts { assert_completed(claim_job(seat)) }
    [ task, pending, check, job_of(check) ]
  end

  # A Backlog task with a draft job claimed by the planner.
  def claimed_draft(**task_columns)
    task = scenario.task(state: "backlog", criteria: [], project: @project, **task_columns)
    job = scenario.job(kind: "contract_draft", task: task,
      input: { "task_id" => task.id, "project_id" => @project.id, "brief_version" => 0 })
    assert_completed(claim_job(@planner))
    [ task, job.reload ]
  end

  def draft_result(**fields)
    { "title" => "A made-up task",
      "details" => "The release notes list every change in 2.4.\n\nList each merged change, one line each.",
      "criteria" => [ { "text" => "The notes list every merged change.", "kind" => "build" },
                      { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }.merge(fields)
  end

  # Records, in one list, the order of the calls to the seams and of the
  # events written while the block runs.
  def in_order(&block)
    order = []
    log = ->(name) { ->(*arguments, **keywords) { order << [ name, arguments, keywords ]; nil } }
    answering(Leverage::RuleChecks, :finish, log.call(:finish)) do
      answering(Leverage::PendingTransitions, :reenter, log.call(:reenter)) do
        appended = Leverage::EventLog.method(:append)
        Leverage::EventLog.define_singleton_method(:append) do |ctx, **fields|
          appended.call(ctx, **fields).tap { |event| order << [ event.type, [ event ], {} ] }
        end
        begin
          block.call
        ensure
          Leverage::EventLog.define_singleton_method(:append, appended)
        end
      end
    end
    order
  end

  test "trace 16 command 4: a failed verdict finishes the job, then the check, then reports the cost, then re-enters" do
    task, pending, check, job = claimed_check
    key = new_key
    order = in_order { assert_completed(submit_result(@orchestrator, job, FAILED, tokens: 400, spend: 0.5, key: key)) }

    assert_equal [ "job.finished", :finish, "cost.reported", :reenter ], order.map(&:first)
    finished = order[0][1].first
    assert_equal [ "job", job.id, task.id, "seat", @orchestrator.id, key ],
      [ finished.subject_kind, finished.subject_id, finished.task_id, finished.actor_kind, finished.actor_id, finished.command_id ]
    _name, (_ctx, finished_check), keywords = order[1]
    assert_equal [ check.id, { result: "failed", reason: FAILED.fetch("reason"), tokens: 400, spend: 0.5 } ],
      [ finished_check.id, keywords ]
    cost = order[2][1].first
    assert_equal [ "job", job.id, task.id, @project.id, "seat", @orchestrator.id, key, { "tokens" => 400, "spend" => 0.5 } ],
      [ cost.subject_kind, cost.subject_id, cost.task_id, cost.project_id, cost.actor_kind, cost.actor_id, cost.command_id,
        cost.payload ]
    _name, (_ctx, reentered, trigger), = order[3]
    assert_equal [ pending.id, Leverage::Gating::Trigger.new(kind: :check_finished, rule_check_id: check.id) ],
      [ reentered.id, trigger ]

    job.reload
    assert_equal [ "finished", FAILED, 400, BigDecimal("0.5") ], job.attributes.values_at("state", "result", "tokens", "spend")
  end

  test "a job's spend adds to its task's project, never to the task's own spent (RE-8)" do
    task, _pending, _check, job = claimed_check
    assert_completed(submit_result(@orchestrator, job, PASSED, tokens: 10, spend: 1.25))

    assert_equal [ BigDecimal("1.25"), BigDecimal("0") ], [ @project.reload.spent, task.reload.spent ]
  end

  test "a warn check's result re-enters nothing: no transition waits on it (RC-16)" do
    _task, _pending, check, job = claimed_check(model_rule(on_fail: "warn"))
    check.update!(pending_transition_id: nil)

    calls = spy_on(Leverage::PendingTransitions, :reenter) { assert_completed(submit_result(@orchestrator, job, PASSED)) }

    assert_empty calls
  end

  test "not_applicable is a let-the-checker-decide rule's answer only, and a result must fit the job's kind" do
    _task, _pending, _check, job = claimed_check
    assert_raises(T::Invalid) { submit_result(@orchestrator, job, { "result" => "not_applicable", "reason" => "x" }) }
    assert_raises(T::Invalid) { submit_result(@orchestrator, job, draft_result) }
    assert_equal "claimed", job.reload.state

    second = scenario.orchestrator(credential: @codex)
    _task, _pending, _check, decides = claimed_check(model_rule(scope_kind: "checker_decides"), seat: second)
    calls = spy_on(Leverage::RuleChecks, :finish) do
      assert_completed(submit_result(second, decides, { "result" => "not_applicable", "reason" => "Not this task." }))
    end
    assert_equal [ "not_applicable" ], calls.map { |call| call.keywords[:result] }

    _task, draft = claimed_draft
    assert_raises(T::Invalid) { submit_result(@planner, draft, PASSED) }
    assert_raises(T::Invalid) { submit_result(@planner, draft, draft_result.except("details")) }
    assert_equal "claimed", draft.reload.state
  end

  # Trace 16's workspace has the shipped rules, so the planner's Complete
  # contract meets "Every task needs specific details", a model gate at
  # task.before_ready, and this call answers pending (RE-6): its own
  # job.finished and cost.reported, then the gate's events under its key.
  test "trace 16 command 11: a draft's result runs Complete contract as the planner, with this call's key (RE-6)" do
    scenario.with_shipped_rules
    task, job = claimed_draft(work_reference: "~/work/notes")
    task.update!(minimum_strength_rank: 2, budget_cap: 7.5)
    key = new_key
    written = nil
    outcome = nil
    calls = spy_on(T, :run_as) do
      written = events_written { outcome = submit_result(@planner, job, draft_result, tokens: 900, key: key) }
    end

    assert_equal :pending, outcome.outcome
    assert_equal [ [ "job.finished", job.id ], [ "cost.reported", job.id ] ],
      written.first(2).map { |event| [ event.type, event.subject_id ] }
    assert_equal %w[check.finished check.queued job.queued], written.drop(2).map(&:type)
    assert_equal [ key ], written.map(&:command_id).uniq
    call = calls.sole
    assert_equal "complete_contract", call.arguments[1]
    assert_equal [ @planner.id, key ], [ call.keywords[:requester].id, call.keywords[:key] ]
    assert_equal draft_result.merge("id" => task.id, "work_reference" => "~/work/notes", "minimum_strength_rank" => 2,
      "budget_cap" => 7.5), call.keywords[:params]
  end

  test "a planner cannot change where the work is: the task's stored three values are sent, whatever the result says" do
    task, job = claimed_draft(work_reference: nil)
    calls = spy_on(T, :run_as) do
      assert_completed(submit_result(@planner, job, draft_result("details" => nil, "work_reference" => "/etc",
        "minimum_strength_rank" => 0, "budget_cap" => 9999)))
    end

    assert_equal [ nil, nil, nil ], calls.sole.keywords[:params].values_at("work_reference", "minimum_strength_rank", "budget_cap")
    assert_nil task.reload.work_reference
    assert_nil task.details
  end

  test "null and blank draft details preserve the task's text even when its model check fails" do
    scenario.with_shipped_rules
    details = "Folded goal.\r\nSecond line.\n\n\r\nOwner details.\r\n"

    [ nil, "", " \t\r\n" ].each do |draft_details|
      task, job = claimed_draft(details: details)
      outcome = submit_result(@planner, job, draft_result("details" => draft_details))
      assert_equal :pending, outcome.outcome
      assert_completed(claim_job(@orchestrator))
      check = RuleCheck.find_by!(task_id: task.id, rule_id: Rule.find_by!(workspace_id: scenario.workspace_id,
        key: "specific_details").id)
      assert_completed(submit_result(@orchestrator, job_of(check), FAILED))

      assert_equal [ "backlog", details ], task.reload.attributes.values_at("state", "details")
    end
  end

  test "when the planner's Complete contract waits on a model check, the result call itself is the one waiting (RE-6)" do
    _task, job = claimed_draft
    pending = ->(*, **) { :pending }
    entry = nil
    answering(T, :run_as, pending) do
      ActiveRecord::Base.transaction(requires_new: true) do
        ctx = scenario.context(request: seat_request(@planner, "submit_job_result", result_params(job, draft_result)))
        entry = T::Table.entry_for("submit_job_result").new
        entry.load(ctx)
        assert_empty entry.refusals(ctx).compact
        entry.perform(ctx)
      end
    end

    assert entry.pending?
    assert_equal "finished", job.reload.state
  end

  test "a draft's result for a task no longer in Backlog is invalid_state and writes nothing (RD-37)" do
    task, job = claimed_draft
    task.update!(state: "ideas")

    written = events_written { assert_refused("invalid_state", submit_result(@planner, job, draft_result)) }

    assert_empty written
    assert_equal "claimed", job.reload.state
  end

  test "a result for a timed-out or withdrawn job, or after its run time, is invalid_state and writes nothing (RD-41)" do
    _task, _pending, _check, timed_out = claimed_check
    timed_out.update!(state: "timed_out")
    _task, _pending, _check, withdrawn = claimed_check
    withdrawn.update!(state: "withdrawn")
    _task, _pending, check, late = claimed_check
    RuleCheckAttempt.where(rule_check_id: check.id).update_all(started_at: scenario.database_now - 301)

    written = events_written do
      [ timed_out, withdrawn, late ].each { |job| assert_refused("invalid_state", submit_result(@orchestrator, job, PASSED)) }
    end

    # Nothing of its own. Timers run first (L118, test 7): the late job's
    # run timeout, due before the result, is applied by the app with no key
    # and commits with the refusal (WP7's request 5).
    assert_empty written.reject { |event| event.actor_kind == "app" && event.command_id.nil? }
    assert_equal %w[job.timed_out job.requeued check.queued], written.map(&:type)
    assert_equal [ late.id, late.id ], written.first(2).map(&:subject_id)
  end

  test "a cancelled task's job is task_cancelled; another seat's is not_holder; a job of another workspace is 404" do
    task, _pending, _check, job = claimed_check
    job.update!(state: "withdrawn")
    task.update!(state: "cancelled")
    scenario.append("task.cancelled", task: task, actor_kind: "owner", actor_id: scenario.owner.id)
    assert_refused("task_cancelled", submit_result(@orchestrator, job, PASSED))

    _task, _pending, _check, held = claimed_check
    other = scenario.orchestrator(credential: @codex)
    assert_refused("not_holder", submit_result(other, held, PASSED))
    assert_refused("not_holder", submit_result(@planner, held, PASSED))

    foreign = Scenario.new
    foreign_job = foreign.job(kind: "contract_draft", task: foreign.task(state: "backlog"))
    assert_raises(T::NotFound) { submit_result(@orchestrator, foreign_job, PASSED) }
  end
end
