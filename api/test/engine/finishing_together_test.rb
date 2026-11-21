require "test_helper"

class FinishingTogetherTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat
    @reviewer = @scenario.seat(role: "reviewer")
    @orchestrator = @scenario.orchestrator
    Leverage::Gating.implementation = Leverage::Rules::Engine.new
  end

  [ false, true ].each do |deferred|
    test "an out-of-scope approval goes to the owner #{deferred ? 'after its gate' : 'immediately'}" do
      policy = @scenario.rule(key: "orchestrator_approves_actions", origin: "shipped",
        scope_kind: "action_kinds", scope_values: [ "publish" ])
      gate = @scenario.rule(hook: "action.requested") if deferred
      task = pass_review("send")
      action = Action.find_by!(task_id: task.id)

      if deferred
        assert_equal "invalid_state", owner("approve_action", action).refusal.code
        job = seat("claim_job", @orchestrator).result.fetch("job_id")
        assert_equal gate.id, RuleCheck.find(Job.find(job).target_id).rule_id
        assert seat("submit_job_result", @orchestrator, "id" => job,
          "result" => { "result" => "passed", "reason" => "Sample result" }, "tokens" => 0, "spend" => 0).completed?
      end

      assert_equal "not_applicable", RuleCheck.find_by!(subject_id: action.id, rule_id: policy.id).result
      assert_empty Job.where(task_id: task.id, kind: "approval")
      assert Hold.exists?(action_id: action.id, reason: "owner_approval", closed_at: nil)
      assert owner("approve_action", action).completed?
      assert_equal @builder.id, task.reload.holder_seat_id
      assert_equal "approved", action.reload.state
    end
  end

  test "outward action jobs queued together follow event order" do
    task = @scenario.finishing_task(builder: @builder, actions: [
      { kind: "publish", description: "Sample first action" },
      { kind: "send", description: "Sample second action" }
    ])
    first_action, second_action = Leverage::Actions.for_task(task).to_a
    gate = @scenario.rule(hook: "action.requested")
    policy = @scenario.rule(key: "orchestrator_approves_actions", origin: "shipped")
    first_check = @scenario.rule_check(task, rule: gate, subject: first_action, attempts: 0)
    second_check = @scenario.rule_check(task, rule: policy, subject: second_action, attempts: 0)
    ctx = @scenario.context
    first = Leverage::Jobs.queue(ctx, kind: "rule_check", task: task, target: first_check, seat_role: "orchestrator",
      input: {}, id: "ffffffff-ffff-4fff-8fff-ffffffffffff")
    second = Leverage::Jobs.queue(ctx, kind: "approval", task: task, target: second_check, seat_role: "orchestrator",
      input: {}, id: "00000000-0000-4000-8000-000000000001")
    first.update_columns(created_at: second.created_at + 1)

    assert_equal first.queued_at, second.queued_at
    assert_equal first.id, Leverage::Jobs.next_for(@orchestrator)&.id
  end

  [ nil, "Use the owner's sample instruction." ].each do |instruction|
    test "an approval job uses #{instruction ? 'the edited' : 'the shipped'} instruction" do
      key = "orchestrator_approves_actions"
      @scenario.rule(key: key, origin: "shipped", instruction: instruction)
      pass_review("send")

      claimed = seat("claim_job", @orchestrator)
      assert claimed.completed?
      expected = instruction || Leverage::Rules::Shipped.find(key).version_fields.fetch(:instruction)
      assert expected == claimed.result.dig("input", "material", "instruction")
    end
  end

  test "a contract draft takes the brief in its edited order" do
    project = @scenario.project
    task = @scenario.task(project: project)
    planner = @scenario.planner
    entries = [
      { "kind" => "fact", "text" => "Sample fact one" },
      { "kind" => "fact", "text" => "Sample fact two" }
    ]
    assert owner("edit_brief", project, "entries" => entries).completed?
    assert owner("edit_brief", project, "entries" => entries.reverse).completed?
    assert owner("draft_contract", task).completed?

    claimed = seat("claim_job", planner)
    assert claimed.completed?
    assert_equal entries.reverse.pluck("text"), claimed.result.dig("input", "material", "brief").pluck("text")
  end

  [ false, true ].each do |claimed|
    test "a #{claimed ? 'claimed' : 'queued'} job cannot repopulate deleted content" do
      @scenario.rule(hook: "task.before_done", on_fail: "warn")
      task = pass_review
      job = Job.find_by!(task_id: task.id, kind: "rule_check")
      assert_equal job.id, seat("claim_job", @orchestrator).result.fetch("job_id") if claimed
      assert apply("delete_content", "owner", @scenario.owner, "task_id" => task.id).completed?

      if claimed
        result = seat("submit_job_result", @orchestrator, "id" => job.id, "tokens" => 1, "spend" => 0,
          "result" => { "result" => "passed", "reason" => "Sample reason" })
        assert_equal "invalid_state", result.refusal&.code
      else
        assert_equal "not_eligible", seat("claim_job", @orchestrator).refusal&.code
      end
      assert_nil job.reload.result
      assert_nil RuleCheck.find(job.target_id).reason
    end
  end

  test "routing credits question job time, tokens and spend to its policy" do
    rule = @scenario.rule(key: "ask_orchestrator_first", origin: "shipped")
    task = @scenario.task(state: "working", builder: @builder)
    acknowledge(task)
    asked = seat("ask_question", @builder, "id" => task.id, "text" => "Sample question?",
      "assumption" => "Sample assumption", "blocking" => false)
    assert asked.completed?
    job_id = seat("claim_job", @orchestrator).result.fetch("job_id")
    assert seat("submit_job_result", @orchestrator, "id" => job_id, "tokens" => 37, "spend" => 0.25,
      "result" => { "outcome" => "answered", "basis" => "record", "answer" => "Sample answer" }).completed?

    job = Job.find(job_id)
    timing = Leverage::Reads::RuleTiming.call(@scenario.workspace_id, rule_id: rule.id).sole
    assert_equal [ 1, 37, 0.25 ], timing.values_at("attempts", "tokens", "spend")
    assert_equal({ "applied" => 1 }, timing.fetch("results"))
    assert_in_delta (job.claimed_at - job.queued_at), timing.fetch("queue_seconds"), 0.000_001
    assert_in_delta (job.finished_at - job.claimed_at), timing.fetch("run_seconds"), 0.000_001
    stats = Leverage::Reads::Rules.call(@scenario.workspace_id).fetch(:rules).sole.fetch(:stats)
    assert_equal [ 1, 37, 0.25 ], stats.values_at(:checks, :tokens, :spend)
  end

  test "a released and offered action gets a fresh briefing before it can start" do
    task = pass_review("send")
    action = Action.find_by!(task_id: task.id)
    assert owner("approve_action", action).completed?
    assert_equal "action", Leverage::Reads::NextItem.call(@builder).fetch("kind")
    acknowledge(task)
    original = task.reload.lease_due_at

    assert seat("release", @builder, "id" => task.id, "reason" => "unable_to_continue").completed?
    released = event(task, "task.released")
    unconfirmed = event(task, "hold.opened")
    assert_equal released.id, unconfirmed.cause_id

    assert owner("offer_task_again", task).completed?
    assert_equal @builder.id, event(task, "hold.closed").payload.fetch("lease_seat_id")
    assert_operator task.reload.lease_due_at, :>, original
    assert_nil task.resume_pending_since
    assert_equal "action", Leverage::Reads::NextItem.call(@builder).fetch("kind")
    assert_equal "briefing_not_acknowledged", action_call("start_action", task, action).refusal&.code
    acknowledge(task)
    assert action_call("start_action", task, action).completed?
    assert action_call("report_action_done", task, action).completed?
    assert_equal "done", task.reload.state
  end

  %w[change_seat remove_seat].each do |command|
    test "#{command} opens a second hold for the approved action under an owner hold" do
      task = pass_review("send")
      action = Action.find_by!(task_id: task.id)
      assert owner("approve_action", action).completed?
      assert owner("hold", task, "note" => "Sample pause").completed?
      assert owner(command, @builder, (command == "change_seat" ? { "enabled" => false } : {})).completed?
      holds = Leverage::Holds.open_holds(task)
      assert_equal %w[action_unconfirmed owner_hold], holds.map(&:reason).sort
      unconfirmed = holds.find { |hold| hold.reason == "action_unconfirmed" }
      item = Leverage::Reads::Inbox.call(@scenario.workspace_id).fetch(:items).find { |row| row[:hold_id] == unconfirmed.id }
      refute_includes item.fetch(:choices), "offer_again"
      assert owner("resume", task).completed?
      assert_equal [ "action_unconfirmed" ], Leverage::Holds.open_holds(task).map(&:reason)
      assert_equal @builder.id, task.reload.holder_seat_id
      assert_equal "invalid_state", owner("offer_task_again", task).refusal&.code
    end
  end

  test "the action lease follows the previous builder as soon as other work is released" do
    task = pass_review("send")
    occupied = @scenario.task(state: "working", builder: @builder)
    action = Action.find_by!(task_id: task.id)
    assert owner("approve_action", action).completed?
    assert_nil task.reload.holder_seat_id
    assert_nil event(task, "action.approved").payload.fetch("lease_seat_id")

    assert seat("release", @builder, "id" => occupied.id, "reason" => "unable_to_continue").completed?

    assert_equal @builder.id, task.reload.holder_seat_id
    granted = event(task, "action.lease_granted")
    assert_equal @builder.id, granted.payload.fetch("lease_seat_id")
    assert_equal event(occupied, "task.released").id, granted.cause_id
    assert_equal "action", Leverage::Reads::NextItem.call(@builder).fetch("kind")
  end

  test "a late blocking question timeout pauses the lease before the later lease expiry" do
    task = @scenario.task(state: "working", builder: @builder)
    question = @scenario.question(task, blocking: true)
    job = @scenario.job(kind: "question", task: task, target: question, attempt_number: 2)
    deadline = Leverage::Timers.job_due_at(job, :queue)
    task.update!(lease_due_at: deadline + 30)
    lock = Leverage::WorkspaceLock
    original = lock.method(:clock)
    lock.define_singleton_method(:clock) { deadline + 90 }

    assert seat("report_cost", @builder, "id" => task.id, "spend" => 0, "tokens" => 0).completed?

    assert_equal "working", task.reload.state
    assert_equal @builder.id, task.holder_seat_id
    assert_nil task.lease_due_at
    assert_equal 30, task.lease_time_left_while_paused
    assert_equal deadline, event(task, "hold.opened").effective_at
    assert_nil event(task, "task.lease_expired")
    assert_equal "passed_on", question.reload.outcome
  ensure
    lock.define_singleton_method(:clock, original) if original
  end

  test "waiving a stopped action retains the already acknowledged Finishing lease" do
    task, first, other = two_approved_actions
    acknowledge(task)
    assert owner("stop_action", first, "reason" => "Sample stop").completed?
    assert_nil task.reload.lease_due_at
    remaining = task.lease_time_left_while_paused
    assert_operator remaining, :>, 0

    assert owner("waive_action", first).completed?

    assert_equal [ "waived", "approved" ], [ first.reload.state, other.reload.state ]
    assert_equal [ "finishing", 0, @builder.id, @builder.id ],
      task.reload.attributes.values_at("state", "round", "builder_seat_id", "holder_seat_id")
    closed = event(task, "hold.closed")
    # Compare at PostgreSQL's resolution. Subtracting the times as floats
    # can put a difference of one microsecond just outside the tolerance.
    resumed_microseconds = (task.lease_due_at.to_r - closed.effective_at.to_r) * 1_000_000
    assert_in_delta (remaining.to_f * 1_000_000).round, resumed_microseconds, 1
    assert_nil event(task, "action.waived").payload.fetch("lease_seat_id")
    assert_nil closed.payload.fetch("lease_seat_id")
    assert_equal "resume", Leverage::Reads::NextItem.call(@builder).fetch("kind")
  end

  [ "pending", "free", "busy" ].each do |availability|
    test "waive leaves the other action with approvals or builder #{availability}" do
      task = pass_review("send", "publish")
      first, other = Action.where(task_id: task.id).order(:position).to_a
      assert owner("approve_action", other).completed? unless availability == "pending"
      @scenario.task(state: "working", builder: @builder) if availability == "busy"
      assert owner("stop_action", first, "reason" => "Sample stop").completed?

      assert owner("waive_action", first).completed?

      expected_holder = @builder.id if availability == "free"
      assert_equal [ "finishing", 0, @builder.id, expected_holder ],
        task.reload.attributes.values_at("state", "round", "builder_seat_id", "holder_seat_id")
      assert_equal [ "waived", availability == "pending" ? "requested" : "approved" ], [ first.reload.state, other.reload.state ]
      waived = event(task, "action.waived")
      assert_equal [ expected_holder, 0 ], [ waived.payload.fetch("lease_seat_id"), waived.round ]
      expected_holds = availability == "pending" ? [ "owner_approval" ] : []
      assert_equal expected_holds, Leverage::Holds.open_holds(task).map(&:reason)
    end
  end

  [ false, true ].each do |paused|
    test "return for rework #{paused ? 'releases a paused builder and closes its seat hold' : 'replaces the retained Finishing lease'}" do
      task, first, other = two_approved_actions
      acknowledge(task)
      assert owner("stop_action", first, "reason" => "Sample stop").completed?
      assert owner("pause_seat", @builder).completed? if paused
      seat_hold = Hold.find_by!(task_id: task.id, reason: "seat_paused", closed_at: nil) if paused
      criterion = Criterion.find_by!(task_id: task.id, kind: "build", removed_at: nil)

      assert owner("return_for_rework", task, "criterion_ids" => [ criterion.id ]).completed?

      returned = event(task, "task.returned_for_rework")
      expected_seat = @builder.id unless paused
      assert_equal [ paused ? "ready" : "working", 1, expected_seat, expected_seat ],
        task.reload.attributes.values_at("state", "round", "builder_seat_id", "holder_seat_id")
      assert_equal [ expected_seat, 0 ], [ returned.payload.fetch("lease_seat_id"), returned.round ]
      related = Event.where(task_id: task.id, command_id: returned.command_id).order(:seq)
      assert_equal [ 0 ], related.pluck(:round).uniq
      assert_equal [ first.id, other.id ], related.where(type: "action.withdrawn").pluck(:subject_id)
      assert_equal %w[contracted contracted], [ first.reload.state, other.reload.state ]
      assert_equal "open", criterion.reload.state
      assert_empty Leverage::Holds.open_holds(task)
      assert_nil task.lease_time_left_while_paused
      if paused
        assert_nil task.lease_due_at
        closed = related.find_by!(type: "hold.closed", subject_id: seat_hold.id)
        assert_equal [ "owner", @scenario.owner.id, "seat_paused" ],
          [ closed.actor_kind, closed.actor_id, closed.payload.fetch("reason") ]
        row = Leverage::Contract.state_machine.fetch("groups").find { |group| group["id"] == "return_for_rework" }
          .fetch("rows").find { |entry| entry.fetch("guard").include?("builder_busy") }
        assert_includes row.fetch("holds_closed"), closed.payload.fetch("reason")
      else
        assert_equal returned.at + @scenario.workspace.lease_length_seconds, task.lease_due_at
        assert_equal "rework", Leverage::Reads::NextItem.call(@builder).fetch("kind")
      end
    end
  end

  [ "free", "busy", "retained" ].each do |availability|
    test "mark done leaves another approved action with the builder #{availability}" do
      task, first, other = two_approved_actions
      if availability == "retained"
        acknowledge(task)
        assert owner("change_seat", @builder, "enabled" => false).completed?
        assert owner("change_seat", @builder, "enabled" => true).completed?
      else
        assert seat("release", @builder, "id" => task.id, "reason" => "unable_to_continue").completed?
        @scenario.task(state: "working", builder: @builder) if availability == "busy"
      end
      hold = Hold.find_by!(task_id: task.id, reason: "action_unconfirmed", closed_at: nil)

      assert owner("mark_action_done", first).completed?

      assert_equal [ "done", "approved" ], [ first.reload.state, other.reload.state ]
      close = event(task, "hold.closed")
      assert_equal hold.id, close.subject_id
      assert_equal %w[action.marked_done hold.closed inbox.resolved],
        Event.where(task_id: task.id, command_id: close.command_id).order(:seq).pluck(:type)
      expected_holder = @builder.id unless availability == "busy"
      fresh_seat = @builder.id if availability == "free"
      assert_equal [ "finishing", 0, @builder.id, expected_holder ],
        task.reload.attributes.values_at("state", "round", "builder_seat_id", "holder_seat_id")
      assert_equal [ fresh_seat, 0 ], [ close.payload.fetch("lease_seat_id"), close.round ]
      assert_empty Leverage::Holds.open_holds(task)
    end
  end

  %w[change_seat remove_seat].product(%w[mark_action_done waive_action]).each do |loss, settlement|
    test "#{settlement} keeps remaining actions unconfirmed after #{loss}" do
      task, first, other = two_approved_actions
      acknowledge(task)
      assert owner(loss, @builder, loss == "change_seat" ? { "enabled" => false } : {}).completed?

      assert owner(settlement, first).completed?

      holds = Leverage::Holds.open_holds(task)
      assert_equal [ "action_unconfirmed" ], holds.map(&:reason)
      hold = holds.sole
      item = InboxItem.find_by!(hold_id: hold.id, state: "open")
      assert_equal "unconfirmed_action", item.kind
      assert_equal [ other.id ], item.facts.fetch("action_ids")
      assert_equal "approved", other.reload.state
      %w[start_action report_action_done].each do |command|
        assert_equal "on_hold", action_call(command, task, other).refusal&.code
      end
    end
  end

  test "cancel takes precedence over an action's state for its former holder" do
    task, first, = two_approved_actions
    acknowledge(task)
    assert action_call("start_action", task, first).completed?
    assert owner("cancel", task).completed?

    %w[start_action report_action_done].each do |command|
      assert_equal "task_cancelled", action_call(command, task, first).refusal&.code
    end
  end

  test "an Approval item is answered by Stop before the stopped action can be waived" do
    task = pass_review("publish")
    action = Action.find_by!(task_id: task.id)
    item = InboxItem.find_by!(about_id: task.id, kind: "approval", state: "open")

    assert_equal "invalid_state", owner("waive_action", action).refusal&.code
    assert_equal "open", item.reload.state
    assert_equal "requested", action.reload.state

    assert owner("stop_action", action, "reason" => "Sample stop").completed?
    resolution = Event.where(subject_id: item.id, type: "inbox.resolved").sole
    assert_equal "stop", resolution.payload.fetch("choice")
    assert owner("waive_action", action).completed?
    assert_equal "done", task.reload.state
  end

  %w[review report_action_done waive_action].product(%w[queued claimed]).each do |completion, state|
    test "a #{state} question job is withdrawn when #{completion} ends its task" do
      if completion == "review"
        task = @scenario.task(state: "in_review", builder: @builder, reviewer: @reviewer)
      else
        task = pass_review("publish")
        action = Action.find_by!(task_id: task.id)
        assert owner("approve_action", action).completed?
        acknowledge(task)
      end
      question = @scenario.question(task, blocking: true)
      job = @scenario.job(kind: "question", task: task, target: question, attempt_number: 2, state: state,
        seat: (state == "claimed" ? @orchestrator : nil))
      deadline = Leverage::Timers.job_due_at(job, state == "queued" ? :queue : :run)

      case completion
      when "review"
        assert_passed_review(task)
      when "report_action_done"
        assert action_call("start_action", task, action).completed?
        assert action_call("report_action_done", task, action).completed?
      when "waive_action"
        assert owner("waive_action", action).completed?
      end

      assert_equal "done", task.reload.state
      if state == "claimed"
        submitted = seat("submit_job_result", @orchestrator, "id" => job.id, "tokens" => 0, "spend" => 0,
          "result" => { "outcome" => "passed_on", "basis" => nil, "answer" => nil })
        assert_equal "invalid_state", submitted.refusal&.code
      end
      timer = state == "queued" ? "question_job_queue_timeout" : "question_job_run_timeout"
      at_workspace_time(deadline + 1) { assert app(timer).completed? }

      assert_equal "withdrawn", job.reload.state
      assert_equal "open", question.reload.outcome
      assert_empty Leverage::Holds.open_holds(task)
      assert_empty InboxItem.where(about_id: task.id, state: "open")
    end
  end

  test "mark done closes the unconfirmed hold while a different action still needs a decision" do
    task, first, other = two_approved_actions
    assert seat("release", @builder, "id" => task.id, "reason" => "unable_to_continue").completed?
    assert owner("stop_action", other, "reason" => "Sample stop").completed?

    assert owner("mark_action_done", first).completed?

    assert_equal [ "done", "stopped" ], [ first.reload.state, other.reload.state ]
    assert_equal [ "finishing", @builder.id, nil ], task.reload.attributes.values_at("state", "builder_seat_id", "holder_seat_id")
    assert_equal [ "action_stopped" ], Leverage::Holds.open_holds(task).map(&:reason)
    assert_equal "action_unconfirmed", event(task, "hold.closed").payload.fetch("reason")
    assert_nil event(task, "hold.closed").payload.fetch("lease_seat_id")
  end

  test "offer closes the hold when the builder is busy and waits for its other work to finish" do
    task, = two_approved_actions
    assert seat("release", @builder, "id" => task.id, "reason" => "unable_to_continue").completed?
    occupied = @scenario.task(state: "working", builder: @builder)

    assert owner("offer_task_again", task).completed?

    assert_nil event(task, "hold.closed").payload.fetch("lease_seat_id")
    assert_nil task.reload.holder_seat_id
    assert_empty Leverage::Holds.open_holds(task)
    assert seat("release", @builder, "id" => occupied.id, "reason" => "unable_to_continue").completed?
    assert_equal [ "finishing", @builder.id, @builder.id ],
      task.reload.attributes.values_at("state", "builder_seat_id", "holder_seat_id")
    assert_equal event(occupied, "task.released").id, event(task, "action.lease_granted").cause_id
  end

  test "offer after re-enabling a retained builder replaces its lease and requires a new briefing" do
    task, first, = two_approved_actions
    acknowledge(task)
    original_due = task.reload.lease_due_at
    assert owner("change_seat", @builder, "enabled" => false).completed?
    assert_equal "invalid_state", owner("offer_task_again", task).refusal&.code
    assert owner("change_seat", @builder, "enabled" => true).completed?

    assert owner("offer_task_again", task).completed?

    assert_equal @builder.id, event(task, "hold.closed").payload.fetch("lease_seat_id")
    assert_equal [ "finishing", 0, @builder.id, @builder.id ],
      task.reload.attributes.values_at("state", "round", "builder_seat_id", "holder_seat_id")
    assert_operator task.lease_due_at, :>, original_due
    assert_equal "briefing_not_acknowledged", action_call("start_action", task, first).refusal&.code
  end

  test "offer after re-enabling a retained builder leaves a signed-out login on hold" do
    login = @scenario.credential
    @builder = @scenario.seat(credential: login)
    task, = two_approved_actions
    assert apply("report_signed_out", "helper", @scenario.helper, "id" => login.id, "credential_id" => login.id,
      "seat_id" => @builder.id, "task_id" => task.id, "observed_at" => @scenario.database_now.utc.iso8601(6),
      "tool_version" => "0.0.0-example").completed?
    assert owner("change_seat", @builder, "enabled" => false).completed?
    assert owner("change_seat", @builder, "enabled" => true).completed?

    assert owner("offer_task_again", task).completed?

    assert_equal [ "credential_signed_out" ], Leverage::Holds.open_holds(task).map(&:reason)
    assert_equal @builder.id, task.reload.holder_seat_id
    assert_nil task.lease_due_at
    assert_equal @scenario.workspace.lease_length_seconds, task.lease_time_left_while_paused
  end

  test "a former builder cannot take an unconfirmed action after changing roles" do
    task, action, = two_approved_actions
    acknowledge(task)
    assert action_call("start_action", task, action).completed?
    assert seat("release", @builder, "id" => task.id, "reason" => "unable_to_continue").completed?
    assert owner("change_seat", @builder, "role" => "reviewer").completed?

    rejected = owner("offer_task_again", task)
    item = Leverage::Reads::TaskPage.call(@scenario.workspace_id, task.id).fetch(:inbox_items)
      .find { |candidate| candidate[:kind] == "unconfirmed_action" }

    assert_equal "invalid_state", rejected.refusal&.code
    refute_includes item.fetch(:choices), "offer_again"
    assert owner("mark_action_done", action).completed?
  end

  test "changing the role of a paused previous builder opens an unconfirmed action" do
    task = pass_review("send")
    action = Action.find_by!(task_id: task.id)
    assert owner("pause_seat", @builder).completed?
    assert owner("approve_action", action).completed?
    assert_nil task.reload.holder_seat_id
    assert_empty Leverage::Holds.open_holds(task)

    assert owner("change_seat", @builder, "role" => "reviewer").completed?

    assert_equal [ "action_unconfirmed" ], Leverage::Holds.open_holds(task).map(&:reason)
    assert owner("mark_action_done", action).completed?
    assert_equal "done", task.reload.state
  end

  test "waiving an action withdraws its errored gate and leaves other approved work available" do
    @scenario.rule(hook: "action.requested", scope_kind: "action_kinds", scope_values: [ "send" ])
    task = pass_review("send", "publish")
    action, other = Leverage::Actions.for_task(task).to_a
    assert owner("approve_action", other).completed?
    check = RuleCheck.find_by!(subject_id: action.id)
    attempts = Job.where(task_id: task.id, kind: "rule_check")
    deadline = Leverage::Timers.job_due_at(attempts.sole, :queue)
    at_workspace_time(deadline) { assert app("check_queue_timeout").completed? }
    deadline = Leverage::Timers.job_due_at(attempts.find_by!(attempt_number: 2), :queue)
    at_workspace_time(deadline) do
      assert Leverage::Transitions::RecordPoll.seat(@orchestrator)
      assert app("check_queue_timeout").completed?
    end
    hold = Hold.find_by!(task_id: task.id, reason: "check_error", rule_check_id: check.id, closed_at: nil)
    item = InboxItem.find_by!(hold_id: hold.id, state: "open")

    at_workspace_time(deadline + 1) { assert owner("waive_action", action).completed? }

    assert_equal "withdrawn", check.reload.result
    assert hold.reload.closed_at
    assert_equal "resolved", item.reload.state
    assert_equal "approved", other.reload.state
    assert_equal @builder.id, task.reload.holder_seat_id
  end

  test "the second approval timeout leaves the owner the decision when the orchestrator returns" do
    @scenario.rule(key: "orchestrator_approves_actions", origin: "shipped")
    task = pass_review("send")
    action = Action.find_by!(task_id: task.id)
    check = RuleCheck.find_by!(subject_id: action.id)
    attempts = Job.where(task_id: task.id, kind: "approval")
    deadline = Leverage::Timers.job_due_at(attempts.sole, :queue)
    at_workspace_time(deadline - 1) { assert app("orchestrator_offline").completed? }
    offline = InboxItem.find_by!(workspace_id: @scenario.workspace_id, kind: "orchestrator_offline", state: "open")
    at_workspace_time(deadline) { assert app("check_queue_timeout").completed? }
    assert_equal [ [ 1, "timed_out" ], [ 2, "queued" ] ], attempts.order(:attempt_number).pluck(:attempt_number, :state)
    second = attempts.find_by!(attempt_number: 2)
    deadline = Leverage::Timers.job_due_at(second, :queue)
    at_workspace_time(deadline) { assert app("check_queue_timeout").completed? }
    assert_equal [ "error", "timed_out" ], [ check.reload.result, second.reload.state ]
    assert Hold.exists?(task_id: task.id, reason: "owner_approval", closed_at: nil)
    refute Hold.exists?(task_id: task.id, reason: "check_error", closed_at: nil)

    at_workspace_time(deadline + 1) do
      assert Leverage::Transitions::RecordPoll.seat(@orchestrator)
      assert Leverage::RolePresence.online?(@scenario.workspace, "orchestrator", deadline + 1)
      polling = seat("claim_job", @orchestrator)
      assert_equal "not_eligible", polling.refusal&.code
      assert app("orchestrator_offline").completed?
      assert_equal "resolved", offline.reload.state
      assert_equal [ [ 1, "timed_out" ], [ 2, "timed_out" ] ], attempts.order(:attempt_number).pluck(:attempt_number, :state)
      assert owner("approve_action", action).completed?
    end
    assert_equal "approved", action.reload.state
  end

  test "the task page identifies the check that stopped the real action" do
    gate = @scenario.rule(hook: "action.requested")
    task = pass_review("send")
    job = seat("claim_job", @orchestrator).result.fetch("job_id")
    assert seat("submit_job_result", @orchestrator, "id" => job,
      "result" => { "result" => "failed", "reason" => "Sample failure" }, "tokens" => 0, "spend" => 0).completed?
    action = Action.find_by!(task_id: task.id)
    check = RuleCheck.find_by!(task_id: task.id, rule_id: gate.id)
    page = Leverage::Reads::TaskPage.call(@scenario.workspace_id, task.id)

    assert_equal [ action.id, "stopped", check.id ], page.fetch(:actions).sole.values_at(:id, :state, :stopped_by_rule_check_id)
    assert_equal check.id, page.fetch(:inbox_items).find { |item| item[:kind] == "stopped_action" }.fetch(:facts).fetch("rule_check_id")
  end

  private

  def two_approved_actions
    task = pass_review("send", "publish")
    first, other = Action.where(task_id: task.id).order(:position).to_a
    assert owner("approve_action", first).completed?
    assert owner("approve_action", other).completed?
    [ task, first, other ]
  end

  def app(command)
    apply(command, nil, nil, {})
  end

  def at_workspace_time(at)
    lock = Leverage::WorkspaceLock
    original = lock.method(:clock)
    lock.define_singleton_method(:clock) { at }
    yield
  ensure
    lock.define_singleton_method(:clock, original)
  end

  def pass_review(*kinds)
    task = @scenario.task(state: "in_review", builder: @builder, reviewer: @reviewer,
      actions: kinds.map { |kind| { kind: kind, description: "Sample action" } })
    assert_passed_review(task)
    assert_equal(kinds.empty? ? "done" : "finishing", task.reload.state)
    task
  end

  def assert_passed_review(task)
    review = @scenario.review(task, reviewer: @reviewer)
    assert seat("acknowledge_review_briefing", @reviewer, "id" => review.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: @reviewer, review: review)).completed?
    assert seat("pass_review", @reviewer, "id" => review.id, "verdict" => "passed",
      "failed_criteria" => [], "notes" => "Sample review", "tokens" => 0, "spend" => 0).completed?
  end

  def acknowledge(task)
    assert seat("acknowledge_briefing", @builder, "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: @builder)).completed?
  end

  def action_call(command, task, action)
    seat(command, @builder, "id" => task.id, "aid" => action.id)
  end

  def event(task, type)
    Event.where(task_id: task.id, type: type).order(:seq).last
  end

  def owner(command, target, params = {})
    apply(command, "owner", @scenario.owner, params.merge("id" => target.id))
  end

  def seat(command, caller, params = {})
    apply(command, "seat", caller, params)
  end

  def apply(command, kind, caller, params)
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id,
      caller_kind: kind, caller_id: caller&.id, key: (SecureRandom.uuid if kind),
      request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end
end
