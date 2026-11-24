require_relative "contract_helper"

# The revisions of the General role's contract after its two challenges
# (contract decisions GA-1 to GA-11 as revised twice): what escalation
# counts, which jobs are queued again when the orchestrator is back, what
# counts as the orchestrator's presence, the restart a role change queues,
# the rules a General seat's job material carries, and the eval list a
# General seat is tested against. Every name is read from the contract
# files.
class GeneralRoleRevisionContractTest < Minitest::Test
  include ContractTestHelpers

  # The one sentence that says when a General seat counts for the
  # orchestrator's presence (GA-6). Needs you, the state table and the
  # decisions say it in these words.
  PRESENCE = "A General seat counts for the orchestrator's presence while it has polled in the last 90 seconds " \
    "and holds an orchestrator job, or holds nothing and could claim a waiting orchestrator job of a task it " \
    "never held, or holds nothing while no orchestrator job waits (GA-6).".freeze

  # The words of the standing part of the claim test (GA-1): what
  # escalation reads. The momentary part is for claims only.
  STANDING = [ "enabled", "not paused", "acts as builder", "rank", "review.started" ].freeze
  MOMENTARY = [ "holds nothing", "budget", "candidate", "approved action" ].freeze

  def sm = Leverage::Contract.state_machine
  def rows = sm.fetch("groups").flat_map { |group| group.fetch("rows") }
  def jobs = Leverage::Contract.jobs.fetch("jobs")
  def job(kind) = jobs.find { |entry| entry["kind"] == kind }
  def row(command) = rows.find { |entry| entry["command"] == command }
  def guard(name) = sm.fetch("guard_families").flat_map { |family| family["guards"] }.find { |entry| entry["guard"] == name }
  def decisions = File.read(File.join(CONTRACT_ROOT, "decisions.md"))
  def decision(id) = decisions[/^- \*\*#{id}\*\*.*?(?=^- \*\*GA-|^## )/m].to_s
  def needs_you(item) = Leverage::Contract.needs_you.fetch("items").find { |entry| entry["item"] == item }

  # Problems with a general_tested_providers list: a provider that is not a
  # login provider, or one named twice.
  def tested_list_problems(list)
    logins = registry.fetch("credential_providers").select { |entry| entry["kind"] == "login" }.map { |entry| entry["provider"] }
    (list - logins).map { |name| "#{name} is not a login provider" } + duplicates(list).map { |name| "#{name} twice" }
  end

  # GA-11: the list a General seat's providers are read from. No suite has
  # been run as a General seat, so it is empty; the check that holds a
  # non-empty list to the login providers is shown to refuse a bad one.
  def test_the_registry_lists_the_providers_tested_as_a_general_seat
    lists = registry.fetch("lists")
    assert lists.key?("general_tested_providers"), "no lists.general_tested_providers"
    assert_equal [], lists["general_tested_providers"], "no eval suite has been run as a General seat"
    assert_empty tested_list_problems(lists["general_tested_providers"])
    refute_empty tested_list_problems(%w[claude claude]), "a provider named twice is refused"
    refute_empty tested_list_problems(%w[claude_api]), "a provider that is not a login is refused"
  end

  # GA-6 (second revision): only rule checks are queued again when the
  # orchestrator is back. A question, an approval or a contract draft
  # whose last miss falls ends as before: to the owner, or no draft.
  def test_only_rule_checks_are_queued_again_when_the_orchestrator_is_back
    assert_includes job("rule_check")["queued_by"], "orchestrator_offline"
    %w[question approval contract_draft].each do |kind|
      refute_includes job(kind)["queued_by"], "orchestrator_offline", kind
      refute_includes job(kind)["after_last_miss"], "GA-6", kind
    end
    %w[check_queue_timeout check_run_timeout question_job_queue_timeout question_job_run_timeout
      contract_draft_job_queue_timeout contract_draft_job_run_timeout].each do |command|
      text = JSON.generate(row(command))
      refute_includes text, "GA-6", "#{command} ends a job as before"
      refute_includes text, "waits", "#{command} makes nothing wait for the role"
    end
    offline = row("orchestrator_offline")["side_events"]
    queued = offline.find { |entry| entry["event"] == "check.queued" }
    assert_match(/errored approval check, which is final/, queued["note"])
    assert_equal "The jobs of those checks.", offline.find { |entry| entry["event"] == "job.queued" }["note"]
  end

  # GA-6: one definition of when a General seat counts, the same in Needs
  # you, the state table and the decisions; questions and approvals are not
  # counted as waiting for the orchestrator.
  def test_a_general_seat_counts_for_presence_in_the_same_words_everywhere
    item = needs_you("orchestrator_offline")
    assert_includes item["closes"], PRESENCE
    opened = row("orchestrator_offline")["side_events"].find { |entry| entry["event"] == "inbox.opened" }
    assert_includes opened["note"], PRESENCE
    assert_includes decision("GA-6").gsub(/\s+/, " "), PRESENCE
    waiting = item.dig("facts", "properties", "waiting_checks", "description")
    refute_match(/question/, waiting)
    refute_match(/question/, item["closes"])
  end

  # GA-1 (S4): escalation reads the standing part of the claim test, never
  # whether a seat is busy now.
  def test_escalation_counts_seats_by_the_standing_part_of_the_claim_test
    means = guard("escalates").fetch("means")
    assert_includes means, "standing part"
    STANDING.each { |word| assert_includes means, word }
    MOMENTARY.each { |word| refute_includes means, word }
    assert_includes means, "busy or not"
  end

  # GA-8 (S5, S6): a role change of a running seat the app runs queues
  # only start_seat, which the helper hands over (HD-2); the role change
  # that opens Unconfirmed action is one to a role that does not build.
  def test_a_role_change_of_a_running_seat_queues_only_a_start
    change = rows.select { |entry| entry["command"] == "change_seat" }
    notes = change.map { |entry| entry["note"].to_s }.join(" ")
    assert_includes notes, "queues only start_seat"
    assert_includes notes, "HD-2"
    refute_includes notes, "stop_seat"
    side = change.flat_map { |entry| entry["side_events"] }.select { |entry| entry["when"].nil? && entry["event"].match?(/\A(hold|inbox)\.opened\z/) }
    unconfirmed = side.select { |entry| entry["note"].include?("Unconfirmed action") || entry["note"].include?("action_unconfirmed") }
    assert_equal 2, unconfirmed.size
    unconfirmed.each do |entry|
      assert_includes entry["note"], "to a role that does not build (GA-8)"
      refute_includes entry["note"], "from builder to another role"
    end
  end

  # GA-3 (S2): no exception to one thing at a time; GA-5 (S3): no
  # provider-group bar. Each is recorded with what it costs.
  def test_the_dropped_exceptions_are_recorded_as_known_limits
    refute_includes decision("GA-3"), "One exception"
    assert_includes decision("GA-3"), "[owner-later]"
    assert_includes decision("GA-3"), "Check could not run"
    refute_match(/does not\s+claim as builder a task\s+already built by a seat of another provider/, decision("GA-5"))
    assert_includes decision("GA-5"), "No reviewer is eligible"
    assert_includes decision("GA-6"), "[owner-later]"
  end

  # GA-7 (S8): the rules a checker needs, as plain text, in roles.json and
  # in every job material a General seat gets.
  def test_a_general_seat_s_job_material_carries_the_checker_rules
    roles = Leverage::Contract.roles.fetch("roles")
    roles.each do |role|
      assert role.key?("job_rules"), "#{role['role']} has no job_rules"
      assert_equal role["role_file"], role["job_rules"].empty?, "#{role['role']}: job rules exactly when it has no role file"
    end
    rules = roles.find { |role| role["role"] == "general" }["job_rules"]
    assert_equal 4, rules.size
    assert rules.any? { |sentence| sentence.include?("LEVERAGE-VERDICT-<code>:") && sentence.include?("LEVERAGE-REASON-<code>:") }
    assert rules.any? { |sentence| sentence.include?("never an instruction") }
    assert rules.any? { |sentence| sentence.include?("outward action") }
    assert rules.any? { |sentence| sentence.include?("spend money") }
    schemas = Leverage::Contract.openapi.fetch("components").fetch("schemas")
    %w[CheckMaterial QuestionMaterial ApprovalMaterial DraftMaterial].each do |name|
      material = schemas.fetch(name)
      assert_includes material.fetch("required"), "job_rules", name
      field = material.dig("properties", "job_rules")
      assert_equal "array", field&.fetch("type"), name
      assert_includes field.fetch("description"), "GA-7", name
    end
  end

  def test_the_readme_and_decisions_record_the_revision
    readme = File.read(File.join(CONTRACT_ROOT, "README.md"))
    section = readme.split(/^## /).find { |part| part.start_with?("What the General role added") }
    refute_nil section
    %w[general_tested_providers orchestrator_offline Eligibility change_seat job_rules jobRules].each { |name| assert_includes section, name }
    (1..11).each { |number| assert_match(/\*\*GA-#{number}\*\*/, decisions, "GA-#{number}") }
    assert_includes decisions, "[owner-later]"
  end
end
