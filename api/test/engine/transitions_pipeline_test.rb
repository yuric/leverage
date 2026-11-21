require "test_helper"

# Leverage::Transitions.apply, the one way to change anything (milestone 2
# plan §2.1, EN-16, EN-17), proven with entries defined here: the real
# entries are other packages'. Each test maps a milestone-2 command name to
# one of these entries for the length of the test.
class TransitionsPipelineTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  # Adds a task and writes two events for it.
  class TwoEvents < Leverage::Transitions::Entry
    def perform(ctx)
      task = Task.create!(workspace_id: ctx.workspace.id, state: "backlog")
      ctx.emit("task.created", task: task, payload: { state: "backlog", added_action_ids: [] })
      ctx.emit("task.promoted", task: task, payload: {})
      @result = { "task_id" => task.id }
    end
  end

  # Writes an event whose payload its schema refuses, after a row.
  class BadPayload < Leverage::Transitions::Entry
    def perform(ctx)
      task = Task.create!(workspace_id: ctx.workspace.id, state: "backlog")
      ctx.emit("task.created", task: task, payload: { state: "backlog", added_action_ids: [] })
      ctx.emit("task.promoted", task: task, payload: { made_up: true })
    end
  end

  # Gives two causes; precedence must return lease_expired (1) before
  # invalid_state (5).
  class Refuses < Leverage::Transitions::Entry
    def refusals(_ctx) = [ T::Refusal.new(code: "invalid_state"), T::Refusal.new(code: "lease_expired") ]

    def perform(_ctx) = raise("a refused command must not perform")
  end

  # Returns a token once: it must not be stored.
  class GivesOnce < Leverage::Transitions::Entry
    def perform(ctx)
      @result = { "user_id" => ctx.request.caller_id, "created_at" => ctx.at.utc.iso8601(6) }
      @once = { "session_token" => "lvo_made-up-token-for-the-test" }
    end
  end

  # Runs at a hook, so the gate is asked.
  class AtHook < Leverage::Transitions::Entry
    def hook = "task.before_claim"
    def perform(_ctx) = @result = {}
  end

  # Records the gating calls it is asked.
  class RecordingGating < Leverage::Rules::Engine
    attr_reader :requests

    def initialize
      super
      @requests = []
    end

    def evaluate(request)
      @requests << request
      super
    end
  end

  # A gating answer milestone 2 cannot apply.
  class PendingGating < Leverage::Rules::Engine
    def evaluate(_request)
      Leverage::Gating::Evaluation.new(outcome: :pending, frozen_rule_version_ids: [], checks: [], jobs: [], failures: [],
        warnings: [], effects: [], holds_to_open: [])
    end
  end

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @performed = 0
  end

  def request(command: "add_task", key: "key-#{SecureRandom.hex(4)}", body: "{}", caller_kind: "owner", caller_id: @owner.id,
              workspace_id: @scenario.workspace_id)
    T::Request.new(command: command, workspace_id: workspace_id, caller_kind: caller_kind, caller_id: caller_id, key: key,
      request_hash: Leverage::Idempotency.request_hash(method: "POST", path: "/v1/owner/tasks", body: body), params: {})
  end

  def with_entry(entry, command: "add_task", &block)
    T::Table.with_entries(command => entry, &block)
  end

  def events = Event.where(workspace_id: @scenario.workspace_id).order(:seq)

  test "two events of one command share at and have consecutive seq" do
    with_entry(TwoEvents) do
      before = @scenario.workspace.reload.last_seq
      outcome = T.apply(request)

      assert_equal :completed, outcome.outcome
      written = events.where("seq > ?", before).to_a
      assert_equal [ before + 1, before + 2 ], written.map(&:seq)
      assert_equal 1, written.map(&:at).uniq.size
      assert_equal written.first.at, written.first.effective_at
      assert_equal before + 2, @scenario.workspace.reload.last_seq
      assert_equal outcome.result.fetch("task_id"), written.first.task_id
    end
  end

  test "an event carries the caller as its actor and the key as its command_id" do
    with_entry(TwoEvents) do
      outcome = T.apply(request(key: "made-up-key"))
      event = events.find_by(task_id: outcome.result.fetch("task_id"), type: "task.created")

      assert_equal [ "owner", @owner.id, "made-up-key", 0, nil ],
        [ event.actor_kind, event.actor_id, event.command_id, event.round, event.subject_kind ]
    end
  end

  test "a payload that fails its schema rolls everything back" do
    with_entry(BadPayload) do
      counts = -> { [ Task.count, Event.count, Command.count, @scenario.workspace.reload.last_seq ] }
      before = counts.call

      assert_raises(Leverage::EventLog::InvalidEvent) { T.apply(request) }
      assert_equal before, counts.call
    end
  end

  test "a repeat with the same key writes nothing and answers the stored outcome" do
    with_entry(TwoEvents) do
      first = T.apply(request(key: "repeat-me"))
      after_first = [ Event.count, Command.count, Task.count ]
      second = T.apply(request(key: "repeat-me"))

      assert_equal after_first, [ Event.count, Command.count, Task.count ]
      assert_equal first.result, second.result
      assert_equal :completed, second.outcome
    end
  end

  test "the same key with another body is key_reused and writes nothing" do
    with_entry(TwoEvents) do
      T.apply(request(key: "reuse-me", body: '{"a":1}'))
      before = [ Event.count, Command.count ]

      assert_raises(Leverage::Idempotency::KeyReused) { T.apply(request(key: "reuse-me", body: '{"a":2}')) }
      assert_equal before, [ Event.count, Command.count ]
    end
  end

  test "a refusal stores its commands row and nothing else, with the first cause by precedence" do
    with_entry(Refuses) do
      before = Event.count
      outcome = T.apply(request(key: "refused-key"))

      assert_equal :refused, outcome.outcome
      assert_equal "lease_expired", outcome.refusal.code
      assert_nil outcome.result
      assert_equal before, Event.count
      row = Command.find_by!(caller_kind: "owner", caller_id: @owner.id, key: "refused-key")
      assert_equal [ "add_task", "refused", { "code" => "lease_expired", "rule_id" => nil, "reason" => nil }, nil ],
        [ row.command, row.outcome, row.refusal, row.result ]

      repeated = T.apply(request(key: "refused-key"))
      assert_equal [ :refused, "lease_expired" ], [ repeated.outcome, repeated.refusal.code ]
    end
  end

  test "a value shown once is answered and never stored" do
    with_entry(GivesOnce, command: "sign_in") do
      outcome = T.apply(request(command: "sign_in", key: "once-key"))

      assert_equal "lvo_made-up-token-for-the-test", outcome.once.fetch("session_token")
      row = Command.find_by!(key: "once-key")
      assert_equal [ "created_at", "user_id" ], row.result.keys.sort

      repeat = T.apply(request(command: "sign_in", key: "once-key"))
      assert_nil repeat.once
      assert_equal row.result, repeat.result
    end
  end

  test "a command at a hook asks the gate, which completes with no rules" do
    gating = RecordingGating.new
    Leverage::Gating.implementation = gating
    with_entry(AtHook, command: "claim") do
      outcome = T.apply(request(command: "claim"))

      assert_equal :completed, outcome.outcome
      assert_equal [ "task.before_claim" ], gating.requests.map(&:hook)
      assert_equal [ "owner", @owner.id ], [ gating.requests.first.requester_kind, gating.requests.first.requester_id ]
    end
  end

  test "a gate answer milestone 2 cannot apply is an error, not a silent pass" do
    Leverage::Gating.implementation = PendingGating.new
    with_entry(AtHook, command: "claim") do
      assert_raises(T::Gate::Unsupported) { T.apply(request(command: "claim")) }
      assert_equal 0, Command.where(workspace_id: @scenario.workspace_id, command: "claim").count
    end
  end

  test "due timers are applied before the entry is asked for its refusals" do
    order = []
    entry = Class.new(Leverage::Transitions::Entry) do
      define_method(:refusals) do |_ctx|
        order << :refusals
        []
      end
      define_method(:perform) { |_ctx| order << :perform }
    end
    original = Leverage::Timers.method(:apply_due)
    Leverage::Timers.define_singleton_method(:apply_due) do |ctx|
      order << :timers
      original.call(ctx)
    end
    with_entry(entry) { T.apply(request) }

    assert_equal %i[timers refusals perform], order
  ensure
    Leverage::Timers.define_singleton_method(:apply_due, original) if original
  end

  test "a command run by the app stores no commands row" do
    with_entry(TwoEvents, command: "builder_lease_expiry") do
      before = Command.count
      outcome = T.apply(request(command: "builder_lease_expiry", key: nil, caller_kind: nil, caller_id: nil))

      assert_equal :completed, outcome.outcome
      assert_equal before, Command.count
      assert_equal [ "app", nil, nil ], events.last.then { |event| [ event.actor_kind, event.actor_id, event.command_id ] }
    end
  end

  # report_reading belongs to milestone 6.
  test "a command that is not in the table is refused before anything runs" do
    assert_raises(T::Table::UnknownCommand) { T.apply(request(command: "report_reading")) }
    assert_equal 0, Command.where(workspace_id: @scenario.workspace_id, command: "report_reading").count
  end

  test "a workspace that does not exist is not found" do
    with_entry(TwoEvents) do
      assert_raises(ActiveRecord::RecordNotFound) { T.apply(request(workspace_id: SecureRandom.uuid)) }
    end
  end

  test "one log line per command names the command, the outcome and the three timings, never a body" do
    with_entry(TwoEvents) do
      lines = capture_log { T.apply(request(key: "logged-key", body: '{"title":"secret title"}')) }
      line = lines.grep(/leverage\.command/).sole

      assert_match(/command=add_task caller=owner:#{@owner.id} key=logged-key outcome=completed refusal=-/, line)
      assert_match(/lock_wait_ms=\d+\.\d+ event_step_ms=\d+\.\d+ transition_ms=\d+\.\d+/, line)
      assert_no_match(/secret title/, line)
    end
  end

  test "the stand-in answers what a test scripts, without a database, and records the requests" do
    stand_in = T::StandIn.new
    stand_in.script("claim", T::Outcome.refused(T::Refusal.new(code: "not_eligible")))
    stand_in.script("submit") { |req| T::Outcome.completed({ "key" => req.key }) }

    T.with_stand_in(stand_in) do
      assert_equal "not_eligible", T.apply(request(command: "claim")).refusal.code
      assert_equal({ "key" => "k1" }, T.apply(request(command: "submit", key: "k1")).result)
      assert_raises(T::StandIn::NotScripted) { T.apply(request(command: "release")) }
    end
    assert_equal %w[claim submit release], stand_in.requests.map(&:command)
    assert_nil T.stand_in
    assert_equal 0, Command.where(workspace_id: @scenario.workspace_id, command: %w[claim submit]).count
  end

  test "precedence follows the registry, with not_eligible after every ranked code" do
    codes = %w[not_eligible duplicate_name invalid_state task_cancelled]
    assert_equal "task_cancelled", T::Precedence.first(codes.map { |code| T::Refusal.new(code: code) }).code
    assert_equal "duplicate_name", T::Precedence.first(%w[not_eligible duplicate_name]).code
    assert_nil T::Precedence.first([])
    assert_raises(ArgumentError) { T::Precedence.first(%w[made_up_code]) }
  end

  test "the table lists its commands in thirteen groups, each a registry command with state-table rows" do
    assert_equal 97, T::Table::COMMANDS.size
    groups = [ T::Table::TASK_LOOP, T::Table::TIMERS, T::Table::SIGN_IN, T::Table::ACCOUNTS, T::Table::HANDOFF,
               T::Table::OWNER_CONTROLS, T::Table::RULES, T::Table::CHECKS, T::Table::JOBS, T::Table::FINISHING,
               T::Table::QUESTIONS, T::Table::PROJECTS, T::Table::WORKSPACE ]
    assert_equal [ 17, 13, 4, 12, 3, 7, 7, 2, 5, 11, 5, 9, 2 ], groups.map(&:size)
    assert_equal T::Table::COMMANDS, groups.flatten
    assert_equal T::Table::COMMANDS.uniq, T::Table::COMMANDS
    commands_with_rows = Leverage::Contract.state_machine.fetch("groups").flat_map { |g| g.fetch("rows") }.map { |r| r.fetch("command") }
    T::Table::COMMANDS.each do |command|
      assert_includes Leverage::Contract.registry.fetch("commands"), command
      assert_includes commands_with_rows, command
    end
    assert_equal "Leverage::Transitions::Entries::AllowAnotherRound", T::Table.class_name("allow_another_round")
    assert T::Table.include?("claim")
    assert T::Table.include?("promote")
    assert T::Table.include?("add_rule")
    assert T::Table.include?("ask_question")
    refute T::Table.const_defined?(:PENDING, false)
  end

  test "an entry finds its state-table row, or invalid_state where none starts" do
    entry = Class.new(Leverage::Transitions::Entry) { def self.command = "fail_review" }.new

    assert_equal "working", entry.state_row("in_review", %w[does_not_escalate builder_free]).fetch("to")
    assert_equal "ready", entry.state_row("in_review", %w[does_not_escalate builder_busy]).fetch("to")
    assert_nil entry.state_row("working")
    assert_equal "invalid_state", entry.state_refusal("working").code
    assert_nil entry.state_refusal("in_review", %w[escalates])
  end

  test "state table cases cover every state of a command that reads one, and each row of one that does not" do
    cases = StateTableCases.for(%w[claim allow_another_round])
    claim = cases.select { |kase| kase.command == "claim" }

    assert_equal Leverage::Contract.list("task_states"), claim.map(&:from)
    assert_equal [ "ready" ], claim.reject(&:invalid_state?).map(&:from)
    assert_equal "invalid_state", claim.find { |kase| kase.from == "done" }.refusal
    assert_equal [ nil ], cases.select { |kase| kase.command == "allow_another_round" }.map(&:from)
    assert_equal "claim from ready to working", claim.find { |kase| kase.from == "ready" }.name
  end

  # The test support every engine package builds its state with. The
  # deferred state trigger checks each task at the test's end (test_helper).
  test "Scenario builds a task in each state it offers, each with an event of the task" do
    Scenario::TASK_STATES.each do |state|
      task = @scenario.task(state: state)
      assert_equal state, task.state
      assert Event.exists?(task_id: task.id, type: "task.created"), state
    end
    working = @scenario.task(state: "working")
    assert_equal [ working.holder_seat_id, false ], [ working.builder_seat_id, working.lease_due_at.nil? ]
    in_review = @scenario.task(state: "in_review")
    assert_equal [ 1, nil ], [ Review.where(task_id: in_review.id).count, in_review.holder_seat_id ]
    assert_raises(ArgumentError) { @scenario.task(state: "finishing") }
  end

  # Milestone 4 (its plan §0.1 fact 10) seeds rules: a custom rule's row
  # must carry its version fields (scenario_rules_test.rb has the rest).
  test "Scenario seeds a golden trace's setup with its ids, and refuses a rule it cannot build" do
    binder = Leverage::Contract::TraceBinder.new(start: Time.utc(2026, 11, 19))
    setup = binder.bind(Leverage::Contract.trace("10-leases-no-rules").fetch("setup"))
    scenario = Scenario.new.seed(setup)

    setup.fetch("seats").each do |row|
      seat = Seat.find(row.fetch("id"))
      assert_equal row.values_at("name", "role", "credential_id"), [ seat.name, seat.role, seat.credential_id ]
      assert scenario.token_for(seat)
    end
    setup.fetch("credentials").each { |row| assert_equal row.fetch("position"), Credential.find(row.fetch("id")).position }
    assert_equal setup.dig("users", 0, "id"), scenario.owner.id
    setup.fetch("settings").each { |column, value| assert_equal value, scenario.workspace.reload[column] }
    bare = { "id" => SecureRandom.uuid, "key" => "custom_bare", "origin" => "custom", "enabled" => true,
             "current_version" => 1, "current_version_id" => SecureRandom.uuid }
    assert_raises(ArgumentError) { Scenario.new.seed(setup.merge("rules" => [ bare ])) }
  end

  private

  def capture_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    original = Rails.logger
    Rails.logger = logger
    yield
    io.string.lines
  ensure
    Rails.logger = original
  end
end
