require "test_helper"
require_relative "accounts_support"
require_relative "call_spy"

class RemoveCredentialTest < ActiveSupport::TestCase
  include AccountsSupport
  include CallSpy

  setup { use_scenario }

  test "a seat's configured credential is in use before it gets a run" do
    credential = scenario.credential
    seat = scenario.seat(credential: credential, token: false)

    assert_in_use(credential, seat)
  end

  test "the credential a seat's run uses is in use" do
    credential = scenario.credential
    seat = scenario.seat(credential: scenario.credential)
    scenario.run(seat, on: credential)

    assert_in_use(credential, seat)
  end

  test "an unfinished task's recorded credential is in use" do
    credential = scenario.credential
    task = scenario.task(state: "working")
    task.update!(credential_id: credential.id)

    assert_in_use(credential, task)
  end

  test "a review's recorded credential is in use while it awaits a verdict" do
    credential = scenario.credential
    review = scenario.review(scenario.task(state: "in_review"))
    review.update!(credential_id: credential.id)

    assert_in_use(credential, review)
  end

  %w[queued claimed].each do |state|
    test "a #{state} job's recorded credential is in use" do
      credential = scenario.credential
      job = scenario.job(kind: "contract_draft", task: scenario.task, state: state, seat: scenario.planner)
      job.update!(credential_id: credential.id)

      assert_in_use(credential, job)
    end
  end

  test "an open hold's credential is in use without a Needs you item" do
    credential = scenario.credential
    task = scenario.task(state: "working")
    hold = scenario.hold(task, reason: "credential_limit", credential: credential, item: false)

    assert_in_use(credential, hold)
  end

  test "an open Needs you item's credential is in use even if its hold names another credential" do
    credential = scenario.credential
    task = scenario.task(state: "working")
    hold = scenario.hold(task, reason: "credential_limit", credential: scenario.credential)
    item = InboxItem.find_by!(hold_id: hold.id)
    item.update!(credential_id: credential.id)

    assert_in_use(credential, item, hold)
  end

  test "Remove deletes the credential and its readings, clears removed seats and fails unfinished requests" do
    credential = scenario.credential
    other = scenario.credential
    own_seat = scenario.remove(scenario.seat(credential: credential, run_credential_id: other.id))
    run_seat = scenario.remove(scenario.seat(credential: other, run_credential_id: credential.id))
    readings = [ scenario.reading(credential), scenario.reading(credential) ]
    other_reading = scenario.reading(other)
    unfinished = %w[read_usage verify open_sign_in].product(%w[queued picked_up]).map do |kind, state|
      scenario.helper_request(kind: kind, credential: credential, state: state)
    end
    finished = %w[finished failed].map do |state|
      scenario.helper_request(kind: "verify", credential: credential, state: state,
        result: result_body(outcome: state, checks: login_checks(failed: ("signed_in" if state == "failed"))))
    end
    other_request = scenario.helper_request(kind: "read_usage", credential: other)
    history = finished + [ other, other_reading, other_request ]
    before = history.map { |row| row.reload.attributes }

    key = new_key
    written = events_written { assert_completed(remove(credential.id, key: key)) }

    assert_equal %w[credential.removed], written.map(&:type)
    removed = written.first
    assert_equal [ "credential", credential.id, "owner", scenario.owner.id, key, {} ],
      [ removed.subject_kind, removed.subject_id, removed.actor_kind, removed.actor_id, removed.command_id, removed.payload ]
    refute Credential.exists?(credential.id)
    refute CredentialReading.exists?(id: readings.map(&:id))
    assert_equal [ nil, other.id ], own_seat.reload.attributes.values_at("credential_id", "run_credential_id")
    assert_equal [ other.id, nil ], run_seat.reload.attributes.values_at("credential_id", "run_credential_id")
    unfinished.each do |request|
      assert_equal [ "failed", credential.id, removed.at, nil ],
        request.reload.attributes.values_at("state", "credential_id", "finished_at", "result")
    end
    assert_equal before, history.map { |row| row.reload.attributes }
  end

  test "removing a seat then its credential leaves the helper's stop available to finish" do
    credential = scenario.credential
    seat = scenario.seat(credential: credential, run_state: "running", wanted_running: true)
    assert_completed owner_command("remove_seat", { "id" => seat.id })
    stop = HelperRequest.find_by!(seat_id: seat.id, kind: "stop_seat")

    assert_completed remove(credential.id)

    assert_equal stop, Leverage::Reads::HelperNext.call(scenario.workspace_id)
    assert_equal "picked_up", T::MarkRead.helper_request(stop).state
    assert_completed helper_command("report_request_result", { "id" => stop.id, "result" => result_body(checks: []) })
    assert_equal "finished", stop.reload.state
  end

  test "finished work and resolved Needs you history survive Remove" do
    credential = scenario.credential
    done = scenario.task(state: "done")
    cancelled = scenario.task(state: "cancelled")
    review = Review.find_by!(task_id: done.id)
    job = scenario.job(kind: "contract_draft", task: done, state: "finished", seat: scenario.planner)
    held = scenario.task(state: "working")
    hold = scenario.hold(held, reason: "credential_limit", credential: credential)
    item = InboxItem.find_by!(hold_id: hold.id)
    Hold.transaction { Leverage::Holds.close(scenario.context, hold: hold, task: held) }
    history = [ done, cancelled, review, job ]
    history.each { |row| row.update!(credential_id: credential.id) }
    history += [ hold, item ]
    before = history.map { |row| row.reload.attributes }
    assert_equal "resolved", item.state

    assert_completed(remove(credential.id))

    refute Credential.exists?(credential.id)
    assert_equal before, history.map { |row| row.reload.attributes }
  end

  test "Remove reevaluates credential holds once after its event and never reevaluates reviewer eligibility" do
    own = scenario.credential
    fallback = scenario.credential
    seat = scenario.seat(credential: own)
    task = scenario.task(state: "working", builder: seat)
    scenario.limit_credential(own)
    scenario.limit_credential(fallback, reset_at: scenario.database_now + 1.hour)
    hold = scenario.hold(task, reason: "credential_limit", credential: own, item: false)
    assert_equal fallback.limited_until, Leverage::Candidates.due_at(seat, task, scenario.database_now)
    key = new_key
    written = nil
    handoff = nil
    outcome = nil

    reviewer_checks = spy_on(Leverage::ReviewerEligibility, :reevaluate) do
      handoff = spy_on(Leverage::Handoff, :reevaluate) do
        written = events_written { outcome = assert_completed(remove(fallback.id, key: key)) }
      end
    end

    assert_equal %w[credential.removed inbox.opened], written.map(&:type)
    assert_equal [ written.first.id ], handoff.map { |call| call.keywords[:cause]&.id }
    assert_equal [ key, key ], written.map(&:command_id)
    assert_equal written.first.id, written.last.cause_id
    assert_empty reviewer_checks
    assert_nil hold.reload.closed_at
    item = InboxItem.find_by!(hold_id: hold.id, state: "open")
    assert_equal [ "limit_with_no_reset_time", own.id, item.id ], [ item.kind, item.credential_id, written.last.subject_id ]

    repeated = nil
    repeated_handoff = spy_on(Leverage::Handoff, :reevaluate) do
      assert_empty events_written { repeated = assert_completed(remove(fallback.id, key: key)) }
    end
    assert_empty repeated_handoff
    assert_nil outcome.result
    assert_nil repeated.result
    assert_equal [ item.id ], InboxItem.where(hold_id: hold.id).pluck(:id)
  end

  test "an unknown credential is not found" do
    assert_raises(T::NotFound) { remove(SecureRandom.uuid) }
  end

  test "a credential whose add is pending is not found" do
    credential = scenario.credential(added: false)

    assert_raises(T::NotFound) { remove(credential.id) }
    assert Credential.exists?(credential.id)
  end

  test "another workspace's credential is not found" do
    credential = Scenario.new.credential

    assert_raises(T::NotFound) { remove(credential.id) }
    assert Credential.exists?(credential.id)
  end

  private

  def remove(id, **options)
    owner_command("remove_credential", { "id" => id }, **options)
  end

  def assert_in_use(credential, *references)
    seat = scenario.remove(scenario.seat(credential: credential))
    reading = scenario.reading(credential)
    request = scenario.helper_request(kind: "read_usage", credential: credential)
    rows = [ credential, seat, reading, request, *references ]
    before = rows.map { |row| row.reload.attributes }

    assert_empty events_written { assert_refused("credential_in_use", remove(credential.id)) }
    assert_equal before, rows.map { |row| row.reload.attributes }
  end
end
