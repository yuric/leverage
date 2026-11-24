require_relative "contract_helper"

# The revision of the General role's contract after its challenge (contract
# decisions GA-1 to GA-11 as revised): who escalation and question routing
# count, which jobs wait for a busy General seat and are queued again, the
# restart a role change queues, and the eval list a General seat is tested
# against. Every name is read from the contract files.
class GeneralRoleRevisionContractTest < Minitest::Test
  include ContractTestHelpers

  def sm = Leverage::Contract.state_machine
  def rows = sm.fetch("groups").flat_map { |group| group.fetch("rows") }
  def jobs = Leverage::Contract.jobs.fetch("jobs")
  def guard(name) = sm.fetch("guard_families").flat_map { |family| family["guards"] }.find { |entry| entry["guard"] == name }

  # GA-11: the list a General seat's providers are read from, empty until
  # the maintainer runs both suites as a General seat.
  def test_the_registry_lists_the_providers_tested_as_a_general_seat
    lists = registry.fetch("lists")
    assert lists.key?("general_tested_providers"), "no lists.general_tested_providers"
    logins = registry.fetch("credential_providers").select { |entry| entry["kind"] == "login" }.map { |entry| entry["provider"] }
    assert_empty lists["general_tested_providers"] - logins
    assert_empty duplicates(lists["general_tested_providers"])
  end

  # GA-6: a question, approval or contract-draft job whose last miss fell
  # while its role counted as offline is queued again when the role is back.
  def test_every_job_kind_is_queued_again_when_its_role_is_back
    jobs.each { |entry| assert_includes entry["queued_by"], "orchestrator_offline", entry["kind"] }
    %w[question approval contract_draft].each do |kind|
      assert_includes jobs.find { |entry| entry["kind"] == kind }["after_last_miss"], "GA-6", kind
    end
    offline = rows.find { |row| row["command"] == "orchestrator_offline" }
    notes = offline["side_events"].map { |entry| entry["note"] }.join(" ")
    assert_includes notes, "GA-6"
    refute_includes notes, "which is final"
  end

  # GA-1 (D1): escalation counts only seats that may claim the task.
  def test_escalation_counts_only_seats_that_may_claim_the_task
    assert_includes guard("escalates").fetch("means"), "may claim"
  end

  # GA-8 (D6): a role change of a running seat the app runs restarts it.
  def test_a_role_change_of_a_running_seat_restarts_it
    change = rows.select { |row| row["command"] == "change_seat" }
    notes = change.map { |row| row["note"].to_s }.join(" ")
    assert_includes notes, "start_seat"
    assert_includes notes, "GA-8"
  end

  def test_the_readme_and_decisions_record_the_revision
    readme = File.read(File.join(CONTRACT_ROOT, "README.md"))
    section = readme.split(/^## /).find { |part| part.start_with?("What the General role added") }
    refute_nil section
    %w[general_tested_providers orchestrator_offline Eligibility change_seat].each { |name| assert_includes section, name }
    decisions = File.read(File.join(CONTRACT_ROOT, "decisions.md"))
    (1..11).each { |number| assert_match(/\*\*GA-#{number}\*\*/, decisions, "GA-#{number}") }
    assert_includes decisions, "[owner-later]"
  end
end
