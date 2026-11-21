require "test_helper"

# Activity uses the board's sequence to page backwards through the same
# events tail as a live client (milestone 5 plan AU-4).
class EventsWindowTest < CommittingTestCase
  include ActionDispatch::IntegrationTest::Behavior

  test "the three Activity windows meet without gaps or duplicates" do
    seat = scenario.seat(role: "builder")
    ActiveRecord::Base.transaction do
      1_201.times { scenario.append("seat.paused", subject: seat, actor_kind: "owner", actor_id: scenario.owner.id) }
    end
    headers = { "Authorization" => "Bearer #{scenario.owner_token}", "Content-Type" => "application/json" }
    get "/v1/owner/board", headers: headers
    assert_response :ok
    last = response.parsed_body.fetch("as_of_seq")

    newest = window(last, headers)
    middle = window(newest.first - 1, headers)
    oldest = window(middle.first - 1, headers)

    assert_equal [ last - 1_000, 500, 500 ], [ oldest.length, middle.length, newest.length ]
    assert_equal (1..last).to_a, oldest + middle + newest
  end

  def window(last, headers)
    after = [ last - 500, 0 ].max
    get "/v1/owner/events", params: { after_seq: after, limit: 500 }, headers: headers
    assert_response :ok
    response.parsed_body.fetch("events").map { |event| event.fetch("seq") }.take_while { |seq| seq <= last }
  end
end
