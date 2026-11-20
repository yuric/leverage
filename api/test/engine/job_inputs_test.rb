require "test_helper"
require_relative "entries/jobs_support"

# Leverage::JobInputs (PRD L428, L429, L539; milestone 4 plan §2.3, RD-30,
# RD-31, RD-37, RE-2; RC-33): what a claimed job hands its seat, the
# contract's input of the job's kind with its material, built from the
# frozen rule version, the pending request and the task's rows. The
# material is the trust boundary between task text and a model (L429): the
# contract and every quoted piece come from this task alone, under the
# frame's labels, and nothing of it is stored in an event.
class JobInputsTest < ActiveSupport::TestCase
  include JobsSupport
  include OpenapiAssertions

  setup do
    use_scenario
    @other = scenario.task(state: "ready", title: "Other task XYZZY-OTHER", goal: "Other goal XYZZY-OTHER.",
      details: "Other details XYZZY-OTHER.")
  end

  def input_for(job) = Leverage::JobInputs.for(job.reload)

  def assert_nothing_of_another_task(input)
    assert_not_includes JSON.generate(input), "XYZZY-OTHER"
    assert_not_includes JSON.generate(input), @other.id
  end

  test "a check at ready to start hands the requested contract and the frozen version's instruction (RE-2, RD-30)" do
    project = scenario.project
    rule = model_rule(instruction: "Made-up instruction one.")
    task = scenario.task(state: "backlog", criteria: [], project: project, title: "Stored title", goal: "Stored goal.")
    body = contract_body(goal: "Requested goal.", details: "Requested details.").merge("title" => "Requested title")
    task, _pending, check = waiting_contract(rule, task: task, body: body)
    frozen = scenario.current_version(rule)
    RuleVersion.create!(frozen.attributes.except("id", "created_at").merge("version" => 2, "instruction" => "Changed later."))
    rule.update!(current_version: 2)

    input = input_for(job_of(check))

    assert_matches_component("RuleCheckJobInput", input)
    assert_equal [ check.id, 1, frozen.id, "task.before_ready", task.id, project.id ],
      input.values_at("rule_check_id", "attempt_number", "rule_version_id", "hook", "task_id", "project_id")
    assert_equal Leverage::HookInputs.for(hook: "task.before_ready", task: task, params: body), input.fetch("inputs")
    material = input.fetch("material")
    assert_equal Leverage::RoleFiles.text("orchestrator"), material.fetch("role_file")
    assert_equal [ "Made-up instruction one.", "when a task is ready to start", false ],
      material.values_at("instruction", "moment", "may_answer_not_applicable")
    assert_equal({ "title" => "Requested title", "goal" => "Requested goal.", "details" => "Requested details.",
                   "criteria" => [ { "text" => "Made-up build criterion.", "kind" => "build", "state" => "open" },
                                   { "text" => "A reviewer agrees.", "kind" => "review", "state" => "open" } ] },
      material.fetch("contract"))
    assert_equal [], material.fetch("quoted")
    assert_nothing_of_another_task(input)
  end

  test "a let-the-checker-decide rule may answer not applicable; an every-task rule may not" do
    decides = model_rule(scope_kind: "checker_decides")
    _task, _pending, check = waiting_contract(decides)

    assert_equal true, input_for(job_of(check)).dig("material", "may_answer_not_applicable")
  end

  test "a check before work is submitted hands the task's contract, its evidence and the requested handoff note" do
    rule = model_rule(hook: "task.before_submit")
    builder = scenario.seat(role: "builder", credential: scenario.credential)
    task = scenario.task(state: "working", builder: builder, criteria: %w[build build review], title: "Stored title",
      goal: "Stored goal.", details: "Stored details.")
    first, second = Criterion.where(task_id: task.id, kind: "build").order(:position).to_a
    first.update!(state: "passed")
    Evidence.create!(workspace_id: scenario.workspace_id, criterion_id: second.id, kind: "text", value: "Second proof.",
      attached_by_seat_id: builder.id)
    Evidence.create!(workspace_id: scenario.workspace_id, criterion_id: first.id, kind: "link",
      value: "https://example.test/first", attached_by_seat_id: builder.id)
    pending = scenario.pending_transition(task, command: "submit", requester: builder,
      params: { "id" => task.id, "handoff_note" => "Made-up note." })
    check = scenario.rule_check(task, rule: rule, pending: pending)

    input = input_for(job_of(check))

    assert_matches_component("RuleCheckJobInput", input)
    material = input.fetch("material")
    assert_equal "before work is submitted", material.fetch("moment")
    assert_equal({ "title" => "Stored title", "goal" => "Stored goal.", "details" => "Stored details.",
                   "criteria" => [ { "text" => "Made-up criterion 1.", "kind" => "build", "state" => "passed" },
                                   { "text" => "Made-up criterion 2.", "kind" => "build", "state" => "open" },
                                   { "text" => "Made-up criterion 3.", "kind" => "review", "state" => "open" } ] },
      material.fetch("contract"))
    assert_equal [ { "label" => "evidence", "text" => "https://example.test/first" },
                   { "label" => "evidence", "text" => "Second proof." },
                   { "label" => "handoff_note", "text" => "Made-up note." } ], material.fetch("quoted")
    assert_equal Leverage::HookInputs.for(hook: "task.before_submit", task: task, params: pending.params), input.fetch("inputs")
    assert_nothing_of_another_task(input)
  end

  test "a check when the review has passed hands the requested notes, then the evidence" do
    rule = model_rule(hook: "task.before_done")
    reviewer = scenario.seat(role: "reviewer", credential: scenario.credential)
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)
    build = Criterion.find_by!(task_id: task.id, kind: "build")
    Evidence.create!(workspace_id: scenario.workspace_id, criterion_id: build.id, kind: "link",
      value: "https://example.test/proof", attached_by_seat_id: task.builder_seat_id)
    pending = scenario.pending_transition(task, command: "pass_review", requester: reviewer,
      params: { "id" => review.id, "verdict" => "passed", "notes" => "Made-up review notes." })
    check = scenario.rule_check(task, rule: rule, pending: pending, subject: review)

    material = input_for(job_of(check)).fetch("material")

    assert_equal "when the review has passed", material.fetch("moment")
    assert_equal [ { "label" => "review_notes", "text" => "Made-up review notes." },
                   { "label" => "evidence", "text" => "https://example.test/proof" } ], material.fetch("quoted")
  end

  test "a check before an agent starts it names the claiming agent's provider and model" do
    rule = model_rule(hook: "task.before_claim")
    task = scenario.task(state: "ready")
    claimant = scenario.seat(role: "builder", credential: scenario.credential(provider: "gemini"), model: "gemini-model-1")
    pending = scenario.pending_transition(task, command: "claim", requester: claimant, params: {})
    check = scenario.rule_check(task, rule: rule, pending: pending, subject: claimant)

    input = input_for(job_of(check))

    assert_matches_component("RuleCheckJobInput", input)
    assert_equal [ { "label" => "agent", "text" => "Provider: gemini. Model: gemini-model-1." } ],
      input.dig("material", "quoted")
    assert_equal({ "contract_version" => task.contract_version, "seat_id" => claimant.id }, input.fetch("inputs"))
  end

  test "a contract draft hands the task's text, the criteria it has and its three stored values (RD-37)" do
    project = scenario.project
    task = scenario.task(state: "backlog", project: project, criteria: [], title: "Draft me", goal: "Made-up goal.",
      details: nil, work_reference: "~/work/made-up")
    Criterion.create!(workspace_id: scenario.workspace_id, task_id: task.id, position: 1, kind: "review",
      text: "A reviewer agrees.")
    task.update!(minimum_strength_rank: 2, budget_cap: 12.5)
    job = scenario.job(kind: "contract_draft", task: task,
      input: { "task_id" => task.id, "project_id" => project.id, "brief_version" => 0 })

    input = input_for(job)

    assert_matches_component("ContractDraftJobInput", input)
    assert_equal [ task.id, project.id, 0 ], input.values_at("task_id", "project_id", "brief_version")
    assert_equal({ "role_file" => Leverage::RoleFiles.text("planner"), "title" => "Draft me", "goal" => "Made-up goal.",
                   "details" => nil, "criteria" => [ { "text" => "A reviewer agrees.", "kind" => "review" } ],
                   "work_reference" => "~/work/made-up", "minimum_strength_rank" => 2, "budget_cap" => 12.5,
                   "brief" => [] }, input.fetch("material"))
    assert_nothing_of_another_task(input)
  end
end
