require "test_helper"

class StateTableFinishingTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  COMMANDS = %w[request_action approve_action stop_action grant_action_lease start_action report_action_done].freeze
  WORK = %w[start_action report_action_done].freeze

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat
    @owner = @scenario.owner
  end

  StateTableCases.define(self, COMMANDS) do |kase|
    task, action = prepare(kase)
    request = request_for(kase.command, task, action)
    outcome = T.apply(request)
    if kase.refusal
      assert_equal kase.refusal, outcome.refusal&.code
    else
      assert outcome.completed?, outcome.refusal&.code
      assert_equal kase.to, task.reload.state
      events = Event.where(task_id: task.id, command_id: request.key).where("seq > ?", @before).order(:seq).to_a
      assert_equal kase.events, events.map(&:type).select { |type| kase.events.include?(type) }
      if kase.builder_lease == "fresh"
        assert_equal @builder.id, task.holder_seat_id
        assert task.lease_due_at
        assert_equal @builder.id, events.find { |event| kase.events.include?(event.type) }.payload.fetch("lease_seat_id")
      end
      if kase.guard.include?("builder_busy")
        assert_nil task.holder_seat_id
        assert_nil events.find { |event| event.type == "action.approved" }.payload.fetch("lease_seat_id")
      end
      assert_nil task.holder_seat_id if kase.to == "done"
    end
  end

  test "finishing work calls require the current acknowledgement and respect holds" do
    WORK.each do |command|
      task = finishing(command == "start_action" ? "approved" : "started", builder: @scenario.seat)
      action = Action.find_by!(task_id: task.id)
      assert_equal "briefing_not_acknowledged", T.apply(request_for(command, task, action)).refusal&.code
      @scenario.hold(task, reason: "owner_hold")
      assert_equal "on_hold", T.apply(request_for(command, task, action)).refusal&.code
    end
  end

  test "the owner cannot approve a stopped action" do
    task = finishing("stopped")
    action = Action.find_by!(task_id: task.id)
    assert_equal "invalid_state", T.apply(request_for("approve_action", task, action)).refusal&.code
    assert_equal "stopped", action.reload.state
  end

  test "approval answers only the matching action hold" do
    task = finishing("requested", "requested")
    first, second = Action.where(task_id: task.id).order(:position)
    other = approval_hold(task, second)
    assert_equal "invalid_state", T.apply(request_for("approve_action", task, first)).refusal.code

    own = approval_hold(task, first)
    assert T.apply(request_for("approve_action", task, first)).completed?
    assert_equal "approved", first.reload.state
    assert own.reload.closed_at
    assert_nil other.reload.closed_at
    assert_nil task.reload.holder_seat_id
  end

  test "a finished approval job cannot be replayed through the action entries" do
    task = finishing("requested")
    action = Action.find_by!(task_id: task.id)
    orchestrator = @scenario.orchestrator
    rule = @scenario.rule(key: "orchestrator_approves_actions", origin: "shipped")
    job = completed_approval(task, action, rule, orchestrator, "approved")
    %w[approve_action stop_action].each do |command|
      params = { id: action.id, job_id: job.id }
      request = T::Request.new(command: command, workspace_id: task.workspace_id, caller_kind: "seat",
        caller_id: orchestrator.id, key: "key-#{SecureRandom.hex(6)}",
        request_hash: Digest::SHA256.hexdigest(params.to_json), params: params)
      assert_equal "invalid_state", T.apply(request).refusal.code
    end
    assert_equal "requested", action.reload.state
  end

  test "an approval job can only run the action command for its recorded decision" do
    orchestrator = @scenario.orchestrator
    rule = @scenario.rule(key: "orchestrator_approves_actions", origin: "shipped")

    { "approved" => "stop_action", "stopped" => "approve_action" }.each do |effect, wrong_command|
      task = finishing("requested")
      action = Action.find_by!(task_id: task.id)
      job = completed_approval(task, action, rule, orchestrator, effect)
      key = "key-#{SecureRandom.hex(6)}"
      request = T::Request.new(command: "submit_job_result", workspace_id: task.workspace_id, caller_kind: "seat",
        caller_id: orchestrator.id, key: key, request_hash: nil, params: { id: job.id })
      ctx = @scenario.context(request: request)
      ctx.emit("job.finished", task: task, subject: job, payload: {})

      assert_equal :refused, T.run_as(ctx, wrong_command, requester: orchestrator, key: key,
        params: { id: action.id, job_id: job.id })
      assert_equal "requested", action.reload.state
    end
  end

  private

  def prepare(kase)
    task = kase.invalid_state? ? non_finishing(kase.from) : finishing_for_row(kase)
    action = Action.find_by!(task_id: task.id, position: 1)
    if kase.command == "approve_action" && kase.row && kase.refusal.nil?
      approval_hold(task, action)
    end
    if task.holder_seat_id && WORK.include?(kase.command)
      lease = Leverage::Briefing.lease_event(task, seat: @builder)
      BriefingAcknowledgement.create!(workspace_id: task.workspace_id, task_id: task.id, seat_id: @builder.id,
        lease_event_id: lease.id, briefing_hash: Leverage::Briefing.hash_for(task, seat: @builder),
        acknowledged_at: @scenario.database_now)
    end
    @before = Event.where(workspace_id: @scenario.workspace_id).maximum(:seq)
    [ task, action ]
  end

  def completed_approval(task, action, rule, orchestrator, effect)
    check = @scenario.rule_check(task, rule: rule, subject: action, checker: orchestrator, result: "applied",
      effect: effect)
    job = Job.find(RuleCheckAttempt.find_by!(rule_check_id: check.id).job_id)
    job.update!(kind: "approval")
    job
  end

  def approval_hold(task, action)
    Leverage::Holds.open(@scenario.context, task: task, reason: "owner_approval", action_id: action.id,
      facts: { action_id: action.id })
  end

  def non_finishing(state)
    task = @scenario.task(state: state, builder: @builder)
    Action.find_by(task_id: task.id, position: 1) || Action.create!(workspace_id: task.workspace_id, task_id: task.id,
      kind: "publish", description: "Publish the made-up sample", position: 1)
    task
  end

  def finishing_for_row(kase)
    case kase.command
    when "approve_action"
      states = kase.guard.include?("approvals_pending") ? %w[requested requested] : %w[requested]
      task = finishing(*states)
      @scenario.task(state: "working", builder: @builder) if kase.guard.include?("builder_busy")
      task
    when "grant_action_lease"
      finishing("approved", holder: false)
    when "start_action"
      finishing("approved")
    when "report_action_done"
      finishing(*(kase.guard.include?("last_open_action") ? %w[started] : %w[started approved]))
    else
      finishing("requested")
    end
  end

  def finishing(*states, builder: @builder, holder: nil)
    @scenario.finishing_task(builder: builder, holder: holder, actions: states.map do |state|
      { description: "Publish the made-up sample", state: state }
    end)
  end

  def request_for(command, task, action)
    params, caller = case command
    when "request_action" then [ { id: action.id }, nil ]
    when "grant_action_lease" then [ { id: task.id }, nil ]
    when *WORK then [ { id: task.id, aid: action.id }, (Seat.find_by(id: task.builder_seat_id) || @builder) ]
    else [ { id: action.id }, @owner ]
    end
    kind = caller.is_a?(User) ? "owner" : ("seat" if caller)
    T::Request.new(command: command, workspace_id: task.workspace_id, caller_kind: kind, caller_id: caller&.id,
      key: ("key-#{SecureRandom.hex(6)}" if caller), request_hash: Digest::SHA256.hexdigest(params.to_json), params: params)
  end
end
