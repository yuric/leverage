require "test_helper"
require_relative "rows"

# The migration that folds a task's goal into its details and drops the
# goal column (contract decision UI-1): nothing is lost, and it folds every
# example of api/contract/goal_fold.json as the eval cases are folded.
class FoldTaskGoalTest < ActiveSupport::TestCase
  include DbRows

  MIGRATION = Dir[File.expand_path("../../db/migrate/*_fold_task_goal_into_details.rb", __dir__)].first

  def migration
    assert MIGRATION, "no *_fold_task_goal_into_details.rb migration"
    require MIGRATION
    FoldTaskGoalIntoDetails.new.tap { |instance| instance.verbose = false }
  end

  def goal_column?
    sql("SELECT 1 FROM information_schema.columns WHERE table_name = 'tasks' AND column_name = 'goal'").rows.any?
  end

  # Fires the deferred checks of the rows inserted so far (the state
  # trigger, C7), which PostgreSQL requires before an ALTER TABLE of tasks in
  # the same transaction, then defers them again.
  def settle_inserts
    sql("SET CONSTRAINTS ALL IMMEDIATE")
    sql("SET CONSTRAINTS ALL DEFERRED")
  end

  def details_of(id)
    sql("SELECT details FROM tasks WHERE id = $1", id).rows.first.first
  end

  teardown do
    db.schema_cache.clear!
    ActiveRecord::Base.descendants.each(&:reset_column_information)
  end

  test "the goal column is gone" do
    refute goal_column?
  end

  test "UI-1: every goal_fold.json example is folded as it says" do
    examples = Leverage::Contract.load("goal_fold.json").fetch("examples")
    change = migration
    change.migrate(:down)
    assert goal_column?, "down brings the column back, empty"
    ids = examples.to_h do |example|
      [ example.fetch("name"), task(title: example["title"], goal: example["goal"], details: example["details"]) ]
    end
    settle_inserts
    change.migrate(:up)
    refute goal_column?
    examples.each do |example|
      expected = example.fetch("details_after")
      actual = details_of(ids.fetch(example["name"]))
      expected.nil? ? assert_nil(actual, example["name"]) : assert_equal(expected, actual, example["name"])
    end
  end

  test "UI-1: a task whose content was deleted stays blank" do
    change = migration
    change.migrate(:down)
    id = task(title: nil, goal: nil, details: nil, content_deleted_at: Time.utc(2026, 11, 24))
    settle_inserts
    change.migrate(:up)
    assert_nil details_of(id)
  end
end
