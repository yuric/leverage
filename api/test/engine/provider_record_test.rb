require "test_helper"
require_relative "entries/handoff_support"

# The record of which credential did each claim and each review (PRD L871,
# L690, L911-L912; milestone 3 plan HE-38, HE-41): every builder's
# credential of a task, and every reviewer's of a review, can be read back
# from task.claimed, review.started and the credential.switched events, and
# each read-back matches what the task's and the review's rows recorded at
# that moment. Milestone 4 computes the providers that built a task from
# the same events; until then a reviewer's handoff may land on any
# provider (HE-41), and the case this test plays lands on one that did not
# build the task.
class ProviderRecordTest < ActiveSupport::TestCase
  include HandoffSupport

  setup do
    use_scenario(lease_length_seconds: 3600)
  end

  def seat_command(seat, command, params = {})
    assert_completed(T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: new_key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"),
      params: params)))
  end

  # The credentials that built the task, in order: task.claimed, then each
  # credential.switched of the task's build work (no review named).
  def built_by(task)
    Event.where(task_id: task.id, type: %w[task.claimed credential.switched]).order(:seq).filter_map do |event|
      if event.type == "task.claimed" then event.payload["credential_id"]
      elsif event.payload["review_id"].nil? then event.subject_id
      end
    end
  end

  # The credentials that did a review, in order: review.started, then each
  # credential.switched that names the review.
  def reviewed_by(review)
    Event.where(task_id: review.task_id).order(:seq).filter_map do |event|
      if event.type == "review.started" && event.subject_id == review.id then event.payload["credential_id"]
      elsif event.type == "credential.switched" && event.payload["review_id"] == review.id then event.subject_id
      end
    end
  end

  def providers(ids) = Credential.where(id: ids).distinct.pluck(:provider).sort

  test "every builder's and every reviewer's credential is read back from the log, and a reviewer's handoff in this case lands on a provider that did not build the task (HE-38, HE-41)" do
    gemini = scenario.credential(provider: "gemini", model: "gemini-model-1")
    grok = scenario.credential(provider: "grok", model: "grok-model-1")
    claude = scenario.credential(provider: "claude", model: "claude-model-1")
    codex = scenario.credential(provider: "codex")
    reviewer = scenario.seat(role: "reviewer", credential: gemini, model: "gemini-model-1")
    builder = scenario.seat(role: "builder", credential: claude, model: "claude-model-1")
    task = scenario.task(state: "ready", criteria: %w[build review])
    recorded = []

    seat_command(builder, "claim")
    recorded << task.reload.credential_id
    assert_completed(report_limit(claude, builder, task: task, reset_at: from_now(3600)))
    recorded << task.reload.credential_id
    assert_equal codex.id, recorded.last, "the builder's handoff is recorded on the task"
    scenario.run(builder, on: codex)

    seat_command(builder, "acknowledge_briefing", "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task.reload, seat: builder))
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    seat_command(builder, "pass_criterion", "id" => task.id, "cid" => criterion.id,
      "evidence" => { "kind" => "link", "value" => "https://example.test/made-up-proof" })
    seat_command(builder, "submit", "id" => task.id, "handoff_note" => "A made-up note.", "work_reference" => nil)

    seat_command(reviewer, "claim_review")
    review = Review.find_by!(task_id: task.id, round: 0)
    reviewers = [ review.reload.credential_id ]
    assert_completed(report_limit(gemini, reviewer, review: review, reset_at: from_now(3600)))
    reviewers << review.reload.credential_id
    scenario.run(reviewer, on: grok)

    seat_command(reviewer, "acknowledge_review_briefing", "id" => review.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task.reload, seat: reviewer, review: review))
    claude.update!(limited_until: from_now(-1))
    seat_command(reviewer, "fail_review", "id" => review.id, "verdict" => "failed", "failed_criteria" => [ criterion.id ],
      "notes" => "Made-up notes.", "tokens" => 1, "spend" => 0)
    recorded << task.reload.credential_id

    assert_equal [ claude.id, codex.id, claude.id ], recorded
    assert_equal recorded, built_by(task)
    assert_equal [ gemini.id, grok.id ], reviewers
    assert_equal reviewers, reviewed_by(review)
    assert_equal %w[claude codex], providers(built_by(task))
    assert_equal %w[gemini grok], providers(reviewed_by(review))
    assert_not_includes providers(built_by(task)), "grok", "the review moved to a provider that did not build the task"
  end

  test "the providers that built a task are read from the same events: every builder's credential and every seat that held it with no credential, never a review's or a job's (L448, milestone 4 RD-50)" do
    claude = scenario.credential(provider: "claude")
    codex = scenario.credential(provider: "codex")
    gemini = scenario.credential(provider: "gemini")
    grok = scenario.credential(provider: "grok_api", kind: "api_token")
    builder = scenario.seat(role: "builder", credential: claude)
    task = scenario.task(state: "working", builder: builder)
    switched = lambda do |credential, review_id: nil, job_id: nil|
      scenario.append("credential.switched", task: task, subject: credential,
        payload: { from_credential_id: claude.id, model: nil, seat_id: builder.id, review_id: review_id, job_id: job_id })
    end
    record = -> { Leverage::Rules::ProviderRecord.groups(task.id) }

    assert_equal %w[anthropic], record.call
    switched.call(codex)
    assert_equal %w[anthropic openai], record.call
    switched.call(gemini, review_id: SecureRandom.uuid)
    switched.call(grok, job_id: SecureRandom.uuid)
    assert_equal %w[anthropic openai], record.call, "a review's and a job's runs did not build the task"

    on_its_own = scenario.seat(role: "builder", provider: "openrouter")
    scenario.append("task.claimed", task: task, actor_kind: "seat", actor_id: on_its_own.id,
      payload: { seat_id: on_its_own.id, credential_id: nil, model: nil })
    assert_equal %w[anthropic openai openrouter], record.call
    Leverage::Gating.implementation = Leverage::Rules::Engine.new
    assert_equal record.call, Leverage::Gating.built_by_providers(task_id: task.id)
  end

  test "a builder that connects on its own counts by its seat's provider; a task with no builder has none" do
    own = scenario.seat(role: "builder", provider: "gemini")
    task = scenario.task(state: "in_review", builder: own)

    assert_equal %w[google], Leverage::Rules::ProviderRecord.groups(task.id)
    assert_equal [], Leverage::Rules::ProviderRecord.groups(scenario.task.id)
    assert_equal [], Leverage::Rules::ProviderRecord.groups(SecureRandom.uuid)
  end
end
