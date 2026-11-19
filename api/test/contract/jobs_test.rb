require_relative "contract_helper"

# jobs.json: who claims each job kind and which timers bound it. The input
# and result shapes have one home, the openapi.json components the registry
# names (plan RC-33), so they are not repeated or read here.
class JobsTest < Minitest::Test
  include ContractTestHelpers

  def jobs = Leverage::Contract.jobs.fetch("jobs")
  def timers = Leverage::Contract.timers.fetch("timers").map { |entry| entry["timer"] }

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("jobs", Leverage::Contract.jobs)
  end

  def test_kinds_and_components_equal_the_registry_job_kinds
    expected = registry["job_kinds"].map { |entry| entry.values_at("kind", "input_component", "result_component") }
    assert_equal expected, jobs.map { |entry| entry.values_at("kind", "input_component", "result_component") }
  end

  def test_claimers_are_seat_roles
    jobs.each { |entry| assert_includes Leverage::Contract.list("seat_roles"), entry["claimer_role"], entry["kind"] }
  end

  def test_each_kind_names_its_timers
    jobs.each do |entry|
      [ entry["queue_timer"], entry["run_timer"] ].each do |timer|
        assert_includes registry["commands"], timer, entry["kind"]
        assert_includes timers, timer, entry["kind"]
      end
      assert_operator entry["attempts"], :>=, 1, entry["kind"]
    end
  end
end
