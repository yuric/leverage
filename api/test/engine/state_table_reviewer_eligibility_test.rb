require "test_helper"

# Test 3 (PRD L836; milestone 4 plan RT-5, WP13) for the one command no
# other state-table class walks: the reviewer_eligibility timer, whose one
# row reads no task state and writes no event of its own, only the item
# "No reviewer is eligible" opened and resolved beside it (SM-42, RD-51).
# The sweep runs it on every pass (Timers.apply_workspace, as the app, no
# key). The real engine decides, on the rows of a workspace with the
# shipped rules: the task was built on Claude, and its only other reviewer
# is on Codex, whose one login is at a limit, so nobody may review it; when
# that limit resets the timer resolves the item, with no command between.
class StateTableReviewerEligibilityTest < ActiveSupport::TestCase
  COMMANDS = %w[reviewer_eligibility].freeze
  ITEM = "no_reviewer_eligible".freeze

  def timer(scenario)
    before = scenario.workspace.reload.last_seq
    outcome = Leverage::Timers.apply_workspace(scenario.workspace_id, "reviewer_eligibility", at: scenario.database_now)
    [ outcome, Event.where(workspace_id: scenario.workspace_id).where("seq > ?", before).order(:seq).to_a ]
  end

  StateTableCases.define(self, COMMANDS) do |kase|
    assert_nil kase.from
    assert_nil kase.to
    side = kase.row.fetch("side_events").map { |event| event.fetch("event") }
    scenario = Scenario.new
    scenario.with_shipped_rules
    builder = scenario.seat(role: "builder", credential: scenario.credential(provider: "claude"))
    task = scenario.task(state: "in_review", builder: builder)
    scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude"))
    codex = scenario.credential(provider: "codex")
    scenario.seat(role: "reviewer", credential: codex)
    scenario.limit_credential(codex, reset_at: scenario.database_now + 3600)

    outcome, opened = timer(scenario)
    assert outcome.completed?, "#{kase.name}: #{outcome.refusal&.code}"
    assert_equal kase.events + %w[inbox.opened], opened.map(&:type), "the item opens beside the row's no event"
    item = InboxItem.find_by!(workspace_id: scenario.workspace_id, kind: ITEM, state: "open")
    assert_equal [ "task", task.id ], item.attributes.values_at("about_kind", "about_id")
    assert_equal [ "app", nil, nil ], opened.sole.attributes.values_at("actor_kind", "actor_id", "command_id")

    _outcome, again = timer(scenario)
    assert_empty again, "nothing is written while nothing changes"

    codex.update!(limited_until: scenario.database_now - 1)
    outcome, resolved = timer(scenario)
    assert outcome.completed?
    assert_equal %w[inbox.resolved], resolved.map(&:type)
    assert_equal item.id, resolved.sole.subject_id
    assert_equal "resolved", item.reload.state
    assert_empty (opened + resolved).map(&:type) - kase.events - side, "#{kase.name} writes only its side events"
  end
end
