require "test_helper"
require_relative "entries/jobs_support"

class QuestionsTest < ActiveSupport::TestCase
  include JobsSupport
  include OpenapiAssertions

  setup do
    use_scenario(lease_length_seconds: 600)
    @builder = own_seat
    @project = scenario.project
    @task = scenario.task(state: "working", builder: @builder, project: @project)
    @orchestrator = scenario.orchestrator
  end

  def acknowledge
    hash = Leverage::Briefing.hash_for(@task, seat: @builder)
    assert_completed(seat_command(@builder, "acknowledge_briefing", { "id" => @task.id, "briefing_hash" => hash }))
  end

  def ask(task = @task, seat: @builder, blocking: false)
    seat_command(seat, "ask_question",
      { "id" => task.id, "text" => "Which sample label?", "assumption" => "Use the short sample.", "blocking" => blocking })
  end

  def use_policy(effect)
    rule = scenario.with_shipped_rules.find { |item| item.key == "ask_orchestrator_first" }
    version = scenario.current_version(rule)
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(rules: [ {
      id: rule.id, version_id: version.id, version: version.version, hook: "question.asked", enabled: true,
      kind: "policy", checker: "app", scope: "covers", effect: effect
    } ])
    rule
  end

  def question_job(blocking: true, state: "claimed")
    question = scenario.question(@task, blocking: blocking)
    job = scenario.job(kind: "question", task: @task, target: question, state: state, seat: @orchestrator)
    [ question, job ]
  end

  test "only a builder holding the task with the current acknowledgement may ask" do
    assert_refused("not_holder", ask(seat: own_seat(role: "reviewer")))
    assert_refused("not_holder", ask(seat: own_seat))
    assert_refused("briefing_not_acknowledged", ask)
    acknowledge
    @project.update!(brief_version: @project.brief_version + 1)
    assert_refused("briefing_changed", ask)
    assert_empty Question.where(task_id: @task.id)
  end

  test "the enabled routing policy checks the actual question and queues a blocking question without opening a hold" do
    rule = use_policy("to_orchestrator")
    acknowledge
    before_step = TaskStep.find_by!(task_id: @task.id, closed_at: nil)
    assert_equal "build", before_step.kind
    before_due = @task.lease_due_at
    outcome = nil
    written = events_written { outcome = assert_completed(ask(blocking: true)) }

    assert_matches_component("AskQuestionResult", outcome.result)
    question = Question.find(outcome.result.fetch("question_id"))
    assert_equal %w[question.asked check.finished job.queued], types(written)
    job = Job.find_by!(target_id: question.id)
    assert_equal({ "blocking" => true }, written.first.payload)
    check = RuleCheck.find(written[1].subject_id)
    assert_equal [ rule.id, "question", question.id, "applied", "to_orchestrator" ],
      check.attributes.values_at("rule_id", "subject_kind", "subject_id", "result", "effect")
    assert_equal Leverage::Gating.input_hash(hook: "question.asked", inputs: { "question" => "Which sample label?" }), check.input_hash
    assert_equal [ "open", @builder.id, written.first.at ], question.attributes.values_at("outcome", "asking_seat_id", "asked_at")
    assert_equal [ "question", "queued", "orchestrator" ], job.attributes.values_at("kind", "state", "seat_role")
    assert_empty Leverage::Holds.open_holds(@task)
    assert_equal before_due, @task.reload.lease_due_at
    assert_nil before_step.reload.closed_at

    claim = assert_completed(claim_job(@orchestrator))
    assert_matches_component("ClaimJobResult", claim.result)
    assert_equal job.id, claim.result.fetch("job_id")
    assert_equal (job.reload.claimed_at + scenario.workspace.check_run_timeout_seconds).utc.iso8601(6), claim.result.fetch("run_due_at")
  end

  test "to_owner writes the applied check and the non-blocking item caused by the question" do
    use_policy("to_owner")
    acknowledge
    written = events_written { assert_completed(ask) }

    assert_equal %w[question.asked check.finished inbox.opened], types(written)
    assert_equal [ "applied", "to_owner" ], written[1].payload.values_at("result", "effect")
    assert_equal written.first.id, written.last.cause_id
    assert_empty Job.where(task_id: @task.id)
    assert_equal "passed_on", Question.find(written.first.subject_id).outcome
  end

  test "rule off passes on without recording a check even when an orchestrator is connected" do
    acknowledge
    written = events_written { assert_completed(ask) }

    assert_equal %w[question.asked inbox.opened], types(written)
    assert_equal "passed_on", Question.find(written[0].subject_id).outcome
  end

  %w[record decision].each do |basis|
    test "a question job answers with basis #{basis}, after the job finishes and reports cost" do
      question, job = question_job
      answer = { "outcome" => "answered", "answer" => "A sample reply.", "basis" => basis }
      written = events_written { assert_completed(submit_result(@orchestrator, job, answer, tokens: 43, spend: 0.5)) }

      assert_equal %w[job.finished cost.reported question.answered], types(written)
      assert_equal({ "basis" => basis }, written.last.payload)
      assert_equal [ "answered", answer["answer"], basis, "seat", @orchestrator.id, written.last.at, nil ],
        question.reload.attributes.values_at("outcome", "answer", "basis", "answered_by_kind", "answered_by_id", "answered_at", "read_at")
      assert_equal [ "finished", answer, 43 ], job.reload.attributes.values_at("state", "result", "tokens")
      assert_equal [ BigDecimal("0.5"), BigDecimal("0") ], [ @project.reload.spent, @task.reload.spent ]
    end
  end

  [ true, false ].each do |blocking|
    test "a job passes on a question with blocking #{blocking}" do
      question, job = question_job(blocking: blocking)
      written = events_written do
        assert_completed(submit_result(@orchestrator, job, { "outcome" => "passed_on", "answer" => nil, "basis" => nil }))
      end

      assert_equal %w[job.finished cost.reported] + (blocking ? %w[hold.opened] : []) + %w[inbox.opened], types(written)
      assert_equal "passed_on", question.reload.outcome
      assert_equal "app", written.last.actor_kind
      assert_equal({ "question_id" => question.id }, InboxItem.find(written.last.subject_id).facts)
    end
  end

  test "an answer longer than the result limit is invalid before any state changes" do
    question, job = question_job
    limit = Leverage::Contract.openapi.dig("components", "schemas", "QuestionJobResult", "properties", "answer", "maxLength")
    answer = { "outcome" => "answered", "answer" => "é" * (limit + 1), "basis" => "record" }

    assert_empty events_written {
      assert_raises(T::Invalid) { submit_result(@orchestrator, job, answer) }
    }
    assert_equal [ "open", "claimed" ], [ question.reload.outcome, job.reload.state ]
    assert_completed(submit_result(@orchestrator, job, answer.merge("answer" => "é" * limit)))
  end

  test "a result must either carry an answer and its basis or pass on without either" do
    question, job = question_job
    malformed = [
      { "outcome" => "answered", "answer" => nil, "basis" => "record" },
      { "outcome" => "answered", "answer" => "A sample reply.", "basis" => nil },
      { "outcome" => "passed_on", "answer" => "A sample reply.", "basis" => nil },
      { "outcome" => "passed_on", "answer" => nil, "basis" => "decision" }
    ]

    assert_empty events_written {
      malformed.each { |result| assert_raises(T::Invalid) { submit_result(@orchestrator, job, result) } }
    }
    assert_equal [ "open", "claimed" ], [ question.reload.outcome, job.reload.state ]
  end

  test "a result that arrives after its run timeout commits the miss and is refused" do
    question, job = question_job
    job.update!(claimed_at: scenario.database_now - scenario.workspace.check_run_timeout_seconds - 1)
    written = events_written do
      assert_refused("invalid_state", submit_result(@orchestrator, job,
        { "outcome" => "answered", "answer" => "Too late.", "basis" => "record" }))
    end

    assert_equal %w[job.timed_out job.requeued], types(written)
    assert written.all? { |event| event.actor_kind == "app" && event.command_id.nil? }
    assert_equal [ "open", "timed_out" ], [ question.reload.outcome, job.reload.state ]
    assert_equal 2, Job.find_by!(target_id: question.id, state: "queued").attempt_number
  end

  test "older questions on Done tasks are neither offered nor replayed as work" do
    task = scenario.task(state: "done", builder: own_seat)
    question = scenario.question(task)
    queued = scenario.job(kind: "question", task: task, target: question)
    claimed = scenario.job(kind: "question", task: task, target: question, state: "claimed", seat: @orchestrator)
    assert_nil Leverage::Jobs.held(@orchestrator)
    refute Leverage::Jobs.claim_material_available?(claimed, @orchestrator, at: scenario.database_now)
    assert_refused("not_eligible", claim_job(@orchestrator))
    assert_equal "queued", queued.reload.state
  end

  test "the asking seat marks only a delivered answer as read and overturn makes it unread again" do
    question = scenario.question(@task, outcome: "answered", answerer: @orchestrator)
    mark = T::MarkQuestionRead
    open_question = scenario.question(@task)
    other = own_seat
    written = events_written do
      refute mark.call(question, seat: other)
      refute mark.call(open_question, seat: @builder)
      assert_nil question.reload.read_at
      assert mark.call(question, seat: @builder)
      assert question.reload.read_at
      refute mark.call(question, seat: @builder)
    end
    assert_empty written

    answer = question.answer
    assert_completed(owner_command("overturn_answer", { "id" => question.id }))
    assert_equal [ "overturned", answer, nil ], question.reload.attributes.values_at("outcome", "answer", "read_at")
    assert mark.call(question, seat: @builder)
  end

  test "an answer read before overturn does not clear the notice of the overturn" do
    question = scenario.question(@task, outcome: "answered", answerer: @orchestrator)
    assert_completed(owner_command("overturn_answer", { "id" => question.id }))

    refute T::MarkQuestionRead.call(question)
    assert_nil question.reload.read_at
    assert T::MarkQuestionRead.call(question)
  end

  test "a read after the lease deadline leaves the answer unread" do
    question = scenario.question(@task, outcome: "answered", answerer: @orchestrator)
    scenario.make_due(@task)

    refute T::MarkQuestionRead.call(question, seat: @builder)
    assert_nil question.reload.read_at
  end

  test "the ask, route and answer clocks follow the workspace lock when the database clock steps back" do
    use_policy("to_orchestrator")
    acknowledge
    at = Event.where(workspace_id: scenario.workspace_id).maximum(:at)
    lock = Leverage::WorkspaceLock
    original = lock.method(:clock)
    lock.define_singleton_method(:clock) { at - 0.04 }

    outcome = assert_completed(ask)
    assert_matches_component("AskQuestionResult", outcome.result)
    question = Question.find(outcome.result.fetch("question_id"))
    job_id = assert_completed(claim_job(@orchestrator)).result.fetch("job_id")
    job = Job.find(job_id)
    assert_completed(submit_result(@orchestrator, job,
      { "outcome" => "answered", "answer" => "Use the sample.", "basis" => "decision" }))

    assert_operator question.asked_at, :>, at
    assert_operator job.queued_at, :>=, question.asked_at
    assert_operator job.claimed_at, :>, job.queued_at
    assert_operator question.reload.answered_at, :>, job.claimed_at
  ensure
    lock.define_singleton_method(:clock, original) if original
  end
end
