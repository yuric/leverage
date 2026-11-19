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
  # L694-L697): each may start the run on another credential.
  CREDENTIAL_HOLD_RELEASES = %w[credential_hold_release report_reading report_request_result].freeze
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

  # For each (command, from) the guards of its rows cover every case exactly
  # once: every assignment of the guard families the rows name is matched by
  # one row, and a family a row does not name does not matter to it.
  def test_guards_partition_each_command_and_state
    family_of = machine["guard_families"].each_with_object({}) do |family, map|
      family["guards"].each { |guard| map[guard["guard"]] = family["family"] }
    end
    members = machine["guard_families"].to_h { |family| [ family["family"], family["guards"].map { |guard| guard["guard"] } ] }
    rows.group_by { |row| [ row["command"], row["from"] ] }.each do |(command, from), same|
      same.each do |row|
        assert_empty duplicates(row["guard"].map { |guard| family_of[guard] }), "#{label(row)} names a family twice"
      end
      families = same.flat_map { |row| row["guard"].map { |guard| family_of[guard] } }.uniq
      assignments = families.map { |family| members[family] }.then { |lists| lists.empty? ? [ [] ] : lists[0].product(*lists[1..]) }
      assignments.each do |assignment|
        matched = same.count { |row| (row["guard"] - assignment).empty? }
        assert_equal 1, matched, "#{command} from #{from.inspect}: #{assignment.inspect} matches #{matched} rows"
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
