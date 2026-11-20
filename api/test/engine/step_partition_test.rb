require "test_helper"
require_relative "../support/walk"

# Step partition (PRD test 2, Steps and timing; milestone 2 plan EN-25):
# for seeded random command sequences, each task's steps touch end to end
# and sum to its lifetime. 200 walks of at most 80 steps over the commands
# and timers of milestones 2 and 3 (Walk; milestone 3 plan HT-3: the twelve
# new commands, the credential timer and a credential whose reset time the
# walk moves); SEED and WALKS override, and a failure prints the seed and
# the walk. The same walks also check the replay (test 1) and the log audit
# (L894), which a random sequence reaches in more corners than a trace.
#
#   SEED=1 WALKS=1000 bin/rails test test/engine/step_partition_test.rb
class StepPartitionTest < ActiveSupport::TestCase
  WALKS = Integer(ENV.fetch("WALKS", "200"), 10)
  SEED = Integer(ENV.fetch("SEED") { Random.new_seed.to_s }, 10) % 1_000_000_000
  STEPS = 80

  # Milestone 3's commands and timers (its plan HT-3), which the walks must
  # reach and see completed.
  HANDOFF = %w[
    report_limit report_signed_out sign_in_again credential_hold_release seat_run_placement
    promote edit_contract hold resume pause_seat resume_seat change_seat
  ].freeze

  # The step rows of a task in the order they opened, each with the seq of
  # its opening event (a zero-length step opens and closes at one time).
  def steps_of(task)
    rows = TaskStep.where(task_id: task.id).to_a
    seqs = Event.where(id: rows.map(&:opening_event_id)).pluck(:id, :seq).to_h
    rows.sort_by { |row| [ row.opened_at, seqs.fetch(row.opening_event_id) ] }
  end

  # Every problem with the partition of each task's life into steps.
  def partition_problems(workspace_id, now)
    Task.where(workspace_id: workspace_id).flat_map do |task|
      events = Event.where(task_id: task.id).order(:seq).to_a
      created = events.find { |event| event.type == "task.created" }
      ended = events.find { |event| %w[task.done task.cancelled].include?(event.type) }
      steps = steps_of(task)
      problems = []
      problems << "no step" if steps.empty?
      next problems.map { |problem| "task #{task.id}: #{problem}" } if steps.empty?

      first = steps.first
      problems << "the first step does not open at task.created" unless first.opening_event_id == created.id &&
        first.opened_at == created.effective_at
      commands = Event.where(task_id: task.id).pluck(:id, :command_id, :at).to_h { |id, *command| [ id, command ] }
      steps.each_cons(2) do |earlier, later|
        # The same time, and an event of the same command: within one
        # command a step changes in place (steps.json), so review may close
        # at review.failed and wait_owner open at the hold.opened after it.
        next if earlier.closed_at == later.opened_at && earlier.closing_event_id &&
          commands[earlier.closing_event_id] == commands[later.opening_event_id]

        problems << "#{earlier.kind} (closed #{earlier.closed_at&.iso8601(6)}) does not touch #{later.kind} " \
                    "(opened #{later.opened_at.iso8601(6)})"
      end
      open = steps.select { |step| step.closed_at.nil? }
      problems << "#{open.size} steps open" if open.size > 1
      if ended
        problems << "a step is open after #{ended.type}" if open.any?
        last = steps.last
        problems << "the last step does not close at #{ended.type}" unless last.closing_event_id == ended.id &&
          last.closed_at == ended.effective_at
      elsif open != [ steps.last ]
        problems << "the last step is not the open one"
      end
      problems += steps.filter_map { |step| "#{step.kind} has a negative length" if step.closed_at && step.closed_at < step.opened_at }
      finish = ended ? ended.effective_at : now
      total = steps.sum { |step| (step.closed_at || now) - step.opened_at }
      lifetime = finish - created.effective_at
      problems << "steps sum to #{total} s, the task lived #{lifetime} s" if (total - lifetime).abs > 1e-6
      problems.map { |problem| "task #{task.id}: #{problem}" }
    end
  end

  WALKS.times do |number|
    seed = SEED + number
    test "walk #{number} (seed #{seed}): each task's steps touch end to end and sum to its lifetime" do
      walk = Walk.new(seed: seed, steps: STEPS).run
      now = database_now
      assert_empty partition_problems(walk.workspace_id, now), walk.to_s
      assert_empty Leverage::Replay.diff(walk.workspace_id), walk.to_s
      assert_empty Leverage::LogAudit.call(walk.workspace_id), walk.to_s
    end
  end

  # The walks this test reads are always the same twenty, whatever SEED
  # is: a walk is the same for the same seed, and twenty walks from a
  # random first seed leave a command never completed now and then (SEED=8
  # and SEED=9 of the first 60 left "resume"), which made the whole suite
  # fail by chance.
  COVERAGE_SEEDS = (10_001..10_020)

  test "the walks complete every milestone-3 command and the credential timer, and move a reset" do
    completed = Set.new
    moved = false
    COVERAGE_SEEDS.each do |seed|
      walk = Walk.new(seed: seed, steps: STEPS).run
      completed.merge(walk.log.select { |step| step.answer == "completed" }.map(&:command))
      moved ||= walk.log.any? { |step| step.action == :pass_reset }
    end
    assert_empty HANDOFF - completed.to_a, "the walks never completed these"
    assert moved, "no walk moved a reset time"
  end

  test "a walk is the same walk for the same seed" do
    first = Walk.new(seed: SEED, steps: 20).run
    second = Walk.new(seed: SEED, steps: 20).run
    strip = ->(walk) { walk.log.map { |step| [ step.action, step.command, step.answer.gsub(/\h{8}-\h{4}-\S+/, "") ] } }
    assert_equal strip.call(first), strip.call(second)
  end

  test "the partition check finds steps that do not touch" do
    walk = Walk.new(seed: 5, steps: 30).run
    step = TaskStep.where(workspace_id: walk.workspace_id).where("closed_at > opened_at").order(:opened_at).first
    assert step, walk.to_s
    assert_empty partition_problems(walk.workspace_id, database_now)
    step.delete
    refute_empty partition_problems(walk.workspace_id, database_now)
  end

  def database_now = ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
end
