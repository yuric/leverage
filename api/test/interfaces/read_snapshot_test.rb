require "test_helper"

# Every owner read runs in one repeatable-read, read-only transaction in
# which the workspace's last_seq is read with the rows, so the rows and
# as_of_seq are one moment of the log (milestone 2 plan MA-20). Proven here
# the hard way: a second connection commits an event between two statements
# of the read, and both the rows and as_of_seq still show the earlier state.
# A CommittingTestCase, because a snapshot cannot be opened inside a test's
# own transaction.
class ReadSnapshotTest < CommittingTestCase
  Reads = Leverage::Reads

  # Runs `read` and, right after its first statement against workspaces (the
  # one that reads last_seq), commits `change` from a second connection, so
  # every later statement of the read comes after the commit. Returns the
  # read's answer and whether the change ran.
  def read_with_commit_between(read, &change)
    reader = Thread.current
    fired = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      next unless Thread.current == reader && !fired && sql.match?(/FROM "workspaces"/) && !sql.match?(/FOR UPDATE/)

      fired = true
      Thread.new { ActiveRecord::Base.connection_pool.with_connection(&change) }.join
    end
    [ read.call, fired ]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def last_seq = Workspace.find(scenario.workspace_id).last_seq

  setup do
    @builder = scenario.seat(role: "builder", credential: scenario.credential)
    scenario.seat(role: "reviewer")
    @task = scenario.task(state: "ready")
    @before = last_seq
  end

  test "the board shows neither the task nor the position committed in the middle of the read" do
    board, fired = read_with_commit_between(-> { Reads::Board.call(scenario.workspace_id) }) do
      scenario.task(state: "backlog", title: "Added in the middle")
    end

    assert fired, "the second connection must have committed during the read"
    assert_operator last_seq, :>, @before
    assert_equal @before, board.fetch(:as_of_seq)
    assert_equal [ @task.id ], board.fetch(:tasks).map { |card| card.fetch(:task).fetch(:id) }
  end

  test "the task page shows neither the new event nor the position committed in the middle of the read" do
    page, fired = read_with_commit_between(-> { Reads::TaskPage.call(scenario.workspace_id, @task.id) }) do
      scenario.append("task.changed", task: @task.reload, actor_kind: "owner", actor_id: scenario.owner.id,
        payload: { priority: "high", project_id: nil, budget_cap: nil })
    end

    assert fired
    assert_equal @before, page.fetch(:as_of_seq)
    assert_equal Event.where(task_id: @task.id, seq: ..@before).order(:seq).pluck(:seq), page.fetch(:events).map { |event| event.fetch(:seq) }
    assert_operator Event.where(task_id: @task.id).count, :>, page.fetch(:events).size
  end

  test "the roster shows neither the seat nor the position committed in the middle of the read" do
    roster, fired = read_with_commit_between(-> { Reads::Seats.call(scenario.workspace_id) }) do
      scenario.seat(role: "builder", name: "Added in the middle")
    end

    assert fired
    assert_equal @before, roster.fetch(:as_of_seq)
    assert_equal 2, roster.fetch(:seats).size
    assert_equal 3, Seat.where(workspace_id: scenario.workspace_id).count
  end

  test "the credentials list shows neither the credential nor the position committed in the middle of the read" do
    list, fired = read_with_commit_between(-> { Reads::Credentials.call(scenario.workspace_id) }) do
      scenario.credential(name: "Added in the middle")
    end

    assert fired
    assert_equal @before, list.fetch(:as_of_seq)
    assert_equal 1, list.fetch(:credentials).size
    assert_equal 2, Credential.where(workspace_id: scenario.workspace_id).count
  end

  test "a helper request shows the state and the position of the moment the read began" do
    request = HelperRequest.create!(workspace_id: scenario.workspace_id, kind: "stop_seat", state: "picked_up", requested_at: Time.current)
    status, fired = read_with_commit_between(-> { Reads::HelperRequest.call(scenario.workspace_id, request.id) }) do
      request.update!(state: "finished", finished_at: Time.current)
      scenario.append("seat.connected", subject: @builder, actor_kind: "owner", actor_id: scenario.owner.id)
    end

    assert fired
    assert_equal "finished", request.reload.state
    assert_equal "picked_up", status.fetch(:request).fetch(:state)
    assert_equal @before, status.fetch(:as_of_seq)
  end

  test "the system health counts are one moment too" do
    health, fired = read_with_commit_between(-> { Reads::SystemHealth.call(scenario.workspace_id) }) do
      scenario.task(state: "ready")
    end

    assert fired
    assert_equal 1, health.fetch(:ready_tasks)
    # Uncached: the test runs inside the executor, whose query cache would answer
    # the read's own count again.
    assert_equal 2, Task.uncached { Task.where(workspace_id: scenario.workspace_id, state: "ready").count }
  end

  test "a read of an unknown workspace is a not found, never an empty answer" do
    assert_raises(ActiveRecord::RecordNotFound) { Reads::Board.call(SecureRandom.uuid) }
  end

  test "a read opens its snapshot read only: a write inside it is refused" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Reads::Snapshot.call(scenario.workspace_id) { |_as_of| Task.where(id: @task.id).update_all(title: "Changed by a read") }
    end
  end
end
