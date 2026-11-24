require_relative "contract_helper"

# The revisions of the General role's contract after its three challenges
# (contract decisions GA-1 to GA-11 as revised three times): what
# escalation counts, which jobs are queued again when the orchestrator is
# back, what counts as the orchestrator's presence, where a question goes,
# when the review bar is lifted, the restart a role change queues, the
# rules a General seat's job material carries, and the eval list a General
# seat is tested against. Every name is read from the contract files.
class GeneralRoleRevisionContractTest < Minitest::Test
  include ContractTestHelpers

  # What waits for the orchestrator (GA-6, round 4 T1): the set the
  # orchestrator_offline timer counts, queued jobs and errored checks both.
  WAITING = "A check waits for the orchestrator while its rule_check or approval job is queued or while it is " \
    "held with check_error.".freeze

  # The one sentence that says when a General seat counts for the
  # orchestrator's presence (GA-6). Needs you, the state table and the
  # decisions say it in these words, after WAITING.
  PRESENCE = "A General seat counts for the orchestrator's presence while it has polled in the last 90 seconds " \
    "and holds an orchestrator job, or holds nothing and, for a waiting check, could claim it (Jobs.next_for), " \
    "as a new attempt when the check is held with check_error, or holds nothing while no check waits (GA-6).".freeze

  # The words every place that decides whether a General seat may take an
  # orchestrator's work now uses (round 4 T1, T2).
  COULD_CLAIM = "could claim it (Jobs.next_for)".freeze

  # The words of the standing part of the claim test (GA-1): what
  # escalation reads, paused or not and busy or not. The momentary part
  # is for claims only.
  STANDING = [ "enabled", "not removed", "acts as builder", "rank", "review.started" ].freeze
  MOMENTARY = [ "holds nothing", "budget", "candidate", "approved action", "not paused" ].freeze

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

  # GA-11: the list a General seat's providers are read from.
  # scripts/check_evals.py checks coverage against the current eval cases.
  def test_the_registry_lists_the_providers_tested_as_a_general_seat
    lists = registry.fetch("lists")
    assert lists.key?("general_tested_providers"), "no lists.general_tested_providers"
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

  # GA-6 (round 4 T1): one definition of what waits and of when a General
  # seat counts, the same in Needs you, the state table and the decisions.
  # Waiting is the timer's own set, so an errored check held with
  # check_error keeps a barred idle seat from counting, and the seat never
  # counts again only because no job is queued (challenge 3, defect 1).
  # Questions and approvals are not counted as waiting checks.
  def test_a_general_seat_counts_for_presence_in_the_same_words_everywhere
    item = needs_you("orchestrator_offline")
    opened = row("orchestrator_offline")["side_events"].find { |entry| entry["event"] == "inbox.opened" }
    [ item["closes"], opened["note"], decision("GA-6").gsub(/\s+/, " ") ].each do |text|
      assert_includes text, "#{WAITING} #{PRESENCE}"
      refute_includes text, "no orchestrator job waits"
      refute_includes text, "of a task it never held"
    end
    waiting = item.dig("facts", "properties", "waiting_checks", "description")
    assert_includes waiting, "check_error"
    refute_match(/question/, waiting)
    refute_match(/question/, item["closes"])
  end

  # GA-6 (round 4 T1): the timer queues an errored check again only when a
  # seat that counts could claim it; otherwise the check stays in its error
  # as the owner's item, and one that has no item yet gets it.
  def test_an_errored_check_is_queued_again_only_when_a_counting_seat_could_claim_it
    side = row("orchestrator_offline")["side_events"]
    queued = side.find { |entry| entry["event"] == "check.queued" }
    assert_includes queued["note"], "only when a seat that counts as present is eligible for the new attempt regardless of queue order"
    assert_includes queued["note"], "stays in its error"
    assert_includes side.find { |entry| entry["event"] == "hold.closed" }["note"], "closes when the role is back"
    item = side.select { |entry| entry["event"] == "inbox.opened" }.map { |entry| entry["note"] }
    assert(item.any? { |note| note.include?("Check could not run") && note.include?("stays in its error") },
      "an errored check left in its error gets its owner item")
    assert_includes decision("GA-6").gsub(/\s+/, " "), "only when a seat that counts as present is eligible for the new attempt regardless of queue order"
  end

  # GA-1 (S4, round 4 T3): escalation reads the standing part of the claim
  # test, never whether a seat is busy now, and, as on main, not whether it
  # is paused, which is temporary.
  def test_escalation_counts_seats_by_the_standing_part_of_the_claim_test
    means = guard("escalates").fetch("means")
    assert_includes means, "standing part"
    STANDING.each { |word| assert_includes means, word }
    MOMENTARY.each { |word| refute_includes means, word }
    assert_includes means, "busy or not"
    assert_includes means, "paused or not"
    escalation = decision("GA-1").gsub(/\s+/, " ")
    assert_includes escalation, "paused or not"
    refute_match(/standing part of the claim test, busy or not: enabled, not paused/, escalation)
  end

  # GA-1 (round 4 T2): a question goes to a job only while a seat that acts
  # as orchestrator could take it now; otherwise to the owner at once.
  def test_a_question_is_routed_to_a_job_only_when_a_seat_could_claim_it_now
    routing = decision("GA-1").gsub(/\s+/, " ")[/question routing.*?(?=- presence|\z)/m].to_s
    refute_empty routing
    assert_includes routing, "counts as present and #{COULD_CLAIM}"
    assert_includes routing, "as on main"
    assert_includes routing, "to the owner at once"
    refute_includes routing, "Paused seats count, as today"
  end

  # GA-5 (round 4 T6): the review bar never keeps a Ready task waiting with
  # no item: it is lifted when no other seat passes the standing part of
  # the claim test for the task. Escalation does not lift it.
  def test_the_review_bar_is_lifted_when_no_other_seat_could_build_the_task
    bar = decision("GA-5").gsub(/\s+/, " ")
    assert_includes bar, "lifted for a task when no other seat passes the standing part of the claim test for it"
    assert_includes bar, "Escalation does not lift it"
    assert_includes bar, "No reviewer is eligible"
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
    # Round 4 T9: only a change to or from General restarts the run; other
    # roles' changes behave as on main.
    assert_includes notes, "when its old or its new role is general"
    assert_includes decision("GA-8").gsub(/\s+/, " "), "when its old or its new role is General"
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

  # GA-9 (round 4 T9): only a General seat's review work passes over a
  # Gemini login; the other roles behave as on main.
  def test_the_gemini_review_pass_over_is_for_general_seats_only
    text = decision("GA-9").gsub(/\s+/, " ")
    assert_includes text, "to a General seat's run on a Gemini login"
    assert_includes text, "for a General seat's review work"
    assert_includes text, "Nothing changes for the other roles"
  end

  def test_the_readme_and_decisions_record_the_revision
    readme = File.read(File.join(CONTRACT_ROOT, "README.md"))
    section = readme.split(/^## /).find { |part| part.start_with?("What the General role added") }
    refute_nil section
    %w[general_tested_providers orchestrator_offline Eligibility change_seat job_rules jobRules Jobs.next_for check_error].each { |name| assert_includes section, name }
    refute_includes section, "enabled, not paused, acts as builder"
    (1..11).each { |number| assert_match(/\*\*GA-#{number}\*\*/, decisions, "GA-#{number}") }
    assert_includes decisions, "[owner-later]"
  end
end
