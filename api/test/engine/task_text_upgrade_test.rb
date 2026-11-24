require "test_helper"
require_relative "entries/jobs_support"

class TaskTextUpgradeTest < ActiveSupport::TestCase
  include JobsSupport
  include OpenapiAssertions

  setup { use_scenario }

  test "an already waiting contract completes with its earlier check and keeps the proposed text" do
    task = scenario.task(title: "Original task", details: "Original details.")
    checker = scenario.orchestrator
    rule = model_rule
    earlier = { "goal" => "  Use the updated figures.\n", "details" => "Leave the totals on page one.",
                "criteria" => [ { "text" => "A reviewer agrees.", "kind" => "review" } ], "actions" => [] }
    digest = Digest::SHA256.hexdigest(Leverage::Gating::CanonicalJson.dump(earlier))
    pending = scenario.pending_transition(task, command: "complete_contract", requester: scenario.owner,
      params: earlier.merge("id" => task.id, "title" => "Updated task"),
      frozen_rule_version_ids: [ scenario.current_version(rule).id ])
    check = scenario.rule_check(task, rule: rule, pending: pending, input_hash: digest)
    job = job_of(check)
    job.update!(input: { "inputs" => earlier })

    request = seat_request(checker, "claim_job")
    claimed = T.apply(request)
    assert_completed(claimed)
    input = claimed.result.fetch("input")
    details = "Use the updated figures.\n\nLeave the totals on page one."
    assert_equal earlier.except("goal").merge("title" => "Updated task", "details" => details), input.fetch("inputs")
    assert_equal [ "Updated task", details ], input.fetch("material").fetch("contract").values_at("title", "details")
    assert_matches_component("RuleCheckJobInput", input)

    receipt = Command.find_by!(caller_id: checker.id, key: request.key)
    previous = receipt.result
    previous["input"]["inputs"] = earlier
    previous["input"]["material"]["contract"].merge!(earlier.slice("goal", "details"))
    receipt.update!(result: previous)
    assert_equal input, T.apply(request).result.fetch("input")
    assert_completed(submit_result(checker, job, { "result" => "passed", "reason" => "The totals can be checked." }))

    assert_equal [ "completed", "ready", "Updated task", details ],
      [ pending.reload.state, *task.reload.attributes.values_at("state", "title", "details") ]
    assert_equal digest, check.reload.input_hash
  end

  test "a stored task claim replays the title and folded details from its snapshot" do
    builder = scenario.seat(role: "builder")
    task = scenario.task(state: "ready", title: "Sample title", details: "Current details.")
    request = seat_request(builder, "claim")
    assert_completed(T.apply(request))
    row = Command.find_by!(caller_id: builder.id, key: request.key)
    previous = { "goal" => "Use the original sample.", "details" => "Original details." }
    cached = row.result
    cached.fetch("task").merge!(previous)
    cached.fetch("briefing")["contract"] = cached.fetch("briefing").fetch("contract").except("title").merge(previous)
    row.update!(result: cached)
    task.update!(title: "Current title")

    replayed = T.apply(request).result

    [ replayed.fetch("task"), replayed.fetch("briefing").fetch("contract") ].each do |text|
      assert_equal [ "Sample title", "Use the original sample.\n\nOriginal details." ], text.values_at("title", "details")
      refute text.key?("goal")
    end
    assert_matches_component("Briefing", replayed.fetch("briefing"))
    assert_equal cached, row.reload.result
  end

  test "a draft queued before the upgrade gives a dedicated planner the current result instruction" do
    planner = scenario.planner
    task = scenario.task
    scenario.job(kind: "contract_draft", task: task,
      input: { "material" => { "role_file" => 'Return {"goal": "...", "details": "...", "criteria": ["..."]}' } })

    claimed = claim_job(planner)

    assert_completed(claimed)
    input = claimed.result.fetch("input")
    assert_equal Leverage::RoleFiles.text("planner"), input.fetch("material").fetch("role_file")
    assert_matches_component("ContractDraftJobInput", input)
  end
end
