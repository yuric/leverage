require "test_helper"

# Whether a role that claims jobs is online (PRD L401, L402, L909;
# milestone 4 plan §2.1 "The orchestrator's presence and its item", RD-15,
# RD-16, RD-20): some enabled, not paused, not removed seat of the role
# polled within the last 90 seconds and either connects on its own or has
# an available candidate (milestone 3 plan §2.1 rule 2). The definition is
# L401's and is not widened for a seat that is busy on a job: the reference
# runner keeps asking GET /v1/next while its tool runs (RD-15).
class RolePresenceTest < ActiveSupport::TestCase
  P = Leverage::RolePresence

  setup do
    @scenario = Scenario.new
    @now = @scenario.database_now
  end

  def online?(role = "orchestrator") = P.online?(@scenario.workspace, role, @now)

  # A seat of the role that last polled seconds_ago before @now (nil:
  # never).
  def seat(role: "orchestrator", polled: 10, **options)
    seat = @scenario.seat(role: role, **options)
    seat.update_columns(last_polled_at: polled && @now - polled)
    # The times as stored: the database keeps microseconds, the object in
    # memory the nanoseconds Ruby read, so a comparison could miss by 1 µs.
    seat.reload
  end

  # A login limited since seconds_ago, until seconds_until from @now (nil:
  # no reset time).
  def limited(credential, since:, until_in: 3600)
    credential.update_columns(limited_since: @now - since, limited_until: until_in && @now + until_in)
    credential.reload
  end

  test "a seat that polled within the last 90 seconds is online, whatever job it holds (RD-15)" do
    orchestrator = seat(polled: 89)
    task = @scenario.task(state: "backlog")
    rule = @scenario.rule(hook: "task.before_ready")
    @scenario.rule_check(task, rule: rule, started: true, checker: orchestrator)

    assert online?
    assert_nil P.offline_since(@scenario.workspace, "orchestrator", @now)
    assert_nil P.cause_credential(@scenario.workspace, "orchestrator", @now)
  end

  test "one that holds a claimed job and has not polled for 91 seconds is not" do
    orchestrator = seat(polled: 91)
    task = @scenario.task(state: "backlog")
    @scenario.rule_check(task, rule: @scenario.rule(hook: "task.before_ready"), started: true, checker: orchestrator)

    refute online?
    assert_instant orchestrator.last_polled_at + 90, P.offline_since(@scenario.workspace, "orchestrator", @now)
  end

  test "90 seconds after its last poll the seat counts as offline: that is when the item's time starts (trace 07)" do
    orchestrator = seat(polled: 90)

    refute online?
    assert_instant orchestrator.last_polled_at + 90, P.offline_since(@scenario.workspace, "orchestrator", @now)
  end

  test "a seat that never polled is offline since it was connected" do
    orchestrator = seat(polled: nil)

    refute online?
    assert_instant orchestrator.created_at, P.offline_since(@scenario.workspace, "orchestrator", @now)
  end

  test "no seat of the role at all is offline (RD-16), since the workspace began" do
    refute online?
    assert_instant @scenario.workspace.reload.created_at, P.offline_since(@scenario.workspace, "orchestrator", @now)
    assert_nil P.cause_credential(@scenario.workspace, "orchestrator", @now)
  end

  test "a paused, a disabled or a removed seat does not count, however recently it polled" do
    seat(paused: true)
    seat(enabled: false)
    seat(removed_at: @now - 1)

    refute online?
  end

  test "each role is read on its own seats" do
    seat(role: "planner")

    refute online?("orchestrator")
    assert online?("planner")
    seat(role: "builder")
    refute online?("orchestrator"), "a builder's polls are not the orchestrator's"
  end

  test "a seat the app runs counts only while one of its candidates is available (L401)" do
    own = @scenario.credential(provider: "codex")
    seat(credential: own, polled: 5)
    assert online?

    limited(own, since: 50)
    refute online?, "it polled 5 seconds ago, but no account can run it"
    assert_equal own.id, P.cause_credential(@scenario.workspace, "orchestrator", @now)&.id
    assert_instant own.limited_since, P.offline_since(@scenario.workspace, "orchestrator", @now)

    below = @scenario.credential(provider: "grok")
    assert online?, "a candidate below it is available"
    assert_nil P.cause_credential(@scenario.workspace, "orchestrator", @now)

    limited(below, since: 40)
    refute online?
    assert_instant below.limited_since, P.offline_since(@scenario.workspace, "orchestrator", @now),
      "offline since the last of its candidates stopped (trace 19: 940)"
    assert_equal own.id, P.cause_credential(@scenario.workspace, "orchestrator", @now)&.id,
      "the item names the seat's own account"
  end

  test "a signed-out own account is the cause too" do
    own = @scenario.credential(provider: "codex")
    seat(credential: own, polled: 5)
    @scenario.sign_out_credential(own)

    refute online?
    assert_equal own.id, P.cause_credential(@scenario.workspace, "orchestrator", @now)&.id
  end

  test "no account is the cause while a seat that is offline only for want of polls remains" do
    own = @scenario.credential(provider: "codex")
    seat(credential: own, polled: 5)
    limited(own, since: 50)
    seat(polled: 300)

    refute online?
    assert_nil P.cause_credential(@scenario.workspace, "orchestrator", @now)
  end

  test "with several seats the role is offline since the last of them stopped" do
    seat(polled: 300)
    later = seat(polled: 120)

    refute online?
    assert_instant later.last_polled_at + 90, P.offline_since(@scenario.workspace, "orchestrator", @now)
  end

  test "online since its seat's last poll, or since its account reset when that came after (trace 19: 1405)" do
    own = @scenario.credential(provider: "codex")
    orchestrator = seat(credential: own, polled: 20)
    assert_instant orchestrator.last_polled_at, P.online_since(@scenario.workspace, "orchestrator", @now)

    own.update_columns(limited_since: @now - 600, limited_until: @now - 10)
    assert online?
    assert_instant own.reload.limited_until, P.online_since(@scenario.workspace, "orchestrator", @now)
    assert_nil P.online_since(@scenario.workspace, "planner", @now), "an offline role has no such time"
  end

  # RD-15: the 120 seconds of L909 rest on three numbers, each a constant:
  # the 90 of L401, last-polled written at most every 10 seconds (EN-20),
  # and a sweep every 15 (EN-22).
  test "the 120-second bound of L909 holds by the constants" do
    assert_equal 90, P::OFFLINE_AFTER
    bound = P::OFFLINE_AFTER + Leverage::Transitions::RecordPoll::SEAT_SECONDS + Leverage::Sweep::INTERVAL
    assert_operator bound, :<=, 120
  end

  def assert_instant(expected, actual, message = nil)
    refute_nil actual, message
    assert_in_delta expected.to_f, actual.to_f, 0.000_001, message
  end
end
