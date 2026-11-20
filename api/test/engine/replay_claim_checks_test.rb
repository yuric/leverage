require "test_helper"
require_relative "../support/walk"

# A claim waits on two model checks (two rules at "before an agent starts
# it") and one fails while the other still runs. The engine keeps the claim
# pending until the other has a result and then refuses it with every
# failure (Rules::Reentry, steps 3 and 6), so the claimant holds the Ready
# task until then. Replay must say the same: the provisional claim lapses
# when no check of it is still running and one of them failed or erred, or
# when every one was withdrawn (DB-43). Walk 44727 of the step partition
# test found replay clearing the holder at the first failure while the
# table kept it (milestone 4 WP20, the whole suite with SEED=44444).
class ReplayClaimChecksTest < ActiveSupport::TestCase
  test "walk 44727: a claim whose first check fails while its second runs replays as the table holds it" do
    walk = Walk.new(seed: 44_727, steps: 100).run
    assert_empty Leverage::Replay.diff(walk.workspace_id), walk.to_s
    assert_empty Leverage::LogAudit.call(walk.workspace_id), walk.to_s
  end
end
