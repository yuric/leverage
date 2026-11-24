require "test_helper"
require_relative "../engine/entries/jobs_support"

# Exercise the engine entry points shared by the HTTP interfaces.
class GeneralAgentsTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    scenario.with_shipped_rules
    @claude = scenario.seat(role: "general", provider: "claude", last_polled_at: scenario.database_now)
    @codex = scenario.seat(role: "general", provider: "codex", last_polled_at: scenario.database_now)
  end

  test "two General seats take a task from the form to Done with the shipped rules" do
    task = from_form
    build(task, @claude)
    review = claim_review(@codex)
    assert_completed(seat_command(@codex, "pass_review",
      { "id" => review.id, "verdict" => "passed", "notes" => "The sample matches.", "tokens" => 0, "spend" => 0 }))

    assert_equal "done", task.reload.state
    assert_equal "passed", review.reload.verdict
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
  end

  test "a different General seat may build a released task and no reviewer is eligible afterward" do
    task = from_form
    assert_completed(seat_command(@claude, "claim"))
    assert_completed(seat_command(@claude, "release", { "id" => task.id, "reason" => "stopping" }))
    build(task, @codex)

    assert_equal "in_review", task.reload.state
    assert InboxItem.exists?(workspace_id: scenario.workspace_id, about_id: task.id,
      kind: "no_reviewer_eligible", state: "open")
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
  end

  private

  def from_form
    contract = contract_body
    added = assert_completed(owner_command("add_task", contract.except("criteria", "minimum_strength_rank", "budget_cap")))
    task = Task.find(added.result.fetch("task_id"))
    assert_equal :pending, owner_command("complete_contract", contract.merge("id" => task.id)).outcome
    offer = assert_completed(claim_job(@codex)).result
    assert_equal "rule_check", offer.fetch("kind")
    assert_completed(submit_result(@codex, Job.find(offer.fetch("job_id")),
      { "result" => "passed", "reason" => "The made-up contract gives clear details." }))
    assert_equal "ready", task.reload.state
    task
  end

  def build(task, seat)
    claim = assert_completed(seat_command(seat, "claim")).result
    assert_equal task.id, claim.dig("task", "id")
    assert_nil claim.dig("briefing", "role_file")
    assert_completed(seat_command(seat, "acknowledge_briefing",
      { "id" => task.id, "briefing_hash" => Leverage::Briefing.hash_for(task.reload, seat: seat) }))
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    assert_completed(seat_command(seat, "start_criterion", { "id" => task.id, "cid" => criterion.id }))
    assert_completed(seat_command(seat, "pass_criterion", { "id" => task.id, "cid" => criterion.id,
      "evidence" => { "kind" => "note", "value" => "The sample line is present." } }))
    assert_completed(seat_command(seat, "submit", { "id" => task.id, "work_reference" => nil, "handoff_note" => "Sample ready." }))
  end

  def claim_review(seat)
    claim = assert_completed(seat_command(seat, "claim_review")).result
    review = Review.find(claim.dig("review", "id"))
    hash = Leverage::Briefing.hash_for(Task.find(review.task_id), seat: seat, review: review)
    assert_completed(seat_command(seat, "acknowledge_review_briefing", { "id" => review.id, "briefing_hash" => hash }))
    review
  end
end
