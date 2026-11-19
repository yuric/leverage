require_relative "contract_helper"

# steps.json: the step kinds and the events that open and close each. Names,
# classes and subjects are compared with the PRD's Step kinds table by
# scripts/check_contract_tables.py; here the file is checked against
# registry.json.
class StepsTest < Minitest::Test
  include ContractTestHelpers

  # Plan SM-41: every event that can open wait_ready carries wait_cause in
  # its payload. payload_schemas_test.rb holds the same list for the payloads.
  WAIT_CAUSE_EVENTS = %w[task.ready task.released task.lease_expired review.failed task.reassigned
                         task.returned_for_rework hold.closed check.finished].freeze

  def steps = Leverage::Contract.steps.fetch("steps")
  def step(kind) = steps.find { |entry| entry["kind"] == kind }
  def event_types = registry["event_types"].map { |entry| entry["type"] }

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("steps", Leverage::Contract.steps)
  end

  def test_kinds_equal_the_registry_step_kinds
    assert_equal registry["step_kinds"], steps.map { |entry| entry["kind"] }
  end

  def test_classes_subjects_and_causes_are_registered
    steps.each do |entry|
      assert_includes Leverage::Contract.list("step_classes"), entry["class"], entry["kind"]
      entry["subject_kinds"].each do |kind|
        assert(kind.nil? || Leverage::Contract.list("step_subject_kinds").include?(kind), "#{entry["kind"]}: #{kind}")
      end
      entry["cause_kinds"].each { |kind| assert_includes Leverage::Contract.list("step_cause_kinds"), kind, entry["kind"] }
    end
  end

  def test_opening_and_closing_events_are_registered
    steps.each do |entry|
      refute_empty entry["opened_by"], entry["kind"]
      refute_empty entry["closed_by"], entry["kind"]
      (entry["opened_by"] + entry["closed_by"]).each do |boundary|
        assert_includes event_types, boundary["event"], entry["kind"]
      end
    end
    Leverage::Contract.steps["close_without_opening"].each { |event| assert_includes event_types, event }
  end

  def test_each_hold_step_opens_and_closes_on_hold_events
    registry["hold_reasons"].map { |entry| entry["step"] }.uniq.each do |kind|
      assert_includes step(kind)["opened_by"].map { |boundary| boundary["event"] }, "hold.opened", kind
      assert_includes step(kind)["closed_by"].map { |boundary| boundary["event"] }, "hold.closed", kind
    end
  end

  def test_wait_ready_opens_only_on_events_that_carry_its_cause
    opened_by = step("wait_ready")["opened_by"].map { |boundary| boundary["event"] }.uniq
    assert_equal WAIT_CAUSE_EVENTS.sort, opened_by.sort
    assert_equal [ "credential_limit" ], step("wait_ready")["cause_kinds"]
  end

  # A check step's subject is the first action waiting on its checks (SM-27)
  # and is fixed when the step opens (PRD Rules for steps, rule 8). When that
  # action is approved while a later one still waits, its step closes and a
  # new one opens on the next action at the same event.
  def test_a_check_step_moves_to_the_next_action_by_closing_and_opening
    assert_includes step("check")["closed_by"].map { |boundary| boundary["event"] }, "action.approved"
    assert_includes step("check")["opened_by"].map { |boundary| boundary["event"] }, "action.approved"
  end

  def test_the_step_table_sentence_of_the_prd_is_kept
    # L306: action.lease_granted keeps wait_builder open, so it opens and
    # closes no step.
    steps.each do |entry|
      (entry["opened_by"] + entry["closed_by"]).each do |boundary|
        refute_equal "action.lease_granted", boundary["event"], entry["kind"]
      end
    end
    assert_includes step("wait_builder")["closed_by"].map { |boundary| boundary["event"] }, "task.briefing_acknowledged"
    assert_includes step("rework")["closed_by"].map { |boundary| boundary["event"] }, "task.submitted"
  end
end
