require "test_helper"

# Milestone 6 plan §2.1 rule 6 and CR-14 through CR-16.
class ReadingCapacityTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @credential = @scenario.credential
    @seat = @scenario.seat(credential: @credential)
    @task = @scenario.task(state: "working", builder: @seat)
    @limited_since = @scenario.database_now.change(usec: 0)
  end

  { "without a reset time" => nil, "with a reset time an hour away" => 1.hour }.each do |name, reset_after|
    test "#{name}: the refused window at 100 percent still has no capacity" do
      report_limit(reset_after: reset_after)

      refute shown?([ limit("five_hour", 100) ])
    end

    test "#{name}: the refused window at 99.9 percent shows capacity even if another window is full" do
      report_limit(reset_after: reset_after)

      assert shown?([ limit("five_hour", 99.9), limit("weekly", 100) ])
    end

    test "#{name}: every limit figure for the refused window must have capacity" do
      report_limit(reset_after: reset_after)

      refute shown?([ limit("five_hour", 99.9), limit("five_hour", 100) ])
    end

    test "#{name}: a reading that only has room in another window proves nothing" do
      report_limit(reset_after: reset_after)

      refute shown?([ limit("weekly", 1) ])
    end

    test "#{name}: an unavailable reading proves nothing" do
      report_limit(reset_after: reset_after)

      refute shown?([ limit("five_hour", 1) ], state: "unavailable")
    end

    test "#{name}: a signed-out reading proves nothing" do
      report_limit(reset_after: reset_after)

      refute shown?([ limit("five_hour", 1) ], state: "signed_out")
    end

    test "#{name}: a reading observed before the limit proves nothing" do
      report_limit(reset_after: reset_after)

      refute shown?([ limit("five_hour", 1) ], observed_at: @limited_since - 1.second)
    end

    test "#{name}: a reading observed at the limit proves nothing" do
      report_limit(reset_after: reset_after)

      refute shown?([ limit("five_hour", 1) ], observed_at: @limited_since)
    end
  end

  test "a refusal with no window is cleared if every limit figure has room" do
    report_limit(window: nil)

    assert shown?([ limit("five_hour", 99.9), limit("weekly", 1), balance ])
  end

  test "a refusal with no window remains if any limit figure is full" do
    report_limit(window: nil)

    refute shown?([ limit("five_hour", 99.9), limit("weekly", 100) ])
  end

  test "a refusal with no window needs at least one limit figure" do
    report_limit(window: nil)

    refute shown?([ balance ])
  end

  test "a limit figure without a percentage does not prove capacity" do
    report_limit

    refute shown?([ limit("five_hour", 1), limit("five_hour", nil) ])
  end

  test "an existing limit with no refusal event has no known window" do
    @scenario.limit_credential(@credential, since: @limited_since)

    assert shown?([ limit("five_hour", 1), limit("weekly", 99.9) ])
    refute shown?([ limit("five_hour", 1), limit("weekly", 100) ])
  end

  test "a credential without a current limit cannot show capacity" do
    report_limit
    @credential.update!(limited_since: nil)

    refute shown?([ limit("five_hour", 1) ])
  end

  test "an elapsed reset time leaves no limit for a reading to clear" do
    report_limit(reset_after: 1.hour)

    refute shown?([ limit("five_hour", 1) ], created_at: @limited_since + 1.hour)
  end

  test "every window refused since this limit began needs evidence of room" do
    report_limit(window: "weekly")
    report_limit(window: "five_hour")

    refute shown?([ limit("five_hour", 1) ])
    refute shown?([ limit("five_hour", 1), limit("weekly", 100) ])
    assert shown?([ limit("five_hour", 1), limit("weekly", 2) ])
  end

  test "a refusal without a window also requires room in every limit figure" do
    report_limit(window: nil)
    report_limit(window: "five_hour")

    refute shown?([ limit("five_hour", 1), limit("weekly", 100) ])
    refute shown?([ limit("weekly", 1) ])
    assert shown?([ limit("five_hour", 1) ])
  end

  test "refusals before this limit began do not determine its windows" do
    report_limit(window: "weekly")
    @limited_since = @scenario.database_now
    report_limit(window: "five_hour")

    assert shown?([ limit("five_hour", 1) ])
  end

  test "a newer refusal for another credential does not determine the window" do
    report_limit(window: "five_hour")
    other = @scenario.credential
    seat = @scenario.seat(credential: other)
    task = @scenario.task(state: "working", builder: seat)
    @scenario.limit_credential(other, seat: seat, task: task, window: "weekly")

    assert shown?([ limit("five_hour", 1), limit("weekly", 100) ])
  end

  test "a newer event with the same subject id in another workspace does not determine the window" do
    report_limit(window: "five_hour")
    own_event = Event.find_by!(workspace_id: @scenario.workspace_id, type: "credential.limit_reached")
    other = Scenario.new
    seat = other.seat(credential: other.credential)
    task = other.task(state: "working", builder: seat)
    other.credential
    # A log subject is a polymorphic id. Give the foreign log a matching
    # subject id to make the workspace condition observable independently.
    foreign_event = other.append("credential.limit_reached", task: task, subject: @credential,
      payload: { seat_id: seat.id, review_id: nil, job_id: nil, window: "weekly", reset_at: nil })

    assert_operator foreign_event.seq, :>, own_event.seq
    assert shown?([ limit("five_hour", 1), limit("weekly", 100) ])
  end

  private

  def report_limit(window: "five_hour", reset_after: nil)
    reset_at = @limited_since + reset_after if reset_after
    @scenario.limit_credential(@credential, since: @limited_since, seat: @seat, task: @task, window: window,
      reset_at: reset_at)
  end

  def shown?(figures, state: "ok", observed_at: @limited_since + 1.second, created_at: @limited_since + 2.seconds)
    reading = @scenario.reading(@credential, observed_at: observed_at, state: state, figures: figures, created_at: created_at)
    Leverage::ReadingCapacity.shown?(@credential, reading)
  end

  def limit(window, percent)
    { label: "Made-up usage", kind: "limit", window: window, percent_used: percent, reset_at: nil, value: nil }
  end

  def balance
    { label: "Made-up balance", kind: "allowance", window: nil, percent_used: nil, reset_at: nil, value: 1 }
  end
end
