require "test_helper"
require_relative "handoff_support"

class ReportReadingTest < ActiveSupport::TestCase
  include HandoffSupport

  setup { use_scenario(lease_length_seconds: 3600) }

  test "a reading is stored as sent once per helper key without an event" do
    credential = scenario.token_credential
    observed_at = from_now(-60).round(6)
    figure = limit_figure(0).merge("reset_at" => (observed_at + 60).utc.iso8601(6), "value" => "Made-up value")
    resets = [ { "count" => 0, "kind" => "full", "expires_at" => (observed_at + 120).utc.iso8601(6) } ]
    request = helper_request("report_reading",
      reading_params(credential, observed_at: observed_at, figures: [ figure ], resets: resets))

    assert_empty events_written {
      2.times { assert_completed(T.apply(request)) }
    }

    readings = CredentialReading.newest_for(credential)
    assert_equal 1, readings.count
    reading = readings.first
    assert_equal [ observed_at, "ok", "0.0.0-example", [ figure ], resets ],
      [ reading.observed_at, reading.state, reading.tool_version, reading.figures, reading.resets ]
    receipt = Command.find_by!(workspace_id: scenario.workspace_id, key: request.key)
    assert_equal receipt.created_at, reading.created_at
  end

  test "an unknown, removed, pending or foreign credential is not found" do
    removed = scenario.credential
    removed.delete
    ids = [ SecureRandom.uuid, removed.id, scenario.credential(added: false).id, Scenario.new.credential.id ]

    ids.each do |id|
      assert_raises(T::NotFound) { helper_command("report_reading", reading_params(id)) }
    end
    assert_empty CredentialReading.where(workspace_id: scenario.workspace_id)
  end

  test "the path and body must name the same credential" do
    credential = scenario.credential
    params = reading_params(credential).merge("credential_id" => scenario.credential.id)

    assert_raises(T::Invalid) { helper_command("report_reading", params) }
    assert_empty CredentialReading.where(workspace_id: scenario.workspace_id)
  end

  test "a reading must have an ISO 8601 observation time" do
    params = reading_params(scenario.credential).merge("observed_at" => "made-up invalid time")

    assert_raises(T::Invalid) { helper_command("report_reading", params) }
    assert_empty CredentialReading.where(workspace_id: scenario.workspace_id)
  end

  test "capacity closes a hold with no reset and resolves its item with the helper's key" do
    credential, seat, task, hold = held_on_limit
    written = events_written { assert_completed(report_reading(credential, key: "reading-without-reset")) }

    assert_equal %w[hold.closed inbox.resolved], written.map(&:type)
    assert_equal [ hold.id, InboxItem.find_by!(hold_id: hold.id).id ], written.map(&:subject_id)
    assert written.all? { |event| event.cause_id.nil? && event.task_id == task.id }
    assert_equal({ "choice" => nil }, written.last.payload)
    assert_helper_events(written, "reading-without-reset")
    assert_limit_cleared(credential, seat, task, hold)
  end

  test "capacity closes a hold with an hour to reset, even when the server clock steps back" do
    credential, seat, task, hold = held_on_limit(reset_at: from_now(3600))
    latest = Event.where(workspace_id: scenario.workspace_id).order(:seq).last
    context_clock = Leverage::WorkspaceLock.method(:clock)
    Leverage::WorkspaceLock.define_singleton_method(:clock) { latest.at - 0.040 }

    written = events_written { assert_completed(report_reading(credential, key: "reading-before-reset")) }

    assert_equal [ "hold.closed" ], written.map(&:type)
    assert_equal latest.at + Rational(1, 1_000_000), written.first.at
    assert_equal written.first.at, CredentialReading.newest_for(credential).sole.created_at
    assert_helper_events(written, "reading-before-reset")
    assert_limit_cleared(credential, seat, task, hold)
  ensure
    Leverage::WorkspaceLock.define_singleton_method(:clock, context_clock) if context_clock
  end

  test "capacity for another candidate closes the hold and switches the work in event order" do
    first = scenario.credential
    spare = scenario.limit_credential(scenario.credential(provider: "codex"))
    first, seat, task, hold = held_on_limit(credential: first, reset_at: from_now(3600))

    written = events_written { assert_completed(report_reading(spare, key: "reading-for-spare")) }

    assert_equal %w[hold.closed credential.switched], written.map(&:type)
    assert_equal [ hold.id, spare.id ], written.map(&:subject_id)
    assert_equal written.first.id, written.last.cause_id
    assert_equal first.id, written.last.payload.fetch("from_credential_id")
    assert_helper_events(written, "reading-for-spare")
    assert_limit_cleared(spare, seat, task, hold)
  end

  test "capacity does not close an unrelated hold or one for a sign-out" do
    recovered = scenario.limit_credential(scenario.credential)
    own = scenario.credential
    builder = scenario.seat(credential: own)
    unrelated = scenario.task(state: "working", builder: builder)
    unrelated_hold = scenario.hold(unrelated, reason: "credential_limit", credential: own)
    signed_out = scenario.task(state: "working", builder: scenario.seat(credential: recovered))
    signed_out_hold = scenario.hold(signed_out, reason: "credential_signed_out", credential: recovered)

    assert_empty events_written { assert_completed(report_reading(recovered)) }
    assert_nil recovered.reload.limited_since
    assert_nil unrelated_hold.reload.closed_at
    assert_nil signed_out_hold.reload.closed_at
  end

  test "a full, different, stale, simultaneous, signed-out or unavailable reading leaves the hold open" do
    credential, _seat, _task, hold = held_on_limit
    cases = [
      { figures: [ limit_figure(100) ] },
      { figures: [ limit_figure(40, window: "weekly") ] },
      { figures: [ limit_figure(40), limit_figure(100) ] },
      { figures: [ limit_figure(nil) ] },
      { observed_at: credential.limited_since - 1 },
      { observed_at: credential.limited_since },
      { state: "signed_out" },
      { state: "unavailable" }
    ]

    cases.each do |reading|
      before = credential.reload.attributes
      assert_empty events_written { assert_completed(report_reading(credential, **reading)) }, reading.inspect
      assert_equal before, credential.reload.attributes, reading.inspect
      assert_nil hold.reload.closed_at, reading.inspect
    end
    assert_equal cases.size, CredentialReading.newest_for(credential).count
  end

  test "a limit with no named window needs room in every limit figure" do
    credential, seat, task, hold = held_on_limit(window: nil)
    activity = limit_figure(100).merge("kind" => "activity")
    week = limit_figure(40, window: "weekly")

    assert_empty events_written { assert_completed(report_reading(credential, figures: [ activity ])) }
    assert_empty events_written {
      assert_completed(report_reading(credential, figures: [ limit_figure(100), week ]))
    }
    assert_nil hold.reload.closed_at
    assert_not_nil credential.reload.limited_since

    written = events_written do
      assert_completed(report_reading(credential, figures: [ limit_figure(40), week, activity ]))
    end

    assert_equal %w[hold.closed inbox.resolved], written.map(&:type)
    assert_limit_cleared(credential, seat, task, hold)
  end

  test "a reading with a full figure never imposes a new limit" do
    credential = scenario.credential
    before = credential.reload.attributes

    assert_empty events_written { assert_completed(report_reading(credential, figures: [ limit_figure(100) ])) }
    assert_equal before, credential.reload.attributes
    assert_equal 1, CredentialReading.newest_for(credential).count
  end

  private

  def held_on_limit(credential: scenario.credential, reset_at: nil, window: "five_hour")
    seat = scenario.seat(credential: credential, wanted_running: true)
    task = scenario.task(state: "working", builder: seat)
    assert_completed(report_limit(credential, seat, task: task, reset_at: reset_at, window: window))
    [ credential.reload, seat, task, open_hold(task) ]
  end

  def report_reading(credential, key: new_key, **fields)
    helper_command("report_reading", reading_params(credential, **fields), key: key)
  end

  def reading_params(credential, observed_at: from_now(1), state: "ok", figures: [ limit_figure(40) ], resets: nil)
    id = credential.is_a?(Credential) ? credential.id : credential
    { "id" => id, "credential_id" => id, "observed_at" => observed_at.utc.iso8601(6), "state" => state,
      "tool_version" => "0.0.0-example", "figures" => figures, "resets" => resets }
  end

  def limit_figure(percent, window: "five_hour")
    { "label" => "Made-up limit", "kind" => "limit", "window" => window, "percent_used" => percent,
      "reset_at" => nil, "value" => nil }
  end

  def assert_helper_events(written, key)
    assert_equal [ [ "app", scenario.helper.id, key ] ],
      written.map { |event| [ event.actor_kind, event.actor_id, event.command_id ] }.uniq
  end

  def assert_limit_cleared(credential, seat, task, hold)
    assert_equal [ nil, nil, "active" ], credential.reload.attributes.values_at("limited_since", "limited_until", "state")
    assert_not_nil hold.reload.closed_at
    assert_equal [ "working", credential.id ], [ task.reload.state, task.credential_id ]
    start = HelperRequest.find_by!(workspace_id: scenario.workspace_id, kind: "start_seat", seat_id: seat.id)
    assert_equal [ credential.id, task.id ], [ start.credential_id, start.params.fetch("task_id") ]
  end
end
