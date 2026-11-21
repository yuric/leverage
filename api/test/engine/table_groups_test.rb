require "test_helper"

# The table of entries and their groups through Questions and approvals
# (milestone 5 plan AT-6).
#
# It also pins the seams the other packages of milestone 4 finished (the
# hand-over table of plan §4): their names and required arguments, and
# what each answers when nothing waits. And it keeps milestone 3's pins of
# the seams that milestone finished.
class TableGroupsTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  Table = T::Table
  RouteTable = Leverage::Http::RouteTable

  # Milestone 4's twenty entries by their group (plan §2.1).
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

  # Milestone 3's twelve, in their groups (milestone 3 plan HT-6).
  MILESTONE_3 = {
    "HANDOFF" => %w[report_limit report_signed_out sign_in_again],
    "OWNER_CONTROLS" => %w[promote edit_contract hold resume pause_seat resume_seat change_seat]
  }.freeze

  def registry = Leverage::Contract.registry

  def required(method) = method.parameters.select { |kind, _name| %i[req keyreq].include?(kind) }

  # --- Transitions::Table --------------------------------------------------------

  MILESTONE_5_TIMERS = %w[question_job_queue_timeout question_job_run_timeout].freeze

  MILESTONE_5 = {
    "FINISHING" => %w[request_action grant_action_lease approve_action stop_action start_action report_action_done
                      waive_action mark_action_done offer_task_again return_for_rework overturn_approval],
    "QUESTIONS" => %w[ask_question request_access answer_question overturn_answer grant_access],
    "PROJECTS" => %w[report_cost create_project edit_brief pause_project resume_project change_budget
                     change_task_priority change_task_project change_task_cap],
    "WORKSPACE" => %w[delete_content change_workspace_settings]
  }.freeze

  test "the Questions and approvals commands are served in their groups" do
    assert_equal 97, Table::COMMANDS.size
    assert_equal registry.fetch("commands").sort, (Table::COMMANDS + Table::PENDING).sort
    assert_equal MILESTONE_5_TIMERS, Table::TIMERS.last(2)
    MILESTONE_5.each do |group, commands|
      assert Table.const_defined?(group, false), group
      assert_equal commands, Table.const_get(group), group
    end
  end

  test "each Questions and approvals command has its named entry class" do
    (MILESTONE_5.values.flatten + MILESTONE_5_TIMERS).each do |command|
      assert Table.include?(command), command
      assert_includes Table::COMMANDS, command
      entry = Table.entry_for(command)
      assert_equal Table.class_name(command), entry.name
      assert_equal command, entry.command
      assert_operator entry, :<, T::Entry
      assert_operator entry, :<, T::JobTimer if command.end_with?("_timeout")
    end
  end

  test "the table names 97 distinct served commands with registry rows" do
    with_rows = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
      .map { |row| row.fetch("command") }

    assert_equal 97, Table::COMMANDS.size
    assert_equal Table::COMMANDS.uniq, Table::COMMANDS
    Table::COMMANDS.each do |command|
      assert_includes registry.fetch("commands"), command
      assert_includes with_rows, command
    end
  end

  test "the twenty new commands are each in the group the plan names" do
    assert_equal NEW_COMMANDS.fetch("RULES"), Table::RULES
    assert_equal NEW_COMMANDS.fetch("CHECKS"), Table::CHECKS
    assert_equal NEW_COMMANDS.fetch("JOBS"), Table::JOBS
    assert_equal NEW_TIMERS, Table::TIMERS.drop(5).first(6)
    NEW_COMMANDS.each do |group, commands|
      assert_empty commands - Table.const_get(group), group
    end
  end

  test "entry_for finds each new command, which include? and COMMANDS answer for" do
    NEW_COMMANDS.values.flatten.each do |command|
      assert Table.include?(command), command
      assert_includes Table::COMMANDS, command
      assert_equal Table.class_name(command), Table.entry_for(command).name
      assert_equal command, Table.entry_for(command).command
      assert_operator Table.entry_for(command), :<, T::Entry
    end
  end

  test "a served name is included, and an unknown name is neither included nor found" do
    assert Table.include?("claim")
    assert Table.include?(:claim)
    assert Table.include?("add_rule")
    refute Table.include?("made_up_command")
    assert_raises(Table::UnknownCommand) { Table.entry_for("made_up_command") }
    assert_raises(Table::UnknownCommand) { Table.with_entries("made_up_command" => T::Entry) { flunk "ran" } }
  end

  test "with_entries temporarily replaces a Questions and approvals entry" do
    assert Table.include?("ask_question")
    replacement = Class.new(T::Entry)
    Table.with_entries("ask_question" => replacement) do
      assert_equal replacement, Table.entry_for("ask_question")
      assert Table.include?("ask_question")
    end
    assert_equal Table.class_name("ask_question"), Table.entry_for("ask_question").name
  end

  test "with_entries accepts a new name" do
    replacement = Class.new(T::Entry)
    Table.with_entries("add_rule" => replacement) do
      assert_equal replacement, Table.entry_for("add_rule")
    end
    assert_equal "Leverage::Transitions::Entries::AddRule", Table.entry_for("add_rule").name
  end

  test "each entry is implemented and each new timer writes nothing when nothing is due" do
    ctx = Scenario.new.context
    timers = NEW_TIMERS + MILESTONE_5_TIMERS
    (NEW_COMMANDS.values.flatten + MILESTONE_5.values.flatten + MILESTONE_5_TIMERS).each do |command|
      source = Rails.root.join("lib/leverage/transitions/entries/#{command}.rb").read
      refute_match(/not built yet|NotImplementedError/, source, command)
      next unless timers.include?(command)

      assert Table.include?(command), command
      entry = Table.entry_for(command).new
      entry.load(ctx)
      entry.perform(ctx)
    end
    assert_empty ctx.events
  end

  test "milestone 3's twelve stay in their groups" do
    assert_equal MILESTONE_3.fetch("HANDOFF"), Table::HANDOFF
    assert_equal MILESTONE_3.fetch("OWNER_CONTROLS"), Table::OWNER_CONTROLS
    assert_equal %w[credential_hold_release seat_run_placement], Table::TIMERS.first(5).last(2)
  end

  # --- StateTableCases --------------------------------------------------------------

  test "each Rule checks command has a case for every row" do
    twenty = NEW_COMMANDS.values.flatten
    cases = StateTableCases.for(twenty)
    twenty.each do |command|
      StateTableCases.rows(command).each do |row|
        assert(cases.any? { |kase| kase.row == row }, "#{command}: #{row.inspect}")
      end
    end
  end

  test "Finishing cases keep their row and an unlisted state keeps its refusal" do
    cases = StateTableCases.for(%w[hold])
    finishing = cases.find { |kase| kase.from == "finishing" }
    done = cases.find { |kase| kase.from == "done" }

    refute finishing.invalid_state?
    assert_equal "finishing", finishing.to
    assert_nil finishing.refusal
    assert done.invalid_state?
    assert_equal "invalid_state", done.refusal
  end

  # --- Http::RouteTable -------------------------------------------------------------

  test "the twelve new operations are served, each by its controller and action" do
    NEW_OPERATIONS.each do |operation_id, target|
      assert RouteTable.serves?(operation_id), operation_id
      assert_equal target, RouteTable::ROUTES[operation_id], operation_id
    end
  end

  # submit_job_result and override_check can decide outward actions
  # (milestone 5). The app runs the timers and installs shipped rules.
  # The two job reports use milestone 3's report routes.
  test "the twelve Rule checks operations still name their commands and now decide outward actions" do
    commands = NEW_OPERATIONS.keys.flat_map do |operation_id|
      registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }.fetch("commands")
    end.uniq
    known = commands.select { |command| Table.include?(command) }

    expected = NEW_COMMANDS.values.flatten - NEW_TIMERS - %w[install_shipped_rules report_job_limit report_job_signed_out]
    assert_equal (expected + %w[complete_contract approve_action stop_action]).sort, known.sort
    assert_equal %w[read], commands - known
  end

  test "milestone 3's two report routes also run the two job reports" do
    %w[report_limit report_signed_out].zip(%w[report_job_limit report_job_signed_out]).each do |operation_id, job_command|
      commands = registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }.fetch("commands")
      assert RouteTable.serves?(operation_id), operation_id
      assert_includes commands, job_command
      assert Table.include?(job_command), job_command
    end
  end

  # --- Milestone 4's seams, finished (plan §4, hand-over table) -------------------

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

  # The seams WP4 to WP11 finished (WP1's request 2, settled by WP12): in
  # a workspace with no rule, job or poll they answer that nothing waits:
  # an orchestrator that never polled is not online (L401), no transition
  # is pending and a cancel of one that is not ends nothing, no job is
  # offered, and the reads have no rule.
  test "the finished seams answer that nothing waits in a workspace with no rule, job or poll" do
    scenario = Scenario.new
    task = scenario.task(state: "ready")
    seat = scenario.seat(role: "orchestrator", token: false)
    ctx = scenario.context

    refute Leverage::RolePresence.online?(scenario.workspace, "orchestrator", ctx.at)
    done = scenario.pending_transition(scenario.task(state: "ready"), command: "claim",
      requester: scenario.seat(role: "builder"), state: "completed")
    assert_nil Leverage::PendingTransitions.of(task)
    assert_nil Leverage::PendingTransitions.cancel(ctx, done, "invalid_state")
    assert_nil Leverage::Jobs.next_for(seat)
    assert_equal({ rules: [] }, Leverage::Reads::Rules.call(scenario.workspace_id))
    assert_equal [], Leverage::Reads::RuleTiming.call(scenario.workspace_id)
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
