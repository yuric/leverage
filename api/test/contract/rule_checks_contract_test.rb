require_relative "contract_helper"

# The Rule checks milestone's additions to the contract (milestone 4 plan,
# section 2.3): the command that writes the shipped rules and its Lifecycle
# row, create_owner's rule.created, the two guards of Run it again, the side
# events of the rows that end a waiting command or turn a rule off, the job
# shapes with their material, the shipped instruction, the registry list of
# tested providers, and the fields the provisional reads gain. Every name is
# read from the contract files.
class RuleChecksContractTest < Minitest::Test
  include ContractTestHelpers

  def doc = Leverage::Contract.openapi
  def schemas = doc.fetch("components").fetch("schemas")
  def sm = Leverage::Contract.state_machine
  def groups = sm.fetch("groups")
  def rows = groups.flat_map { |group| group.fetch("rows") }
  def rows_of(command) = rows.select { |row| row["command"] == command }
  def group(id) = groups.find { |entry| entry["id"] == id }
  def timer(name) = Leverage::Contract.timers.fetch("timers").find { |entry| entry["timer"] == name }
  def step(kind) = Leverage::Contract.steps.fetch("steps").find { |entry| entry["kind"] == kind }
  def item(kind) = Leverage::Contract.needs_you.fetch("items").find { |entry| entry["item"] == kind }
  def shipped(key) = Leverage::Contract.shipped_rules.fetch("rules").find { |entry| entry["key"] == key }
  def all_guards = sm.fetch("guard_families").flat_map { |family| family["guards"] } + sm.fetch("guard_conditions")

  def operation(operation_id)
    doc.fetch("paths").each_value do |path_item|
      path_item.each_value { |op| return op if op.is_a?(Hash) && op["operationId"] == operation_id }
    end
    flunk "no operation #{operation_id} in openapi.json"
  end

  def side_events(row, event) = row.fetch("side_events").select { |entry| entry["event"] == event }
  def notes(row, event) = side_events(row, event).map { |entry| entry["note"].to_s }

  def all_events(row)
    row["events"] + row["conditional_events"].map { |entry| entry["event"] } + row["side_events"].map { |entry| entry["event"] }
  end

  def label(row) = "#{row["command"]} from #{row["from"].inspect} #{row["guard"].inspect}"

  def validator(component) = JSONSchemer.openapi(doc).ref("#/components/schemas/#{component}")

  def property(component, name) = schemas.dig(component, "properties", name)

  def required(component) = schemas.dig(component, "required") || []

  # Plan RD-2, S-1: the one-time write is a command of its own, run by the
  # app with no key, with its own Lifecycle row; nothing calls it over HTTP.
  def test_install_shipped_rules_is_a_command_with_its_prd_lifecycle_row
    assert_includes registry.fetch("commands"), "install_shipped_rules"
    entry = sm.fetch("commands").find { |candidate| candidate["command"] == "install_shipped_rules" }
    refute_nil entry, "state_machine.json commands has no install_shipped_rules"
    assert_equal [ false, false, false ], entry.values_at("work_call", "blocked_by_hold", "allowed_while_pending")
    lifecycle = group("install_shipped_rules")
    refute_nil lifecycle, "no install_shipped_rules group"
    assert_equal "prd", lifecycle["source"]
    assert_equal [ "Write the shipped rules", "None", "Unchanged", "The app", "None", "`rule.created`" ], lifecycle["prd_cells"]
    assert_equal 1, lifecycle.fetch("rows").size
    row = lifecycle.fetch("rows").first
    assert_equal "install_shipped_rules", row["command"]
    assert_nil row["from"]
    assert_nil row["to"]
    assert_equal [ "app" ], row["who"]
    assert_nil row["hook"]
    assert_equal [ "rule.created" ], row["events"]
    assert notes(row, "inbox.opened").any? { |note| note.include?("SM-42") }, "No reviewer is eligible is re-evaluated (RD-3)"
    assert notes(row, "inbox.resolved").any? { |note| note.include?("SM-42") }
    assert_includes row["note"].to_s, "RD-2"
    assert_equal 1, rows_of("install_shipped_rules").size
    refute registry.fetch("operations").any? { |op| op["commands"].include?("install_shipped_rules") }, "no operation runs it"
    assert_includes schemas.dig("CommandName", "enum"), "install_shipped_rules"
  end

  # L434, SM-33: creating the workspace writes the shipped rules, the
  # workspace's first events, with the owner as actor and the command's key.
  # DB-53: the Imaginarium project's project.created comes after them.
  def test_create_owner_writes_the_shipped_rules
    row = rows_of("create_owner").first
    assert_equal [ "rule.created", "project.created" ], row["events"]
    refute_includes row["note"], "with no rule"
    assert_includes row["note"], "SM-33"
    assert_includes row["note"], "shipped rule"
  end

  # Plan RD-42: Run it again on an errored task.before_claim check closes
  # its hold and queues nothing. An errored approval check is final (AE-15).
  def test_rerun_check_splits_on_the_targets_of_one_guard_family
    guards = %w[rerun_of_approval_check rerun_of_claim_check rerun_queues]
    family = sm.fetch("guard_families").find { |entry| entry["family"] == "rerun_target" }
    assert_equal guards, family.fetch("guards").map { |guard| guard["guard"] }.sort
    guards.each { |guard| assert_includes registry.fetch("guards"), guard }
    reruns = rows_of("rerun_check")
    assert_equal guards.map { |guard| [ guard ] }, reruns.map { |row| row["guard"] }.sort
    approval = reruns.find { |row| row["guard"] == %w[rerun_of_approval_check] }
    assert_equal "invalid_state", approval["refusal"]
    assert_empty approval["events"]
    queues = reruns.find { |row| row["guard"] == %w[rerun_queues] }
    assert_equal %w[check.queued job.queued], queues["events"]
    claim = reruns.find { |row| row["guard"] == %w[rerun_of_claim_check] }
    assert_equal [], claim["events"]
    assert_equal %w[hold.closed inbox.resolved], claim["side_events"].map { |entry| entry["event"] }.sort
    assert_equal [ "check_error" ], claim["holds_closed"]
    assert_includes claim["note"].to_s, "RD-42"
  end

  # RD-12, RC-50: claim-next writes an applied row with effect refused for a
  # review the provider rule keeps from this seat, also when it is refused.
  def test_claim_review_may_write_the_provider_rules_refusal
    row = rows_of("claim_review").first
    assert notes(row, "check.finished").any? { |note| note.include?("refused") && note.include?("RD-12") }
  end

  # L379, RD-45, S-5: turning a rule off withdraws its checks, which closes a
  # rerun_limit hold too and lets the waiting command complete.
  def test_turning_a_rule_off_closes_its_rerun_limit_hold_and_completes_the_command
    %w[disable_rule remove_rule].each do |command|
      row = rows_of(command).first
      %w[check_error claim_gate_failed rerun_limit].each { |reason| assert_includes row["holds_closed"], reason, command }
      assert notes(row, "inbox.resolved").any? { |note| note.include?("Check past the re-run limit") }, command
      assert_includes row["note"].to_s, "RD-45", command
      assert_includes row["note"].to_s, "requester", command
    end
  end

  # RD-45: an override of the check held at the re-run limit completes its
  # transition in place.
  def test_override_check_completes_a_command_held_at_the_rerun_limit
    assert_includes rows_of("override_check").first["note"], "re-run limit"
    assert_includes rows_of("override_check").first["note"], "RD-45"
  end

  # RE-6, RD-45: a planner's contract is a Complete contract, so its result
  # may reach the re-run limit.
  def test_a_job_result_may_open_the_rerun_limit_hold
    row = rows_of("submit_job_result").first
    assert_includes row["holds_opened"], "rerun_limit"
    assert notes(row, "inbox.opened").any? { |note| note.include?("re-run limit") }
  end

  # RD-16, RD-19: the item opens only while a check waits, and on return
  # only errored checks get a new attempt.
  def test_orchestrator_offline_opens_only_while_a_check_waits
    row = rows_of("orchestrator_offline").first
    assert_includes row["note"], "RD-16"
    assert notes(row, "check.queued").any? { |note| note.include?("RD-19") && note.start_with?("Errored checks") }
    closes = item("orchestrator_offline")["closes"]
    assert_includes closes, "only while"
    assert_includes closes, "RD-16"
    assert_equal %w[orchestrator planner], item("orchestrator_offline").dig("facts", "properties", "role", "enum")
    assert_includes item("orchestrator_offline").dig("facts", "properties", "role", "description").to_s, "RD-20"
    assert_includes item("orchestrator_offline").dig("facts", "properties", "waiting_checks", "description").to_s, "RD-18"
  end

  # Rule 11 of section 2.1: a reviewer's pending pass is cancelled when the
  # review is taken from it; its checks and jobs are withdrawn and the
  # holds they opened close.
  def test_the_rows_that_take_a_review_away_cancel_its_pending_pass
    taking = rows_of("release_review") + rows_of("review_lease_expiry") + rows_of("report_run_stopped") +
      rows_of("issue_helper_token") +
      (rows_of("report_limit") + rows_of("report_signed_out")).select { |row| row["guard"] == %w[reviewer_holds_review no_candidate_available] }
    assert_equal 6, taking.size
    taking.each do |row|
      %w[check.finished job.withdrawn hold.closed inbox.resolved].each do |event|
        refute_empty side_events(row, event), "#{label(row)} lacks #{event}"
      end
      assert notes(row, "check.finished").any? { |note| note.include?("pending transition this cancels") }, label(row)
      %w[check_error rerun_limit].each { |reason| assert_includes row["holds_closed"], reason, label(row) }
    end
    review_lease = timer("review_lease_expiry")["events"]
    %w[check.finished job.withdrawn hold.closed].each { |event| assert_includes review_lease, event }
  end

  # Rule 11: pausing the claimant of a provisional claim cancels the claim.
  def test_pausing_a_seat_withdraws_its_provisional_claims_checks
    row = rows_of("pause_seat").first
    assert notes(row, "check.finished").any? { |note| note.include?("provisional claim") }
    refute_empty side_events(row, "job.withdrawn")
  end

  # Rule 11: every row that can end a waiting command at a hook where the
  # re-run limit can be reached closes a rerun_limit hold its check opened.
  def test_every_row_that_ends_a_waiting_submit_or_pass_closes_its_rerun_limit_hold
    ending = rows_of("release").select { |row| row["from"] == "working" } + rows_of("change_seat") + rows_of("remove_seat")
    assert_equal 3, ending.size
    ending.each do |row|
      assert_includes row["holds_closed"], "rerun_limit", label(row)
      assert notes(row, "hold.closed").any? { |note| note.include?("rerun_limit") }, label(row)
    end
  end

  # Rule 11: the refusal a waiting command reads says which ending gave it.
  def test_get_command_says_which_code_each_ending_gives
    description = operation("get_command").fetch("description")
    %w[task_cancelled lease_expired invalid_state RC-17].each { |word| assert_includes description, word }
  end

  # RD-11: the provider rule's refusal closes the open wait_review step and
  # opens one that names the rule.
  def test_wait_review_moves_to_the_rule_at_its_refusal
    %w[opened_by closed_by].each do |side|
      boundary = step("wait_review")[side].find { |entry| entry["event"] == "check.finished" }
      refute_nil boundary, "wait_review #{side} has no check.finished"
      assert_includes boundary["when"], "refused"
      assert_includes boundary["when"], "RD-11"
    end
  end

  # RD-34, RD-40, RD-41: when a claim's result is discarded, a claim that
  # returns the job the seat holds, and what a late result answers.
  def test_the_claim_carries_its_run_due_time_and_the_calls_say_what_a_repeat_and_a_late_result_do
    assert_includes required("ClaimJobResult"), "run_due_at"
    assert_equal "date-time", property("ClaimJobResult", "run_due_at")&.dig("format")
    assert_includes operation("claim_next_job").fetch("description"), "RD-40"
    assert_includes operation("claim_next_job").fetch("description"), "already holds"
    assert_includes operation("submit_job_result").fetch("description"), "invalid_state"
    assert_includes operation("submit_job_result").fetch("description"), "RD-41"
    assert_equal 500, property("RuleCheckJobResult", "reason")&.dig("maxLength")
  end

  # RD-30, RD-31: a rule check job hands its seat everything the checker
  # needs, built when the job is claimed.
  def test_a_rule_check_jobs_input_carries_its_material
    assert_includes required("RuleCheckJobInput"), "material"
    material = schemas["CheckMaterial"]
    refute_nil material, "no CheckMaterial component"
    assert_equal "#/components/schemas/CheckMaterial", property("RuleCheckJobInput", "material")&.dig("$ref")
    assert_equal %w[contract instruction job_rules may_answer_not_applicable moment quoted role_file], material.fetch("required").sort
    contract = schemas.fetch("CheckContract")
    assert_equal %w[criteria details goal title], contract.fetch("required").sort
    criterion_ref = contract.dig("properties", "criteria", "items", "$ref")
    criterion = schemas.fetch(criterion_ref.delete_prefix("#/components/schemas/"))
    assert_equal %w[kind state text], criterion.fetch("required").sort
    assert_equal registry.dig("lists", "criterion_kinds"), criterion.dig("properties", "kind", "enum")
    assert_equal registry.dig("lists", "criterion_states"), criterion.dig("properties", "state", "enum")
    quoted = schemas.fetch("QuotedText")
    assert_equal %w[label text], quoted.fetch("required").sort
    assert_equal %w[handoff_note evidence review_notes agent], quoted.dig("properties", "label", "enum")
    moments = Leverage::Contract.hooks.fetch("hooks").map { |hook| hook["moment_name"] }
    assert_equal moments, material.dig("properties", "moment", "enum")
  end

  # RD-37: a draft job carries the task's text, the criteria it has, and the
  # three values the result sends back unchanged.
  def test_a_contract_draft_jobs_input_carries_its_material
    assert_includes required("ContractDraftJobInput"), "material"
    material = schemas["DraftMaterial"]
    refute_nil material, "no DraftMaterial component"
    assert_equal "#/components/schemas/DraftMaterial", property("ContractDraftJobInput", "material")&.dig("$ref")
    assert_equal %w[brief budget_cap criteria details goal job_rules minimum_strength_rank role_file title work_reference],
      material.fetch("required").sort
    assert_equal "#/components/schemas/CriterionInput", material.dig("properties", "criteria", "items", "$ref")
    assert_equal "#/components/schemas/BriefEntry", material.dig("properties", "brief", "items", "$ref")
    complete = schemas.fetch("CompleteContractRequest").fetch("properties")
    %w[work_reference minimum_strength_rank budget_cap].each do |field|
      assert_equal complete.fetch(field).except("description"), material.dig("properties", field).except("description"), field
    end
  end

  # RD-62, RD-38: what a briefing's rule instruction and the builder's
  # review notes carry now.
  def test_the_briefing_says_what_an_app_rules_instruction_and_the_review_notes_carry
    assert_includes property("BriefingRule", "instruction")&.dig("description").to_s, "RD-62"
    assert_includes property("BriefingResponse", "review_notes")&.dig("description").to_s, "RD-38"
  end

  # RV-5: the providers whose tool's default model passed the eval suite.
  # WP0 writes it empty; the managing agent fills it after the eval run.
  def test_the_registry_lists_the_tested_orchestrator_providers
    lists = registry.fetch("lists")
    assert lists.key?("orchestrator_tested_providers"), "no lists.orchestrator_tested_providers"
    logins = registry.fetch("credential_providers").select { |entry| entry["kind"] == "login" }.map { |entry| entry["provider"] }
    assert_empty lists["orchestrator_tested_providers"].to_a - logins
  end

  # RV-2: the shipped instruction of "Every task needs specific details".
  def test_the_specific_details_rule_has_its_instruction
    instruction = shipped("specific_details")["instruction"]
    assert_kind_of String, instruction
    assert instruction.start_with?("A task has specific details when someone who has never seen it could do it")
    assert instruction.end_with?("Do not judge whether the task is worth doing.")
  end

  # The server writes both model rules with instructions. RuleVersion can
  # still read an app rule or a version from before its instruction shipped.
  def test_a_shipped_instruction_as_written_is_one_rule_version_takes
    instruction = schemas.dig("RuleVersion", "properties", "instruction")
    takes = JSONSchemer.schema(instruction)
    Leverage::Rules::Shipped.all.each { |record| assert takes.valid?(record.instruction), record.key }
    approval = Leverage::Rules::Shipped.find("orchestrator_approves_actions").instruction
    assert_kind_of String, approval
    assert_equal shipped("orchestrator_approves_actions")["instruction"], approval
    assert takes.valid?(approval)
    assert takes.valid?(nil)
  end

  # RD-26: each rule of Settings, Rules with its sentence, its moment,
  # whether it acts, and its counts.
  def test_the_rules_read_carries_the_sentence_moment_and_counts
    %w[sentence moment_name acts stats].each { |field| assert_includes required("RuleWithVersion"), field }
    assert_equal "#/components/schemas/RuleStats", property("RuleWithVersion", "stats")&.dig("$ref")
    assert_equal %w[average_seconds checks overrides spend tokens], required("RuleStats").sort
    assert_equal %w[string null], property("RuleWithVersion", "sentence")&.dig("type")
    assert_equal %w[number null], property("RuleStats", "average_seconds")&.dig("type")
  end

  # Section 2.3: the task page's timeline, its rule checks, the waiting
  # command and the draft.
  def test_the_task_page_carries_its_steps_rule_checks_pending_and_draft
    %w[steps lifetime_seconds as_of rule_checks pending draft].each { |field| assert_includes required("TaskPage"), field }
    assert_equal "#/components/schemas/TaskStep", property("TaskPage", "steps")&.dig("items", "$ref")
    assert_equal %w[cause_kind cause_rule_id closed_at kind opened_at round seat_id seconds step_class subject_id subject_kind],
      required("TaskStep").sort
    assert_equal registry.fetch("step_kinds"), property("TaskStep", "kind")&.dig("enum")
    assert_equal "#/components/schemas/TaskRuleCheck", property("TaskPage", "rule_checks")&.dig("items", "$ref")
    assert_equal %w[attempts can_override can_rerun checker effect hook id moment_name on_fail overridden_at
                    overridden_by_user_id override_reason queue_seconds reason result round rule_id rule_name
                    rule_version_id run_seconds version version_saved_at], required("TaskRuleCheck").sort
    assert_equal "#/components/schemas/RuleCheckAttempt", property("TaskRuleCheck", "attempts")&.dig("items", "$ref")
    assert_equal %w[attempt_number finished_at queued_at started_at], required("RuleCheckAttempt").sort
    assert_equal registry.fetch("check_results") + [ nil ], property("TaskRuleCheck", "result")&.dig("enum")
    assert_equal %w[none queued writing not_written], property("TaskPage", "draft")&.dig("enum")
    pending = property("TaskPage", "pending")&.dig("anyOf")&.map { |branch| branch["$ref"] || branch["type"] }
    assert_equal [ "#/components/schemas/PendingCommand", "null" ], pending
    assert_equal %w[command since waiting_on_rule_ids], required("PendingCommand").sort
  end

  def test_the_board_card_says_when_a_task_is_being_checked_and_why_it_needs_details
    %w[checking check_reason].each { |field| assert_includes required("BoardTask"), field }
    assert_equal "boolean", property("BoardTask", "checking")&.dig("type")
    assert_equal %w[string null], property("BoardTask", "check_reason")&.dig("type")
  end

  # RD-17, RD-18: the health line keeps the three merged values and counts
  # the waiting checks.
  def test_the_health_line_keeps_its_three_orchestrator_values_and_counts_waiting_checks
    assert_equal %w[not_set_up online offline], property("SystemHealth", "orchestrator")&.dig("enum")
    refute_includes property("SystemHealth", "orchestrator")&.dig("description").to_s, "Always not_set_up"
    assert_includes property("SystemHealth", "orchestrator")&.dig("description").to_s, "RD-17"
    assert_includes required("SystemHealth"), "waiting_checks"
    assert_equal "integer", property("SystemHealth", "waiting_checks")&.dig("type")
  end

  # The examples of every changed component validate.
  def test_the_examples_of_the_new_shapes_validate
    %w[ClaimJobResult RuleCheckJobInput ContractDraftJobInput CheckMaterial DraftMaterial TaskPage BoardTask
       SystemHealth RuleWithVersion TaskStep TaskRuleCheck PendingCommand].each do |component|
      refute_nil schemas[component], component
      examples = schemas.dig(component, "examples")
      refute_empty examples.to_a, component
      examples.to_a.each { |example| assert validator(component).valid?(example), component }
    end
  end

  def test_the_readme_records_the_rule_checks_milestones_additions
    readme = File.read(File.join(CONTRACT_ROOT, "README.md"))
    section = readme.split(/^## /).find { |part| part.start_with?("What the Rule checks milestone added") }
    refute_nil section, "README.md has no section for the Rule checks milestone"
    %w[install_shipped_rules create_owner rerun_queues rerun_of_claim_check orchestrator_tested_providers run_due_at
       material CheckMaterial DraftMaterial wait_review pending_transitions.params jobs.attempt_number
       waiting_checks TaskStep TaskRuleCheck].each do |name|
      assert_includes section, name
    end
  end
end
