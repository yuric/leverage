require_relative "contract_helper"

# timers.json: every timer, its scope, the column its due time is read from
# and the events it writes (plan TM-1). The sweep triggers them and is not
# one of them.
class TimersTest < Minitest::Test
  include ContractTestHelpers

  # Plan TM-1, the timers the contract item "the timer list" asks for.
  TIMERS = %w[builder_lease_expiry review_lease_expiry check_queue_timeout check_run_timeout
              question_job_queue_timeout question_job_run_timeout contract_draft_job_queue_timeout
              contract_draft_job_run_timeout credential_hold_release orchestrator_offline reviewer_eligibility
              command_key_retention].freeze

  def timers = Leverage::Contract.timers.fetch("timers")
  def event_types = registry["event_types"].map { |entry| entry["type"] }

  def machine_rows(command)
    Leverage::Contract.state_machine["groups"].flat_map { |group| group["rows"] }.select { |row| row["command"] == command }
  end

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("timers", Leverage::Contract.timers)
  end

  def test_every_timer_of_the_list_once
    names = timers.map { |entry| entry["timer"] }
    assert_empty duplicates(names)
    assert_equal TIMERS.sort, names.sort
    names.each { |name| assert_includes registry["commands"], name }
  end

  def test_scope_and_due_time_source
    timers.each do |entry|
      assert_includes %w[task workspace], entry["scope"], entry["timer"]
      assert_includes registry["due_time_sources"], entry["due_at"]["source"], entry["timer"]
    end
  end

  def test_events_are_registered_and_an_empty_list_says_why
    timers.each do |entry|
      entry["events"].each { |event| assert_includes event_types, event, entry["timer"] }
      refute_nil entry["note"], "#{entry["timer"]} writes no event and gives no reason" if entry["events"].empty?
    end
  end

  def test_events_are_those_of_its_state_table_rows
    timers.each do |entry|
      rows = machine_rows(entry["timer"])
      refute_empty rows, entry["timer"]
      rows.each { |row| assert_equal [ "app" ], row["who"], entry["timer"] }
      written = rows.flat_map do |row|
        row["events"] + (row["conditional_events"] + row["side_events"]).map { |entry| entry["event"] }
      end.uniq
      assert_equal written.sort, entry["events"].sort, entry["timer"]
    end
  end

  def test_the_sweep_is_the_trigger_and_not_a_timer
    trigger = Leverage::Contract.timers.fetch("trigger")
    assert_equal "sweep", trigger["name"]
    refute_includes timers.map { |entry| entry["timer"] }, trigger["name"]
    refute_includes registry["commands"], trigger["name"]
    assert_operator trigger["every_seconds_at_most"], :<=, 30
  end
end
