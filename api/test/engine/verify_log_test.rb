require "test_helper"
require_relative "../support/walk"

# leverage:verify_log (PRD L896, L921 "a restore passes the replay test";
# milestone 2 plan §1.1, SC-12): the command that checks a database's log
# runs the replay (Leverage::Replay.diff) and the log audit
# (Leverage::LogAudit) for each workspace, or for the one WORKSPACE_ID
# names, prints one line per workspace and every finding, and exits
# non-zero when anything is found.
class VerifyLogTest < ActiveSupport::TestCase
  def verify(workspace_id)
    task = Rake::Task["leverage:verify_log"]
    task.reenable
    saved = ENV.fetch("WORKSPACE_ID", nil)
    ENV["WORKSPACE_ID"] = workspace_id
    task.invoke
  ensure
    ENV["WORKSPACE_ID"] = saved
  end

  setup { Rails.application.load_tasks unless Rake::Task.task_defined?("leverage:verify_log") }

  test "a log the engine wrote passes, with one line for the workspace" do
    walk = Walk.new(seed: 31).run
    out, = capture_io { verify(walk.workspace_id) }
    assert_match(/workspace #{walk.workspace_id}: \d+ events, replay ok, audit ok/, out)
  end

  test "a column changed without an event fails the check and is named" do
    walk = Walk.new(seed: 32).run
    task = Task.where(workspace_id: walk.workspace_id).first
    assert task, walk.to_s
    task.update_columns(round: task.round + 5)
    error = nil
    out, err = capture_io do
      error = assert_raises(SystemExit) { verify(walk.workspace_id) }
    end
    refute error.success?
    assert_match(/tasks #{task.id} round/, out + err)
  end

  test "an unknown workspace fails the check" do
    _out, err = capture_io do
      assert_raises(SystemExit) { verify(SecureRandom.uuid) }
    end
    assert_match(/no such workspace/, err)
  end
end
