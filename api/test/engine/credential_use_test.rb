require "test_helper"

class CredentialUseTest < ActiveSupport::TestCase
  Use = Leverage::CredentialUse

  setup do
    @scenario = Scenario.new
    @credential = @scenario.credential
  end

  test "a seat's own credential is in use even without a run" do
    @scenario.seat(credential: @credential, token: false)
    assert Use.in_use?(@credential)
  end

  test "the credential a seat's run is on is in use" do
    seat = @scenario.seat(credential: @scenario.credential)
    @scenario.run(seat, on: @credential)
    assert Use.in_use?(@credential)
  end

  test "a task's recorded credential is in use until Done or Cancelled" do
    task = @scenario.task(state: "working")
    task.update!(credential_id: @credential.id)
    assert Use.in_use?(@credential)

    task.update!(credential_id: nil)
    %w[done cancelled].each do |state|
      @scenario.task(state: state).update!(credential_id: @credential.id)
    end
    refute Use.in_use?(@credential)
  end

  test "a review's recorded credential is in use until it has a verdict" do
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task)
    review.update!(credential_id: @credential.id)
    assert Use.in_use?(@credential)

    review.update!(verdict: "passed")
    refute Use.in_use?(@credential)
  end

  %w[queued claimed].each do |state|
    test "a #{state} job's recorded credential is in use" do
      job = @scenario.job(kind: "contract_draft", task: @scenario.task, state: state, seat: @scenario.planner)
      job.update!(credential_id: @credential.id)
      assert Use.in_use?(@credential)

      job.update!(state: "finished", finished_at: @scenario.database_now)
      refute Use.in_use?(@credential)
    end
  end

  test "an open hold's credential is in use even with no Needs you item" do
    hold = @scenario.hold(@scenario.task(state: "working"), reason: "credential_limit", credential: @credential, item: false)
    assert Use.in_use?(@credential)

    hold.update!(closed_at: @scenario.database_now, closed_by_kind: "app")
    refute Use.in_use?(@credential)
  end

  test "an open Needs you item's credential is in use" do
    own = @scenario.credential
    task = @scenario.task(state: "working", builder: @scenario.seat(credential: own))
    hold = @scenario.hold(task, reason: "credential_limit", credential: own)
    item = InboxItem.find_by!(hold_id: hold.id)
    item.update!(credential_id: @credential.id)
    assert Use.in_use?(@credential)

    item.update!(state: "resolved", resolved_at: @scenario.database_now, resolved_by_kind: "app")
    refute Use.in_use?(@credential)
  end

  test "a removed seat's own credential is free and release clears that column" do
    seat = @scenario.remove(@scenario.seat(credential: @credential, token: false))
    refute Use.in_use?(@credential)

    release
    assert_nil seat.reload.credential_id
    @credential.delete
  end

  test "a removed seat's run credential is free and release clears that column" do
    own = @scenario.credential
    seat = @scenario.seat(credential: own)
    @scenario.run(seat, on: @credential)
    @scenario.remove(seat)
    refute Use.in_use?(@credential)

    release
    assert_nil seat.reload.run_credential_id
    assert_equal own.id, seat.credential_id
  end

  test "release preserves a removed seat's run on a different credential" do
    other = @scenario.credential
    seat = @scenario.seat(credential: @credential)
    @scenario.run(seat, on: other)
    @scenario.remove(seat)

    release

    assert_nil seat.reload.credential_id
    assert_equal other.id, seat.run_credential_id
  end

  test "release marks each unfinished helper request failed and preserves its neighbours" do
    kinds = %w[read_usage verify open_sign_in]
    unfinished = kinds.product(%w[queued picked_up]).map do |kind, state|
      @scenario.helper_request(credential: @credential, kind: kind, state: state)
    end
    finished = @scenario.helper_request(credential: @credential, kind: "verify", state: "finished")
    other = @scenario.helper_request(credential: @scenario.credential, kind: "read_usage")

    at = release

    unfinished.each do |request|
      assert_equal [ "failed", at, nil ], request.reload.attributes.values_at("state", "finished_at", "result")
    end
    assert_equal "finished", finished.reload.state
    assert_equal "queued", other.reload.state
  end

  private

  def release
    Credential.transaction do
      ctx = @scenario.context
      Use.release(ctx, @credential)
      ctx.at
    end
  end
end
