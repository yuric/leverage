require "test_helper"
require_relative "entries/accounts_support"

class CredentialsHookIntegrationTest < ActiveSupport::TestCase
  include AccountsSupport

  setup do
    use_scenario
    @credential = scenario.credential
  end

  test "a usage receipt updates the request without opening an inbox item or granting an action lease" do
    request = queue_request("read_usage", credential: @credential, state: "picked_up")
    unrelated_tasks
    assert_empty events_written { report(request, checks: [ check("reading_taken") ]) }.map(&:type)
    assert_equal "finished", request.reload.state
  end

  test "a Verify receipt after Remove leaves the request and the waiting tasks alone" do
    request = queue_request("verify", credential: @credential, state: "picked_up")
    assert_completed owner_command("remove_credential", { "id" => @credential.id })
    original = request.reload.attributes
    unrelated_tasks
    assert_empty events_written { report(request) }.map(&:type)
    assert_equal original, request.reload.attributes
  end

  %w[run_add_checks verify].each do |kind|
    test "a passed #{kind} receipt still rechecks reviewers and waiting action leases" do
      credential = kind == "run_add_checks" ? scenario.credential(added: false) : @credential
      request = queue_request(kind, credential: credential)
      unrelated_tasks
      events = events_written { report(request) }
      assert_equal %w[inbox.opened action.lease_granted], events.last(2).map(&:type)
      assert_equal "no_reviewer_eligible", events[-2].payload["kind"]
    end
  end

  test "Refresh queues a read without granting an unrelated lease" do
    unrelated_tasks
    assert_empty events_written { assert_completed owner_command("refresh_usage") }.map(&:type)
    assert HelperRequest.exists?(credential_id: @credential.id, kind: "read_usage")
  end

  test "the usage timer queues a due read without granting an unrelated lease" do
    scenario.live_helper(at: scenario.database_now)
    unrelated_tasks
    assert_empty events_written {
      Leverage::Timers.apply_workspace(scenario.workspace_id, "usage_read_due", at: scenario.database_now)
    }.map(&:type)
    assert HelperRequest.exists?(credential_id: @credential.id, kind: "read_usage")
  end

  test "a reading with no capacity evidence is stored without granting an unrelated lease" do
    unrelated_tasks
    params = { "id" => @credential.id, "credential_id" => @credential.id, "observed_at" => scenario.database_now.iso8601(6),
      "state" => "unavailable", "figures" => [], "resets" => nil, "tool_version" => nil }
    assert_empty events_written { assert_completed helper_command("report_reading", params) }.map(&:type)
    assert CredentialReading.exists?(credential_id: @credential.id, state: "unavailable")
  end

  test "a reading that restores a waiting builder's account can grant its action lease" do
    builder = scenario.seat(credential: @credential)
    task = scenario.finishing_task(builder: builder, holder: false, actions: [ { kind: "send", state: "approved" } ])
    scenario.limit_credential(@credential, since: scenario.database_now - 1.minute, seat: builder)
    at = Event.where(subject_id: @credential.id, type: "credential.limit_reached").maximum(:effective_at) + 1.second
    params = { "id" => @credential.id, "credential_id" => @credential.id, "observed_at" => at.iso8601(6),
      "state" => "ok", "resets" => nil, "tool_version" => nil,
      "figures" => [ { "label" => "Made-up limit", "kind" => "limit", "window" => "five_hour", "percent_used" => 25,
        "reset_at" => nil, "value" => nil } ] }
    events = events_written { assert_completed helper_command("report_reading", params) }
    assert_includes events.map(&:type), "action.lease_granted"
    assert_equal builder.id, task.reload.holder_seat_id
  end

  test "renaming to the same name writes nothing with a waiting action" do
    unrelated_tasks
    assert_empty events_written {
      assert_completed owner_command("rename_credential", { "id" => @credential.id, "name" => @credential.name })
    }
  end

  test "a reorder matching the current order writes nothing with a waiting action" do
    unrelated_tasks
    assert_empty events_written { assert_completed owner_command("reorder_credentials", { "order" => [ @credential.id ] }) }.map(&:type)
  end

  test "a changed order that gives the waiting builder a candidate can grant its action lease" do
    own = scenario.credential
    builder = scenario.seat(credential: own)
    task = scenario.finishing_task(builder: builder, holder: false, actions: [ { kind: "send", state: "approved" } ])
    scenario.limit_credential(own, seat: builder)
    refute Leverage::Finishing.builder_free?(task)

    events = events_written { assert_completed owner_command("reorder_credentials", { "order" => [ own.id, @credential.id ] }) }
    assert_includes events.map(&:type), "action.lease_granted"
    assert_equal builder.id, task.reload.holder_seat_id
  end

  private

  def report(request, **fields)
    assert_completed helper_command("report_request_result", { "id" => request.id, "result" => result_body(**fields) })
  end

  def unrelated_tasks
    scenario.with_shipped_rules
    reviewer = scenario.seat(role: "reviewer")
    scenario.finishing_task(reviewer: reviewer, holder: false, actions: [ { kind: "send", state: "approved" } ])
    scenario.remove(reviewer)
    scenario.task(state: "in_review")
  end
end
