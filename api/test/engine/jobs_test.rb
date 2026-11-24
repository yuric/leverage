require "test_helper"
require_relative "entries/jobs_support"

# Leverage::Jobs (PRD L540, L545, L872; milestone 4 plan §2.1, RD-34 to
# RD-36, RD-40, RD-41, RD-44, RC-49, DB-31; traces 16 and 19): the only
# writer of jobs and the only emitter of job.*. Who may claim, in what
# order, and what queueing, claiming, finishing, timing out, requeueing and
# withdrawing a job write.
#
# The class is not JobsTest: test/contract/jobs_test.rb has that name, and
# bin/rails test loads both (milestone 4 plan §0.1).
class JobQueueTest < ActiveSupport::TestCase
  include JobsSupport

  J = Leverage::Jobs

  setup do
    use_scenario
    @codex = scenario.credential(provider: "codex", model: nil)
    @orchestrator = scenario.orchestrator(credential: @codex, model: "codex-model-1")
  end

  # Runs the block inside a command of caller (a seat, the owner's User, or
  # nil for the app), with its context.
  def inside(caller = nil, key: new_key)
    ActiveRecord::Base.transaction(requires_new: true) do
      request = case caller
      when Seat then seat_request(caller, "made_up", {}, key: key)
      when User then owner_request("made_up", {}, key: key)
      else T::Request.new(command: "made_up", workspace_id: scenario.workspace_id, caller_kind: nil, caller_id: nil,
        key: nil, request_hash: nil, params: {})
      end
      yield scenario.context(request: request)
    end
  end

  def draft_job(task = scenario.task(state: "backlog"), **options)
    scenario.job(kind: "contract_draft", task: task, **options)
  end

  def check_job(task = scenario.task(state: "backlog"))
    _task, _pending, check = waiting_contract(model_rule, task: task)
    job_of(check)
  end

  # --- queue ------------------------------------------------------------------

  test "queue writes the job row and job.queued about the job, on its task, as the caller" do
    project = scenario.project
    task = scenario.task(state: "backlog", project: project)
    key = new_key
    job = nil
    written = events_written do
      inside(scenario.owner, key: key) do |ctx|
        job = J.queue(ctx, kind: "contract_draft", task: task, target: task, seat_role: "planner",
          input: { "task_id" => task.id, "project_id" => project.id, "brief_version" => 0 })
      end
    end

    assert_kind_of Job, job
    job.reload
    assert_equal [ "contract_draft", task.id, project.id, "task", task.id, "planner", "queued", 1, nil, nil ],
      job.attributes.values_at("kind", "task_id", "project_id", "target_kind", "target_id", "seat_role", "state",
        "attempt_number", "claimed_by_seat_id", "claimed_at")
    assert_equal({ "task_id" => task.id, "project_id" => project.id, "brief_version" => 0 }, job.input)
    queued = written.sole
    assert_equal [ "job.queued", "job", job.id, task.id, "owner", scenario.owner.id, key, { "kind" => "contract_draft" } ],
      [ queued.type, queued.subject_kind, queued.subject_id, queued.task_id, queued.actor_kind, queued.actor_id,
        queued.command_id, queued.payload ]
    assert_equal queued.at, job.queued_at
  end

  test "queue takes an id chosen first and an attempt number, so check.queued can name the job before job.queued" do
    task = scenario.task(state: "backlog")
    id = SecureRandom.uuid
    job = inside { |ctx| J.queue(ctx, kind: "contract_draft", task: task, target: task, seat_role: "planner", input: {}, id: id,
      attempt_number: 3) }

    assert_equal [ id, 3 ], [ job.id, job.reload.attempt_number ]
  end

  # --- next_for: who may claim and what (L545, RD-35, RD-36, RC-49) -----------

  test "jobs are given out oldest first, by queued time and then id, each to the role that claims its kind (IF-13)" do
    jobs = Array.new(3) { check_job }.sort_by(&:id)
    base = jobs.first.reload.queued_at
    jobs.reverse.each_with_index { |job, index| Job.where(id: job.id).update_all(queued_at: base - 10 + index) }
    planner = scenario.planner(credential: scenario.credential(provider: "claude"))
    draft = draft_job

    assert_equal jobs.last.id, J.next_for(@orchestrator)&.id, "the oldest, whose id is the highest"
    assert_equal draft.id, J.next_for(planner)&.id
    Job.where(id: jobs.map(&:id)).update_all(queued_at: base)
    assert_equal jobs.first.id, J.next_for(@orchestrator)&.id, "the same time: the lowest id"
  end

  test "a seat that holds a job gets that job again, whatever is queued (RD-35, RD-40)" do
    held = check_job
    inside(@orchestrator) { |ctx| J.claim(ctx, held.reload, @orchestrator) }
    check_job

    assert_equal held.id, J.next_for(@orchestrator)&.id
  end

  test "a builder, a reviewer, a disabled, paused or removed seat gets no job" do
    check_job
    builder = scenario.seat(role: "builder", credential: @codex)
    reviewer = scenario.seat(role: "reviewer", credential: @codex)
    disabled = scenario.orchestrator(credential: @codex, enabled: false)
    paused = scenario.pause_seat(scenario.orchestrator(credential: @codex))
    removed = scenario.remove(scenario.orchestrator(credential: @codex))

    [ builder, reviewer, disabled, paused, removed ].each { |seat| assert_nil J.next_for(seat), seat.role }
    assert J.next_for(@orchestrator)
  end

  test "a seat the app runs needs an available candidate its run is on; one that connects on its own needs none" do
    check_job
    own = scenario.orchestrator(provider: "codex")
    assert J.next_for(own), "a seat that connects on its own claims"

    scenario.limit_credential(@codex, reset_at: from_now(900))
    assert_nil J.next_for(@orchestrator), "its only login is limited"

    grok = scenario.credential(provider: "grok", model: "grok-model-1")
    assert_nil J.next_for(@orchestrator), "a candidate below, but its run is on the limited login (HD-4)"
    scenario.run(@orchestrator, on: grok)
    assert J.next_for(@orchestrator.reload)
  end

  test "a seat never gets a job of a task it held as a builder (RC-49, RD-36, from task.claimed)" do
    task = scenario.task(state: "backlog")
    held_once = check_job(task)
    scenario.append("task.claimed", task: task, actor_kind: "seat", actor_id: @orchestrator.id,
      payload: { seat_id: @orchestrator.id, credential_id: @codex.id, model: "codex-model-1" })
    other = scenario.orchestrator(credential: @codex)

    assert_nil J.next_for(@orchestrator)
    assert_equal held_once.id, J.next_for(other)&.id
  end

  test "a job whose queue time has run out is left to its timer, and so is a held job whose run time has" do
    late = check_job
    RuleCheckAttempt.where(job_id: late.id).update_all(queued_at: scenario.database_now - 121)
    fresh = check_job

    assert_equal fresh.id, J.next_for(@orchestrator)&.id

    inside(@orchestrator) { |ctx| J.claim(ctx, fresh.reload, @orchestrator) }
    RuleCheckAttempt.where(job_id: fresh.id).update_all(started_at: scenario.database_now - 301)
    assert_nil J.next_for(@orchestrator), "the held job is past its run time; the queued one past its queue time"
  end

  test "a withdrawn, timed-out or finished job is never given out" do
    task = scenario.task(state: "backlog")
    %w[withdrawn timed_out].each { |state| draft_job(task, state: state) }
    planner = scenario.planner(provider: "claude")
    draft_job(task, state: "finished", seat: planner)

    assert_nil J.next_for(planner)
  end

  # --- claim (L872, RD-40) ------------------------------------------------------

  test "claim records the seat, the time, the credential and the model, and writes job.claimed as the seat" do
    job = check_job
    key = new_key
    written = events_written { inside(@orchestrator, key: key) { |ctx| J.claim(ctx, job.reload, @orchestrator) } }

    claimed = written.sole
    job.reload
    assert_equal [ "claimed", @orchestrator.id, @codex.id, claimed.at ],
      job.attributes.values_at("state", "claimed_by_seat_id", "credential_id", "claimed_at")
    assert_equal [ "job.claimed", "job", job.id, job.task_id, "seat", @orchestrator.id, key ],
      [ claimed.type, claimed.subject_kind, claimed.subject_id, claimed.task_id, claimed.actor_kind, claimed.actor_id,
        claimed.command_id ]
    assert_equal({ "credential_id" => @codex.id, "model" => "codex-model-1" }, claimed.payload)
  end

  test "claim records the first available candidate and the model a run on it uses (HE-5)" do
    job = check_job
    scenario.limit_credential(@codex, reset_at: from_now(900))
    grok = scenario.credential(provider: "grok", model: "grok-model-1")
    scenario.run(@orchestrator, on: grok)

    claimed = events_written { inside(@orchestrator) { |ctx| J.claim(ctx, job.reload, @orchestrator.reload) } }.sole

    assert_equal({ "credential_id" => grok.id, "model" => "grok-model-1" }, claimed.payload)
    assert_equal grok.id, job.reload.credential_id
  end

  test "a seat that connects on its own claims with no credential and its own model, or none" do
    job = check_job
    own = scenario.orchestrator(provider: "codex", model: "")

    claimed = events_written { inside(own) { |ctx| J.claim(ctx, job.reload, own) } }.sole

    assert_equal({ "credential_id" => nil, "model" => nil }, claimed.payload)
  end

  # --- finish, time_out, requeue, withdraw ----------------------------------------

  test "finish keeps the result, the tokens and the spend on the row and writes job.finished" do
    job = check_job
    inside(@orchestrator) { |ctx| J.claim(ctx, job.reload, @orchestrator) }
    result = { "result" => "passed", "reason" => "Made-up reason." }
    finished = events_written do
      inside(@orchestrator) { |ctx| J.finish(ctx, job.reload, result: result, tokens: 400, spend: 0.25) }
    end.sole

    job.reload
    assert_equal [ "finished", result, 400, BigDecimal("0.25"), finished.at ],
      job.attributes.values_at("state", "result", "tokens", "spend", "finished_at")
    assert_equal [ "job.finished", "job", job.id, "seat", @orchestrator.id, {} ],
      [ finished.type, finished.subject_kind, finished.subject_id, finished.actor_kind, finished.actor_id, finished.payload ]
  end

  test "time_out ends the job at the timer's time, as the app with no key, and writes job.timed_out" do
    job = check_job
    due = scenario.database_now - 5
    timed_out = events_written do
      inside(@orchestrator) do |ctx|
        J.time_out(ctx, job.reload, :queue, effective_at: due, actor_kind: "app", actor_id: nil, command_id: nil)
      end
    end.sole

    assert_equal [ "timed_out", due ], job.reload.attributes.values_at("state", "finished_at").then { |s, at| [ s, at.round(6) ] }
    assert_equal [ "job.timed_out", "job", job.id, "app", nil, nil, due.round(6) ],
      [ timed_out.type, timed_out.subject_kind, timed_out.subject_id, timed_out.actor_kind, timed_out.actor_id,
        timed_out.command_id, timed_out.effective_at.round(6) ]
    assert_raises(ArgumentError) { inside { |ctx| J.time_out(ctx, job, :late) } }
  end

  test "requeue writes job.requeued on the old job and makes the next attempt's job, with no job.queued (DB-31)" do
    job = check_job
    inside { |ctx| J.time_out(ctx, job.reload, :queue) }
    created = nil
    written = events_written { inside { |ctx| created = J.requeue(ctx, job.reload) } }

    assert_equal [ [ "job.requeued", job.id ] ], written.map { |event| [ event.type, event.subject_id ] }
    created.reload
    assert_not_equal job.id, created.id
    assert_equal job.attributes.values_at("kind", "task_id", "project_id", "target_kind", "target_id", "seat_role", "input"),
      created.attributes.values_at("kind", "task_id", "project_id", "target_kind", "target_id", "seat_role", "input")
    assert_equal [ "queued", 2, written.sole.effective_at ], created.attributes.values_at("state", "attempt_number", "queued_at")
  end

  test "withdraw ends a queued or claimed job and writes job.withdrawn" do
    queued = check_job
    claimed = check_job
    inside(@orchestrator) { |ctx| J.claim(ctx, claimed.reload, @orchestrator) }

    written = events_written do
      inside(scenario.owner) do |ctx|
        J.withdraw(ctx, queued.reload)
        J.withdraw(ctx, claimed.reload)
      end
    end

    assert_equal [ [ "job.withdrawn", queued.id ], [ "job.withdrawn", claimed.id ] ],
      written.map { |event| [ event.type, event.subject_id ] }
    assert_equal %w[withdrawn withdrawn], [ queued.reload.state, claimed.reload.state ]
    assert_nil J.next_for(@orchestrator)
  end
  test "General claims and completes each job with only the General role's job rules" do
    seat = scenario.seat(role: "general", provider: "codex")
    task = scenario.task(state: "backlog")
    [ "rule_check", "approval", "question", "contract_draft" ].each do |kind|
      current = kind == "approval" ? scenario.finishing_task(actions: [ { state: "requested" } ]) : task
      job, result = general_job(kind, current)
      offered = assert_completed(claim_job(seat)).result
      assert_equal [ job.id, kind ], offered.values_at("job_id", "kind")
      assert_nil offered.dig("input", "material", "role_file")
      instructions = Leverage::Contract.roles.fetch("roles").find { |row| row.fetch("role") == "general" }.fetch("job_rules")
      assert_equal instructions, offered.dig("input", "material", "job_rules")
      assert_completed(submit_result(seat, job, result))
      assert_equal "finished", job.reload.state
    end
  end

  test "General cannot work on a job for a task it built, which another orchestrator can take" do
    general = scenario.seat(role: "general", provider: "codex")
    task = scenario.task(state: "working", builder: general)
    question, = general_job("question", task)
    other, = general_job("question", scenario.task)

    assert_equal other, J.next_for(general)
    assert_equal question, J.next_for(@orchestrator)
  end

  test "General cannot take the ready check of its own draft but can take another check" do
    general = scenario.seat(role: "general")
    task = scenario.task
    scenario.job(kind: "contract_draft", task: task, state: "finished", seat: general)
    own, = general_job("rule_check", task)
    assert_nil J.next_for(general)
    assert_equal own, J.next_for(@orchestrator)
  end

  %i[task review provisional].each do |work|
    test "a General seat holding a #{work} cannot claim a job" do
      general = scenario.seat(role: "general")
      general_job("question", scenario.task)
      case work
      when :task then scenario.task(state: "working", builder: general)
      when :review
        task = scenario.task(state: "in_review")
        review = scenario.review(task, reviewer: general)
        scenario.pending_transition(task, command: "pass_review", requester: general, params: { "id" => review.id })
      when :provisional then scenario.task(state: "ready").update!(holder_seat_id: general.id)
      end
      assert_nil J.next_for(general)
    end
  end

  private

  def general_job(kind, task)
    case kind
    when "rule_check"
      _task, _pending, check = waiting_contract(model_rule, task: task)
      [ job_of(check), { "result" => "passed", "reason" => "The made-up details are sufficient." } ]
    when "approval"
      action = Action.find_by!(task_id: task.id, state: "requested")
      rule = model_rule(hook: "action.requested")
      check = scenario.rule_check(task, rule: rule, subject: action, attempts: 0)
      attempt = Leverage::RuleChecks.queue_attempt(scenario.context, check, kind: kind)
      [ Job.find(attempt.job_id), { "decision" => "pass_to_owner", "reason" => "The made-up action needs a change." } ]
    when "question"
      question = scenario.question(task, asking_seat: task.builder_seat_id ? Seat.find(task.builder_seat_id) : scenario.seat)
      [ scenario.job(kind: kind, task: task, target: question), { "outcome" => "pass_on" } ]
    when "contract_draft"
      [ draft_job(task), contract_body ]
    end
  end

end
