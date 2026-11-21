require_relative "contract_helper"

# state_machine.json: the table of states and commands. Its PRD rows are
# compared with the PRD's lifecycle table by scripts/check_contract_tables.py;
# here only its shape and its consistency with registry.json are checked, so
# the test holds no copy of a PRD table.
class StateMachineTest < Minitest::Test
  include ContractTestHelpers

  # The events that set the task's holder when they give a builder a fresh
  # lease, and the events that clear it (plan DB-43).
  FRESH_LEASE_EVENTS = %w[review.failed action.approved action.lease_granted task.returned_for_rework
                          hold.closed action.waived].freeze
  HOLDER_CLEARING_EVENTS = %w[task.submitted task.released task.lease_expired task.returned task.cancelled].freeze
  # The commands that close a credential hold and let the run go on (L118,
  # L694-L697): each may start the run on another credential. A change of
  # the seat's credential is one of them (milestone 3 plan HE-10, HE-27).
  CREDENTIAL_HOLD_RELEASES = %w[credential_hold_release report_reading report_request_result change_seat].freeze
  CREDENTIAL_HOLDS = %w[credential_limit credential_signed_out].freeze

  def machine = Leverage::Contract.state_machine
  def groups = machine.fetch("groups")
  def rows = groups.flat_map { |group| group.fetch("rows") }
  def task_states = Leverage::Contract.list("task_states")
  def event_types = registry["event_types"].map { |entry| entry["type"] }
  def side_event_types = registry["event_types"].select { |entry| entry["written_as_side_event"] }.map { |entry| entry["type"] }
  def hold_reasons = registry["hold_reasons"].map { |entry| entry["reason"] }
  def family_guards = machine["guard_families"].flat_map { |family| family["guards"].map { |guard| guard["guard"] } }
  def condition_guards = machine["guard_conditions"].map { |guard| guard["guard"] }

  def label(row)
    "#{row["command"]} from #{row["from"].inspect} #{row["guard"].inspect}"
  end

  def all_events(row)
    row["events"] + row["conditional_events"].map { |entry| entry["event"] } +
      row["side_events"].map { |entry| entry["event"] }
  end

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("state_machine", machine)
  end

  def test_its_commands_equal_the_registry_commands
    assert_equal registry["commands"].sort, rows.map { |row| row["command"] }.uniq.sort
    listed = machine["commands"].map { |entry| entry["command"] }
    assert_empty duplicates(listed)
    assert_equal registry["commands"].sort, listed.sort
  end

  def test_group_ids_are_unique
    assert_empty duplicates(groups.map { |group| group["id"] })
  end

  def test_states_hooks_events_refusals_and_callers_are_registered
    callers = Leverage::Contract.list("operation_callers") + Leverage::Contract.list("seat_roles") + [ "app" ]
    refusals = registry["refusals"].map { |entry| entry["code"] }
    rows.each do |row|
      [ row["from"], row["to"] ].compact.each { |state| assert_includes task_states, state, label(row) }
      assert(row["hook"].nil? || registry["hooks"].include?(row["hook"]), "#{label(row)}: hook #{row["hook"]}")
      all_events(row).each { |event| assert_includes event_types, event, label(row) }
      assert(row["refusal"].nil? || refusals.include?(row["refusal"]), label(row))
      row["who"].each { |who| assert_includes callers, who, label(row) }
      (row["holds_opened"] + row["holds_closed"]).each { |reason| assert_includes hold_reasons, reason, label(row) }
    end
  end

  def test_every_registry_guard_is_defined_once
    defined = family_guards + condition_guards
    assert_empty duplicates(defined)
    assert_equal registry["guards"].sort, defined.sort
  end

  def test_rows_split_only_on_family_guards_and_conditions_name_guards
    rows.each do |row|
      row["guard"].each { |guard| assert_includes family_guards, guard, label(row) }
      row["conditional_events"].each { |entry| assert_includes registry["guards"], entry["when"], label(row) }
      row["side_events"].each do |entry|
        assert(entry["when"].nil? || registry["guards"].include?(entry["when"]), label(row))
      end
    end
  end

  # For each (command, from), every reachable assignment matches one row.
  # A guard family a row does not name does not matter to it.
  def test_guards_partition_each_command_and_state
    family_of = machine["guard_families"].each_with_object({}) do |family, map|
      family["guards"].each { |guard| map[guard["guard"]] = family["family"] }
    end
    members = machine["guard_families"].to_h { |family| [ family["family"], family["guards"].map { |guard| guard["guard"] } ] }
    holder_exclusions = {
      "fail_review" => %w[does_not_escalate builder_holds_task],
      "approve_action" => %w[approval_asked_of_caller approvals_complete builder_holds_task]
    }
    rows.group_by { |row| [ row["command"], row["from"] ] }.each do |(command, from), same|
      same.each do |row|
        assert_empty duplicates(row["guard"].map { |guard| family_of[guard] }), "#{label(row)} names a family twice"
      end
      families = same.flat_map { |row| row["guard"].map { |guard| family_of[guard] } }.uniq
      assignments = families.map { |family| members[family] }.then { |lists| lists.empty? ? [ [] ] : lists[0].product(*lists[1..]) }
      assignments.each do |assignment|
        matched = same.count { |row| (row["guard"] - assignment).empty? }
        # AE-16: these paths cannot start with the builder holding this task.
        # Check that the rest of each guard partition still has exactly one row.
        excluded = holder_exclusions[command]
        if excluded && (excluded - assignment).empty?
          assert_equal 0, matched, "#{command} from #{from.inspect}: #{assignment.inspect} must be unreachable"
          assert same.any? { |row| row["note"].to_s.include?("cannot hold this task") }, command
        else
          assert_equal 1, matched, "#{command} from #{from.inspect}: #{assignment.inspect} matches #{matched} rows"
        end
      end
    end
  end

  def test_a_command_is_either_bound_to_task_states_or_not
    rows.group_by { |row| row["command"] }.each do |command, same|
      next if command == "add_task" # creates the task: from none to a state

      kinds = same.map { |row| row["from"].nil? }.uniq
      assert_equal 1, kinds.size, "#{command} mixes rows with and without a from-state"
    end
  end

  def test_refused_rows_change_nothing_and_others_name_their_target
    rows.each do |row|
      if row["refusal"]
        assert_nil row["to"], label(row)
        assert_empty all_events(row), label(row)
        assert_nil row["builder_lease"], label(row)
      elsif row["from"]
        refute_nil row["to"], label(row)
      end
    end
  end

  def test_a_pair_with_no_row_is_refused_with_invalid_state
    assert_equal "invalid_state", machine["unlisted_pair_refusal"]
    stated = rows.map { |row| [ row["command"], row["from"] ] }
    # Plan SM-2 and SM-3: no hold in Done or Cancelled, no cancel in
    # Cancelled, no contract edit in Imaginarium, Finishing or Done.
    [ %w[hold done], %w[hold cancelled], %w[cancel cancelled], %w[cancel done], %w[edit_contract imaginarium],
      %w[edit_contract finishing], %w[edit_contract done] ].each do |pair|
      refute_includes stated, pair
    end
  end

  def test_an_empty_row_says_why
    rows.each do |row|
      next if row["refusal"] || !all_events(row).empty?

      refute_nil row["note"], "#{label(row)} writes no event and gives no note"
    end
  end

  def test_side_events_are_registry_side_events_or_declared_exceptions
    exceptions = machine["side_event_exceptions"].map { |entry| entry["event"] }
    exceptions.each { |event| refute_includes side_event_types, event, "#{event} needs no exception" }
    rows.each do |row|
      row["side_events"].each do |entry|
        assert_includes side_event_types + exceptions, entry["event"], label(row)
      end
    end
  end

  def test_every_event_type_is_written_by_some_row
    written = rows.flat_map { |row| all_events(row) }.uniq
    assert_empty event_types - written
  end

  def test_every_hold_reason_is_opened_and_closed_by_some_row
    assert_empty hold_reasons - rows.flat_map { |row| row["holds_opened"] }
    assert_empty hold_reasons - rows.flat_map { |row| row["holds_closed"] }
    rows.each do |row|
      assert_includes all_events(row), "hold.opened", label(row) unless row["holds_opened"].empty?
      assert_includes all_events(row), "hold.closed", label(row) unless row["holds_closed"].empty?
    end
  end

  def test_holder_events_match_the_builder_lease
    rows.each do |row|
      events = all_events(row)
      assert_equal "claim", row["builder_lease"], label(row) if events.include?("task.claimed")
      if row["builder_lease"] == "fresh"
        refute_empty events & FRESH_LEASE_EVENTS, "#{label(row)} grants a lease with no event that sets the holder"
      end
      next if row["refusal"] || (row["events"] & HOLDER_CLEARING_EVENTS).empty?

      assert_equal "ends", row["builder_lease"], label(row)
    end
  end

  # Replay sets the holder from the event that grants a fresh lease (DB-43,
  # SM-7), so each such event names the seat in its payload.
  def test_every_event_that_grants_a_fresh_lease_names_the_seat
    FRESH_LEASE_EVENTS.each do |type|
      schema = Leverage::Contract.payload_schema(type, 1)
      assert_includes schema.fetch("required"), "lease_seat_id", type
    end
  end

  def test_a_task_back_in_working_has_a_fresh_lease
    rows.each do |row|
      next unless row["to"] == "working" && %w[in_review finishing].include?(row["from"])

      assert_equal "fresh", row["builder_lease"], label(row)
    end
  end

  # SM-7: a fresh lease, or a credential hold that lifts, may start the run
  # on another credential than the one last recorded for the task (L688).
  def test_fresh_leases_and_credential_hold_releases_may_switch_credential
    switching = rows.select do |row|
      row["builder_lease"] == "fresh" ||
        (CREDENTIAL_HOLD_RELEASES.include?(row["command"]) && !(row["holds_closed"] & CREDENTIAL_HOLDS).empty?)
    end
    refute_empty switching
    switching.each do |row|
      assert row["side_events"].any? { |entry| entry["event"] == "credential.switched" && entry["when"] == "credential_differs" },
        "#{label(row)} lacks credential.switched when credential_differs"
    end
  end

  def test_command_attributes_name_registered_commands
    machine["commands"].each do |entry|
      next unless entry["allowed_while_pending"]

      refute entry["work_call"], "#{entry["command"]}: a work call is refused while a transition is pending"
    end
  end

  def written(row) = row["events"] + row["conditional_events"].map { |entry| entry["event"] }

  def guard_action_states
    (machine["guard_families"].flat_map { |family| family["guards"] } + machine["guard_conditions"])
      .to_h { |guard| [ guard["guard"], guard["action_states"] ] }.compact
  end

  # L144: overturning an approval stops the action whether or not it has
  # started. Every action event a row writes is a move of the action
  # sub-machine for that command, from every action state its guards admit.
  def test_every_action_event_a_row_writes_is_a_move_of_the_action_machine
    family = machine["guard_families"].find { |entry| entry["family"] == "approved_action_state" }
    family["guards"].each { |guard| refute_nil guard["action_states"], "#{guard["guard"]} names its action states" }
    by_event = machine.fetch("action_machine").fetch("transitions").group_by { |move| move["event"] }
    rows.each do |row|
      written(row).each do |event|
        moves = by_event[event] or next
        matching = moves.select { |move| move["commands"].include?(row["command"]) }
        refute_empty matching, "#{label(row)} writes #{event}"
        from = matching.flat_map { |move| move["from"] }
        row["guard"].each do |guard|
          states = guard_action_states[guard] or next
          assert_empty states - from, "#{label(row)}: #{guard} admits #{states}, but #{event} moves only from #{from}"
        end
      end
    end
  end

  # L139: when no action waits for a decision and none is stopped, the
  # previous builder gets a fresh lease if it holds nothing. A row that
  # settles an action and leaves the task in Finishing splits on that.
  def test_a_row_that_settles_an_action_applies_the_lease_rule_of_l139
    rows.each do |row|
      next if row["refusal"] || row["to"] == "done"
      next if (written(row) & %w[action.approved action.waived action.marked_done]).empty?

      refute_empty row["guard"] & %w[approvals_pending approvals_complete], "#{label(row)} names no approvals guard"
      next unless row["guard"].include?("approvals_complete")

      refute_empty row["guard"] & %w[builder_free builder_busy builder_holds_task], "#{label(row)} names no builder guard"
      assert_equal "fresh", row["builder_lease"], label(row) if row["guard"].include?("builder_free")
      assert_nil row["builder_lease"], label(row) if row["guard"].include?("builder_holds_task")
    end
  end

  # L162, L205, L377: cancelling a pending transition withdraws its checks,
  # and a withdrawn check closes its check_error hold.
  def test_a_row_that_cancels_a_pending_transition_closes_its_check_error_hold
    cancelling = rows.select do |row|
      row["side_events"].any? { |entry| entry["event"] == "check.finished" && entry["note"].to_s.include?("pending transition this cancels") }
    end
    refute_empty cancelling
    cancelling.each do |row|
      assert_includes row["holds_closed"], "check_error", label(row)
      assert_includes all_events(row), "inbox.resolved", label(row)
    end
  end

  # L399, L698: a limit or sign-out reported for a job's run reads no task
  # state; with no candidate the job is left to its run timeout.
  def test_a_report_about_a_jobs_run_reads_no_task_state
    operations = registry["operations"].to_h { |op| [ op["operation_id"], op ] }
    { "report_job_limit" => [ "credential.limit_reached", "report_limit" ],
      "report_job_signed_out" => [ "credential.signed_out", "report_signed_out" ] }.each do |command, (event, operation)|
      same = rows.select { |row| row["command"] == command }
      assert_equal [ %w[candidate_available], %w[no_candidate_available] ], same.map { |row| row["guard"] }.sort, command
      same.each do |row|
        assert_nil row["from"], label(row)
        assert_empty row["holds_opened"], label(row)
        assert_equal [ "helper" ], row["who"], label(row)
        assert_includes row["events"], event, label(row)
      end
      assert_includes same.find { |row| row["guard"] == %w[candidate_available] }["events"], "credential.switched"
      assert_includes operations.fetch(operation)["commands"], command
    end
  end

  # L146, L148: only a change that disables the seat takes its task away.
  # A change of the seat's credential may also close its credential hold
  # and resume the task (milestone 3 plan HE-10, HE-27): those side events,
  # and the SM-42 re-evaluation, are the only others.
  def test_a_seat_change_releases_and_withdraws_only_when_it_disables_the_seat
    row = rows.find { |candidate| candidate["command"] == "change_seat" }
    released = row["conditional_events"].find { |entry| entry["event"] == "task.released" }
    assert_equal "disables_seat_holding_working_task", released["when"]
    row["side_events"].each do |entry|
      next if entry["event"].start_with?("inbox.") && entry["note"].to_s.include?("SM-42")
      next if %w[hold.closed credential.switched inbox.resolved].include?(entry["event"]) && entry["note"].to_s.include?("HE-27")
      next if %w[hold.opened inbox.opened].include?(entry["event"]) &&
        entry["note"].include?("changes from builder to another role")

      assert_equal "seat_disabled_by_change", entry["when"], "change_seat writes #{entry["event"]} on any change"
    end
  end

  def test_a_waive_closes_the_errored_gate_of_its_action
    rows.select { |row| row["command"] == "waive_action" && row["refusal"].nil? }.each do |row|
      assert_includes row["holds_closed"], "check_error", label(row)
    end
  end

  # L160: a task in a paused project is held with project_paused.
  def test_a_task_added_to_or_moved_into_a_paused_project_is_held
    rows.select { |row| %w[add_task change_task_project].include?(row["command"]) }.each do |row|
      assert_includes row["holds_opened"], "project_paused", label(row)
      assert row["side_events"].any? { |entry| entry["event"] == "hold.opened" && entry["when"] == "target_project_paused" }, label(row)
    end
    move = rows.find { |row| row["command"] == "change_task_project" }
    assert_includes move["holds_closed"], "project_paused"
    assert move["side_events"].any? { |entry| entry["event"] == "hold.closed" && entry["when"] == "source_project_paused" }
  end

  def test_the_action_sub_machine_uses_registered_states_events_and_commands
    action = machine.fetch("action_machine")
    states = Leverage::Contract.list("action_states")
    assert_equal states.sort, action["states"].sort
    action["transitions"].each do |transition|
      (transition["from"] + [ transition["to"] ]).each { |state| assert_includes states, state, transition.inspect }
      assert_includes event_types, transition["event"]
      transition["commands"].each { |command| assert_includes registry["commands"], command }
    end
    assert_empty (states - %w[contracted]) - action["transitions"].map { |transition| transition["to"] }
  end
end
