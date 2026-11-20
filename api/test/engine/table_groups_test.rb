require "test_helper"

# The table of entries while milestone 4 is built (milestone 4 plan RT-6,
# §2.1, §0.1 fact 3), as milestone 3 built its own (its plan HT-6): the
# twenty new entries wait in Transitions::Table::PENDING, which
# Table.entry_for, Table.known? and Table.with_entries read and
# Table.include?, Table::COMMANDS and every walk of the table do not; the
# twelve new operations wait in Http::RouteTable::PENDING, out of ROUTES.
# Served and pending are counted together, so these tests hold before and
# after WP10 moves the operations. WP13 moves the entries into their
# groups, deletes both PENDING lists and rewrites what names them here.
#
# It also pins the first versions of the seams the other packages of
# milestone 4 finish (the hand-over table of plan §4): their names and
# required arguments. A package may add an optional argument; a required
# one, or a new name, is a change to the seam and is written in the notes.
# And it keeps milestone 3's pins of the seams that milestone finished.
class TableGroupsTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  Table = T::Table
  RouteTable = Leverage::Http::RouteTable

  # Milestone 4's twenty entries by the group each moves into (plan §2.1).
  NEW_COMMANDS = {
    "RULES" => %w[add_rule save_rule enable_rule disable_rule revert_rule remove_rule install_shipped_rules],
    "CHECKS" => %w[rerun_check override_check],
    "JOBS" => %w[draft_contract claim_job submit_job_result report_job_limit report_job_signed_out],
    "TIMERS" => %w[check_queue_timeout check_run_timeout contract_draft_job_queue_timeout contract_draft_job_run_timeout
                   orchestrator_offline reviewer_eligibility]
  }.freeze
  NEW_TIMERS = NEW_COMMANDS.fetch("TIMERS")

  # Milestone 4's twelve operations (plan §2.3), each to its controller and
  # action (plan §2.1, Controllers).
  NEW_OPERATIONS = {
    "claim_next_job" => "v1/agent/jobs#claim_next",
    "submit_job_result" => "v1/agent/jobs#result",
    "list_rules" => "v1/owner/rules#index",
    "add_rule" => "v1/owner/rules#create",
    "save_rule" => "v1/owner/rules#versions",
    "enable_rule" => "v1/owner/rules#enable",
    "disable_rule" => "v1/owner/rules#disable",
    "revert_rule" => "v1/owner/rules#revert",
    "remove_rule" => "v1/owner/rules#remove",
    "rerun_check" => "v1/owner/rule_checks#rerun",
    "override_check" => "v1/owner/rule_checks#override",
    "draft_contract" => "v1/owner/tasks#draft_contract"
  }.freeze

  # Milestone 3's twelve, now in their groups (milestone 3 plan HT-6).
  MILESTONE_3 = {
    "HANDOFF" => %w[report_limit report_signed_out sign_in_again],
    "OWNER_CONTROLS" => %w[promote edit_contract hold resume pause_seat resume_seat change_seat]
  }.freeze

  def registry = Leverage::Contract.registry

  def pending = Table.const_defined?(:PENDING, false) ? Table::PENDING : []

  def pending_groups = Table.const_defined?(:PENDING_GROUPS, false) ? Table::PENDING_GROUPS : {}

  def pending_operations = RouteTable.const_defined?(:PENDING, false) ? RouteTable::PENDING : {}

  def required(method) = method.parameters.select { |kind, _name| %i[req keyreq].include?(kind) }

  # --- Transitions::Table --------------------------------------------------------

  test "served and pending together are 68 commands, no name twice, each a registry command with rows" do
    all = Table::COMMANDS + pending
    with_rows = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
      .map { |row| row.fetch("command") }

    assert_equal 68, all.size
    assert_equal all.uniq, all
    all.each do |command|
      assert_includes registry.fetch("commands"), command
      assert_includes with_rows, command
    end
  end

  test "the twenty new commands are served or pending, and each pending one names the group it moves into" do
    twenty = NEW_COMMANDS.values.flatten
    assert_equal 20, twenty.size
    assert_equal twenty.sort, (twenty & (Table::COMMANDS + pending)).sort
    assert_equal pending.sort, pending_groups.values.flatten.sort
    pending_groups.each do |group, commands|
      assert_empty commands - NEW_COMMANDS.fetch(group), group
    end
  end

  test "entry_for and known? find a pending name; include? and COMMANDS do not" do
    assert_operator pending.size, :>, 0
    pending.each do |command|
      assert Table.known?(command), command
      refute Table.include?(command), command
      refute_includes Table::COMMANDS, command
      assert_equal Table.class_name(command), Table.entry_for(command).name
      assert_equal command, Table.entry_for(command).command
      assert_operator Table.entry_for(command), :<, T::Entry
    end
  end

  test "a served name is known, and a later milestone's name is neither known nor found" do
    assert Table.known?("claim")
    assert Table.known?(:claim)
    refute Table.known?("ask_question")
    refute Table.include?("ask_question")
    assert_raises(Table::UnknownCommand) { Table.entry_for("ask_question") }
    assert_raises(Table::UnknownCommand) { Table.with_entries("ask_question" => T::Entry) { flunk "ran" } }
  end

  test "with_entries accepts a pending name" do
    replacement = Class.new(T::Entry)
    Table.with_entries("add_rule" => replacement) do
      assert_equal replacement, Table.entry_for("add_rule")
    end
    assert_equal "Leverage::Transitions::Entries::AddRule", Table.entry_for("add_rule").name
  end

  # The first versions (plan §4, the hand-over table). WP6 to WP9 write
  # them; WP13 rewrites this case once none is left a stub.
  test "a pending timer's entry does nothing; a pending command's entry is not built yet" do
    ctx = Scenario.new.context
    pending.each do |command|
      entry = Table.entry_for(command).new
      if NEW_TIMERS.include?(command)
        entry.perform(ctx)
        assert_nil entry.result, command
      else
        error = assert_raises(NotImplementedError, command) { entry.perform(ctx) }
        assert_match(/not built yet/, error.message)
      end
    end
    assert_empty ctx.events
  end

  test "milestone 3's twelve stay in their groups" do
    assert_equal MILESTONE_3.fetch("HANDOFF"), Table::HANDOFF
    assert_equal MILESTONE_3.fetch("OWNER_CONTROLS"), Table::OWNER_CONTROLS
    assert_equal %w[credential_hold_release seat_run_placement], Table::TIMERS.first(5).last(2)
  end

  # --- StateTableCases --------------------------------------------------------------

  test "the twenty new commands have a case for every row, and none is a row not served" do
    twenty = NEW_COMMANDS.values.flatten
    cases = StateTableCases.for(twenty)
    twenty.each do |command|
      StateTableCases.rows(command).each do |row|
        assert(cases.any? { |kase| kase.row == row }, "#{command}: #{row.inspect}")
      end
    end
    assert_empty cases.select(&:not_served?).map(&:name)
  end

  test "every case of a row from Finishing is marked not served (HS-3), and no other" do
    cases = StateTableCases.for(MILESTONE_3.values.flatten)
    finishing = cases.select { |kase| kase.from == "finishing" && !kase.invalid_state? }

    assert_operator finishing.size, :>, 0
    finishing.each { |kase| assert kase.not_served?, kase.name }
    (cases - finishing).each { |kase| refute kase.not_served?, kase.name }
    assert_equal "invalid_state", finishing.first.expected_refusal
    assert_nil finishing.first.refusal, "the row itself moves the task; HS-3 is what refuses it"
  end

  test "a served case keeps its refusal as expected_refusal" do
    kase = StateTableCases.for(%w[hold]).find { |candidate| candidate.from == "done" }

    assert_equal kase.refusal, kase.expected_refusal
    refute kase.not_served?
  end

  # --- Http::RouteTable -------------------------------------------------------------

  test "served and pending operations are disjoint, and the twelve are one or the other" do
    assert_empty RouteTable::ROUTES.keys & pending_operations.keys
    assert_equal NEW_OPERATIONS.keys.sort, (NEW_OPERATIONS.keys & (RouteTable::ROUTES.keys + pending_operations.keys)).sort
    NEW_OPERATIONS.each do |operation_id, target|
      assert_equal target, RouteTable::ROUTES[operation_id] || pending_operations[operation_id], operation_id
    end
  end

  test "a pending operation is not served, and its route reads the registry's method and path" do
    routes = RouteTable.routes(pending_operations).index_by(&:operation_id)
    pending_operations.each_key do |operation_id|
      refute RouteTable.serves?(operation_id), operation_id
      operation = registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }
      assert_equal [ operation.fetch("method").downcase, operation.fetch("path").gsub(/\{([a-z]+)\}/, ':\1') ],
        [ routes.fetch(operation_id).verb, routes.fetch(operation_id).path ]
    end
  end

  # submit_job_result and override_check also name approve_action and
  # stop_action, which run only for an outward action (milestone 5).
  test "the commands of the twelve operations are the new commands but the timers, a read, or milestone 5's" do
    commands = NEW_OPERATIONS.keys.flat_map do |operation_id|
      registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }.fetch("commands")
    end.uniq
    known = commands.select { |command| Table.known?(command) }

    assert_equal (NEW_COMMANDS.values.flatten - NEW_TIMERS - %w[install_shipped_rules report_job_limit
                                                               report_job_signed_out]).sort.push("complete_contract").sort,
      known.sort
    assert_equal %w[approve_action read stop_action], (commands - known).sort
  end

  # --- The first versions of milestone 4's seams (plan §4, hand-over table) -------

  test "PendingTransitions, RuleChecks and Jobs have their names and required arguments" do
    expected = {
      Leverage::PendingTransitions => {
        store: [ [ :req, :ctx ], [ :req, :entry ], [ :req, :evaluation ], [ :req, :params ] ],
        reenter: [ [ :req, :ctx ], [ :req, :pending ], [ :req, :trigger ] ],
        complete: [ [ :req, :ctx ], [ :req, :pending ], [ :keyreq, :cause_id ] ],
        refuse: [ [ :req, :ctx ], [ :req, :pending ], [ :req, :decision ], [ :keyreq, :cause_id ] ],
        cancel: [ [ :req, :ctx ], [ :req, :pending ], [ :req, :code ] ],
        of: [ [ :req, :task ] ]
      },
      Leverage::RuleChecks => {
        write: [ [ :req, :ctx ], [ :req, :evaluation ], [ :keyreq, :task ] ],
        start: [ [ :req, :ctx ], [ :req, :check ], [ :keyreq, :job ], [ :keyreq, :seat ] ],
        finish: [ [ :req, :ctx ], [ :req, :check ], [ :keyreq, :result ], [ :keyreq, :reason ] ],
        error: [ [ :req, :ctx ], [ :req, :check ] ],
        withdraw: [ [ :req, :ctx ], [ :req, :check ] ],
        override: [ [ :req, :ctx ], [ :req, :check ], [ :keyreq, :user ], [ :keyreq, :reason ] ],
        new_attempt: [ [ :req, :ctx ], [ :req, :check ], [ :keyreq, :job ] ]
      },
      Leverage::Jobs => {
        queue: [ [ :req, :ctx ], [ :keyreq, :kind ], [ :keyreq, :task ], [ :keyreq, :target ], [ :keyreq, :seat_role ],
                 [ :keyreq, :input ] ],
        next_for: [ [ :req, :seat ] ],
        claim: [ [ :req, :ctx ], [ :req, :job ], [ :req, :seat ] ],
        finish: [ [ :req, :ctx ], [ :req, :job ], [ :keyreq, :result ], [ :keyreq, :tokens ], [ :keyreq, :spend ] ],
        time_out: [ [ :req, :ctx ], [ :req, :job ], [ :req, :kind ] ],
        requeue: [ [ :req, :ctx ], [ :req, :job ] ],
        withdraw: [ [ :req, :ctx ], [ :req, :job ] ]
      },
      Leverage::JobInputs => { for: [ [ :req, :job ] ] }
    }
    expected.each do |mod, methods|
      methods.each { |name, parameters| assert_equal parameters, required(mod.method(name)), "#{mod}.#{name}" }
    end
  end

  test "RolePresence, RuleRecords, ReviewerEligibility and the three reads have their names and required arguments" do
    expected = {
      Leverage::RolePresence => {
        online?: [ [ :req, :workspace ], [ :req, :role ], [ :req, :at ] ],
        offline_since: [ [ :req, :workspace ], [ :req, :role ], [ :req, :at ] ],
        cause_credential: [ [ :req, :workspace ], [ :req, :role ], [ :req, :at ] ]
      },
      Leverage::RuleRecords => {
        install_shipped: [ [ :req, :ctx ] ],
        add: [ [ :req, :ctx ], [ :req, :fields ] ],
        save: [ [ :req, :ctx ], [ :req, :rule ], [ :req, :fields ] ],
        enable: [ [ :req, :ctx ], [ :req, :rule ] ],
        disable: [ [ :req, :ctx ], [ :req, :rule ] ],
        revert: [ [ :req, :ctx ], [ :req, :rule ] ],
        remove: [ [ :req, :ctx ], [ :req, :rule ] ]
      },
      Leverage::ReviewerEligibility => {
        after_command: [ [ :req, :ctx ], [ :req, :entry ] ],
        reevaluate: [ [ :req, :ctx ] ]
      },
      Leverage::Reads::Rules => { call: [ [ :req, :workspace_id ] ] },
      Leverage::Reads::RuleTiming => { call: [ [ :req, :workspace_id ] ] },
      Leverage::Reads::TaskTimeline => { call: [ [ :req, :workspace_id ], [ :req, :task_id ] ] }
    }
    expected.each do |mod, methods|
      methods.each { |name, parameters| assert_equal parameters, required(mod.method(name)), "#{mod}.#{name}" }
    end
    assert_kind_of Array, Leverage::ReviewerEligibility::REEVALUATED_BY
    assert Leverage::ReviewerEligibility::REEVALUATED_BY.frozen?
  end

  test "Rules::Engine answers the seven calls of Gating with Gating's arguments" do
    engine = Leverage::Rules::Engine.new
    %i[evaluate reenter reenter_action briefing_rules built_by_providers provider_allowed? claimable_filter].each do |name|
      assert_equal Leverage::Gating.method(name).parameters, engine.method(name).parameters, name
    end
  end

  # The do-nothing answers WP4 to WP11 build against until each finishes
  # its file (plan §4, WP1's Produces).
  test "the first versions answer as the plan says: online, nothing pending, no job, empty reads" do
    scenario = Scenario.new
    task = scenario.task(state: "ready")
    seat = scenario.seat(role: "orchestrator")
    ctx = scenario.context

    assert Leverage::RolePresence.online?(scenario.workspace, "orchestrator", ctx.at)
    pending = scenario.pending_transition(scenario.task(state: "ready"), command: "claim",
      requester: scenario.seat(role: "builder"))
    assert_nil Leverage::PendingTransitions.of(task)
    assert_nil Leverage::PendingTransitions.cancel(ctx, pending, "invalid_state")
    assert_equal :completed, T.run_as(ctx, "claim", requester: seat, key: "made-up-key", params: {})
    assert_nil Leverage::Jobs.next_for(seat)
    assert_equal({ "rules" => [] }, Leverage::Reads::Rules.call(scenario.workspace_id))
    assert_equal [], Leverage::Reads::RuleTiming.call(scenario.workspace_id)
    assert_equal [], Leverage::Reads::TaskTimeline.call(scenario.workspace_id, task.id)
    assert_empty ctx.events
  end

  # --- Milestone 3's seams, which that milestone finished ----------------------------

  # Handoff.interrupt's arguments are not pinned here: WP6 may change them
  # (milestone 4 plan §0.1 fact 13). reevaluate answers the events it
  # wrote (none here).
  test "Handoff has its other three methods with their final arguments, and reevaluate writes nothing in an empty workspace" do
    handoff = Leverage::Handoff
    expected = {
      continue_or_hold: [ [ :req, :ctx ], [ :keyreq, :seat ], [ :keyreq, :stopped ], [ :keyreq, :cause ], [ :key, :task ],
                          [ :key, :review ] ],
      reevaluate: [ [ :req, :ctx ], [ :key, :tasks ], [ :key, :cause ], [ :key, :verified ], [ :key, :signed_out ],
                    [ :key, :choice ] ],
      switch: [ [ :req, :ctx ], [ :keyreq, :seat ], [ :keyreq, :to ], [ :keyreq, :from ], [ :keyreq, :cause ],
                [ :key, :task ], [ :key, :review ] ]
    }
    expected.each { |name, parameters| assert_equal parameters, handoff.method(name).parameters, name }
    assert handoff.respond_to?(:interrupt)
    assert_equal [], handoff.reevaluate(Scenario.new.context)
  end

  test "SeatRuns has placement, ensure_run_on and ended_by_interruption; placement answers the seat's own credential" do
    scenario = Scenario.new
    credential = scenario.credential
    seat = scenario.seat(credential: credential)
    placement = Leverage::SeatRuns.placement(seat)

    assert_equal [ credential.id, nil ], [ placement.credential&.id, placement.work ]
    assert_nil Leverage::SeatRuns.placement(scenario.seat(provider: "claude")).credential
    assert_equal [ [ :req, :ctx ], [ :req, :seat ], [ :req, :credential ], [ :req, :work ] ],
      Leverage::SeatRuns.method(:ensure_run_on).parameters
    assert_nil Leverage::SeatRuns.ensure_run_on(scenario.context, seat, credential, nil)
    assert_equal [ [ :req, :seat ], [ :req, :reason ] ], Leverage::SeatRuns.method(:ended_by_interruption).parameters
    assert_equal 0, HelperRequest.where(workspace_id: scenario.workspace_id).count
  end

  test "Reads::RecoveryTimes answers an empty list, for a task or for the workspace" do
    scenario = Scenario.new
    task = scenario.task(state: "working")

    assert_equal [], Leverage::Reads::RecoveryTimes.call(scenario.workspace_id)
    assert_equal [], Leverage::Reads::RecoveryTimes.call(scenario.workspace_id, task_id: task.id)
  end

  test "BackupRun is the model of backup_runs" do
    assert_equal "backup_runs", BackupRun.table_name
  end
end
