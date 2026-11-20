require "test_helper"

# ContractDiff (PRD Contract edits and cancel, L205; milestone 3 plan HE-25
# (i)): a criterion keeps its identity by position and kind. The same
# position, kind and text is kept with its state and evidence; the same
# position and kind with another text is reset to open; a new position is
# added, a position that is gone is removed, and a changed kind is a
# removal and an addition.
class ContractDiffTest < ActiveSupport::TestCase
  D = Leverage::ContractDiff

  setup do
    @scenario = Scenario.new
    @task = @scenario.task(state: "ready", criteria: %w[build build review])
    @criteria = Criterion.where(task_id: @task.id, removed_at: nil).order(:position).to_a
  end

  def spec(text, kind) = { "text" => text, "kind" => kind }

  # The specs that keep every criterion as it is.
  def same = @criteria.map { |criterion| spec(criterion.text, criterion.kind) }

  def write(wanted) = D.write(@task, wanted, at: @scenario.database_now)

  test "the same position, kind and text is kept" do
    diff = D.compare(@criteria, same)

    assert_equal @criteria, diff.kept
    assert_empty diff.reset
    assert_empty diff.added
    assert_empty diff.removed
  end

  test "the same position and kind with another text is reset" do
    wanted = same
    wanted[1] = spec("A changed second criterion.", "build")
    diff = D.compare(@criteria, wanted)

    assert_equal [ @criteria[0], @criteria[2] ], diff.kept
    assert_equal [ [ @criteria[1], wanted[1] ] ], diff.reset
    assert_empty diff.added
    assert_empty diff.removed
  end

  test "a new position is added, in order" do
    wanted = same.insert(2, spec("A third build criterion.", "build"))
    diff = D.compare(@criteria, wanted)

    assert_equal [ @criteria[0], @criteria[1] ], diff.kept
    # Position 3 was the review; it is now a build criterion, so the review
    # there is removed and two criteria are added, at 3 and 4.
    assert_equal [ [ 3, wanted[2] ], [ 4, wanted[3] ] ], diff.added
    assert_equal [ @criteria[2] ], diff.removed
    assert_empty diff.reset
  end

  test "a position that is gone is removed" do
    wanted = [ same.first, same.last ]
    diff = D.compare(@criteria, wanted)

    # Position 2 was a build criterion and is now the review: a changed kind.
    assert_equal [ @criteria[0] ], diff.kept
    assert_equal [ [ 2, wanted[1] ] ], diff.added
    assert_equal [ @criteria[1], @criteria[2] ], diff.removed
  end

  test "a changed kind with the same text is a removal and an addition" do
    wanted = same
    wanted[1] = spec(@criteria[1].text, "review")
    wanted[2] = spec(@criteria[2].text, "build")
    diff = D.compare(@criteria, wanted)

    assert_equal [ @criteria[0] ], diff.kept
    assert_equal [ [ 2, wanted[1] ], [ 3, wanted[2] ] ], diff.added
    assert_equal [ @criteria[1], @criteria[2] ], diff.removed
    assert_empty diff.reset
  end

  test "against no criteria, every criterion is added" do
    diff = D.compare([], same)

    assert_equal same.each_with_index.map { |wanted, index| [ index + 1, wanted ] }, diff.added
    assert_empty diff.kept
  end

  test "write keeps a passed criterion passed, with its state and evidence" do
    passed = @criteria[0]
    passed.update!(state: "passed", passed_at: @scenario.database_now)
    started = @criteria[1]
    started.update!(state: "started")
    written = write(same)

    assert_equal [ [], [], [] ], [ written.added_ids, written.reset_ids, written.removed_ids ]
    assert_equal "passed", passed.reload.state
    assert passed.passed_at
    assert_equal "started", started.reload.state
  end

  test "write resets a changed criterion to open in place, keeping its id" do
    changed = @criteria[0]
    changed.update!(state: "passed", passed_at: @scenario.database_now)
    wanted = same
    wanted[0] = spec("A changed first criterion.", "build")
    written = write(wanted)

    assert_equal [ changed.id ], written.reset_ids
    changed.reload
    assert_equal [ "open", nil, nil, "A changed first criterion.", nil ],
      changed.attributes.values_at("state", "passed_at", "passed_by_seat_id", "text", "removed_at")
  end

  test "write removes, then adds, so a changed kind keeps one criterion at each position" do
    at = @scenario.database_now
    wanted = same
    wanted[1] = spec("Now the review.", "review")
    wanted[2] = spec("Now a build criterion.", "build")
    wanted << spec("The independent review, last.", "review")
    written = D.write(@task, wanted, at: at)

    assert_equal [ @criteria[1].id, @criteria[2].id ], written.removed_ids
    assert_equal 3, written.added_ids.size
    @criteria[1..].each { |criterion| assert_equal at, criterion.reload.removed_at }
    current = Criterion.where(task_id: @task.id, removed_at: nil).order(:position)
    assert_equal [ 1, 2, 3, 4 ], current.map(&:position)
    assert_equal wanted.map { |entry| entry.fetch("text") }, current.map(&:text)
    assert_equal written.added_ids, current.drop(1).map(&:id)
    assert current.drop(1).all? { |criterion| criterion.state == "open" && criterion.workspace_id == @task.workspace_id }
  end

  test "write leaves an earlier removed criterion alone" do
    old = @criteria[2]
    old.update!(removed_at: @scenario.database_now)
    Criterion.create!(workspace_id: @task.workspace_id, task_id: @task.id, position: 3, kind: "review", text: old.text)
    written = write(same)

    assert_equal [ [], [], [] ], [ written.added_ids, written.reset_ids, written.removed_ids ]
  end
end
