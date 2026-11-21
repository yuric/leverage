require "test_helper"

# CR-10 and CR-22: the workspace timer schedules reads and retains readings.
class UsageReadDueTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @at = @scenario.database_now
    @requests = HelperRequest.where(workspace_id: @scenario.workspace_id)
  end

  test "the timer queues one read per due account without appending events or command rows" do
    @scenario.live_helper(at: @at)
    login = @scenario.credential
    token = @scenario.token_credential
    @scenario.reading(token, observed_at: @at, created_at: @at - 10.minutes)
    fresh = @scenario.credential
    @scenario.reading(fresh, observed_at: @at - 12.minutes, created_at: @at - 1.minute)
    @scenario.credential(state: "signed_out")
    @scenario.credential(added: false, state: "active")
    picked_up = @scenario.helper_request(kind: "read_usage", credential: @scenario.credential, state: "picked_up", at: @at)
    events = Event.where(workspace_id: @scenario.workspace_id)
    commands = Command.where(workspace_id: @scenario.workspace_id)

    assert_no_difference [ -> { events.count }, -> { commands.count } ] do
      assert fire_timer.completed?
      assert fire_timer.completed?
    end

    queued = @requests.where(kind: "read_usage", state: "queued")
    assert_equal [ login.id, token.id ].sort, queued.pluck(:credential_id).sort
    [ login, token ].each do |credential|
      assert_equal({ "provider" => credential.provider, "credential_kind" => credential.kind },
        queued.find_by!(credential_id: credential.id).params)
    end
    assert_equal "picked_up", picked_up.reload.state
  end

  test "the timer queues no read when the workspace helper's last report is too old" do
    @scenario.credential
    @scenario.live_helper(at: @at - 91.seconds)

    assert fire_timer.completed?

    assert_empty @requests
  end

  test "the timer purges old terminal usage read requests and retains readings and other requests" do
    credential = @scenario.credential
    reading = @scenario.reading(credential, observed_at: @at - 8.days, created_at: @at - 8.days)
    old = %w[finished failed].map do |state|
      @scenario.helper_request(kind: "read_usage", credential: credential, state: state, at: @at - 8.days)
    end
    recent = @scenario.helper_request(kind: "read_usage", credential: credential, state: "finished", at: @at - 6.days)
    unfinished = @scenario.helper_request(kind: "read_usage", credential: credential, at: @at - 8.days)
    verify = @scenario.helper_request(kind: "verify", credential: credential, state: "finished", at: @at - 8.days)

    assert fire_timer.completed?

    assert_empty @requests.where(id: old.map(&:id))
    assert_equal [ recent.id, unfinished.id, verify.id ].sort, @requests.pluck(:id).sort
    assert CredentialReading.exists?(reading.id)
  end

  private

  def fire_timer
    Leverage::Timers.apply_workspace(@scenario.workspace_id, "usage_read_due", at: @at)
  end
end
