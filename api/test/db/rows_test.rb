require "test_helper"
require_relative "rows"

# The raw rows the database tests insert are a log the app can go on from.
# StateTriggerAcrossTransactionsTest commits its rows, which stay in the
# worker's database; bin/rails leverage:install_shipped_rules, which a later
# test of the same worker runs, appends to every workspace with no rule. An
# event row that left workspaces.last_seq behind made that append take a seq
# the log already held (seed 3333 of the whole suite, milestone 4 WP20).
class DbRowsLogTest < ActiveSupport::TestCase
  include DbRows

  def last_seq = sql("SELECT last_seq FROM workspaces WHERE id = $1", workspace).rows.first.first

  test "an event row moves the workspace's last seq to its own" do
    task
    assert_equal 1, last_seq
    event(type: "task.ready")
    assert_equal 2, last_seq
  end
end
