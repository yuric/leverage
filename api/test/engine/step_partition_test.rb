require "test_helper"
require_relative "../support/walk"

# Step partition (PRD test 2, Steps and timing; milestone 2 plan EN-25):
# for seeded random command sequences, each task's steps touch end to end
# and sum to its lifetime. 300 walks of at most 120 steps over the
# commands and timers of milestones 2 to 5 (Walk; milestone 3 plan HT-3:
# the twelve new commands, the credential timer and a credential whose
# reset time the walk moves; milestone 4 plan RT-3: the twenty new
# commands and timers, a rule set drawn per walk, an orchestrator that
# answers drawn verdicts or none, a planner, and a step for each row of
# rule 11's table; milestone 5 plan AT-3: questions, approvals, projects,
# budgets and the choices in Needs you); SEED and WALKS override.
# A failure prints the seed and the walk. The same walks also check the
# replay (test 1) and the log
# audit (L894, with RT-4's gate line), which a random sequence reaches in
# more corners than a trace.
#
#   SEED=1 WALKS=1000 bin/rails test test/engine/step_partition_test.rb
class StepPartitionTest < ActiveSupport::TestCase
  WALKS = Integer(ENV.fetch("WALKS", "300"), 10)
  SEED = Integer(ENV.fetch("SEED") { Random.new_seed.to_s }, 10) % 1_000_000_000
  STEPS = 120

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
      # One command's events share at (the workspace lock): a waiting
      # command's own events written inside it carry another key (RE-3).
      commands = Event.where(task_id: task.id).pluck(:id, :at).to_h
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

  # Milestone 4's commands the walks must reach and see completed (its
  # plan RT-3). The one-time write runs when each walk starts.
  RULE_CHECKS = %w[
    add_rule save_rule enable_rule disable_rule revert_rule remove_rule rerun_check override_check draft_contract
    claim_job submit_job_result report_job_limit
  ].freeze

  # The ends of a waiting command (rule 11's table) the twenty walks reach:
  # the command that withdrew a waiting command's check. The other rows
  # need a pass that waits on a gate at task.before_done, which a walk of
  # 100 steps reaches too seldom to count on; each row is held by
  # state_table_pending_ends_test.rb, state_table_review_and_seat_ends_test.rb,
  # state_table_handoff_test.rb and trace 18 instead.
  RULE_11_REACHED = %w[cancel edit_contract].freeze

  # Fixed seeds, as COVERAGE_SEEDS: forty, because twenty walks seldom
  # time out a contract draft both in the queue and while it runs.
  # Seed 218 also reaches Check could not run with the milestone 5 draws.
  RULE_CHECK_SEEDS = [ 218, *(10_001..10_040) ].freeze

  test "the walks complete milestone 4's commands, run its timers on due jobs and end waiting commands" do
    completed = Set.new
    ends = Set.new
    timed_out = Set.new
    items = Set.new
    installed = true
    RULE_CHECK_SEEDS.each do |seed|
      walk = Walk.new(seed: seed, steps: STEPS).run
      completed.merge(walk.log.select { |step| step.answer.start_with?("completed") }.map(&:command))
      events = Event.where(workspace_id: walk.workspace_id)
      installed &&= events.where(type: "rule.created", actor_kind: "app", command_id: nil).count == 7
      timed_out.merge(events.where(type: "job.timed_out").joins("JOIN jobs ON jobs.id = events.subject_id")
        .pluck(Arel.sql("jobs.kind"), Arel.sql("CASE WHEN jobs.claimed_at IS NULL THEN 'queue' ELSE 'run' END")))
      items.merge(events.where(type: "inbox.opened").map { |event| event.payload["kind"] })
      ends.merge(waiting_ends(walk.workspace_id))
    end
    assert installed, "every walk starts with the seven shipped rules from the one-time write"
    assert_empty RULE_CHECKS - completed.to_a, "the walks never completed these"
    assert_equal [ %w[contract_draft queue], %w[contract_draft run], %w[rule_check queue], %w[rule_check run] ],
      timed_out.select { |kind, _due| %w[contract_draft rule_check].include?(kind) }.sort,
      "each milestone 4 job timer times a job out"
    assert_empty %w[orchestrator_offline no_reviewer_eligible check_could_not_run] - items.to_a
    assert_empty RULE_11_REACHED - ends.to_a, "no walk ended a waiting command this way"
  end

  # AT-3: the app asks about each action and grants delayed leases from
  # inside a different command. Those entries show up in events rather
  # than as requests in the walk log.
  QUESTIONS_AND_APPROVALS = %w[
    approve_action stop_action start_action report_action_done waive_action mark_action_done offer_task_again
    return_for_rework overturn_approval ask_question request_access answer_question overturn_answer grant_access
    report_cost create_project edit_brief pause_project resume_project change_budget change_task_priority
    change_task_project change_task_cap delete_content change_workspace_settings
  ].freeze
  # These draws reach owner, question and project outcomes alongside the
  # busy-builder and action-completion path that starts the test below.
  QUESTIONS_AND_APPROVALS_SEEDS = [ 10_075, 10_084, 10_088, 10_101, 10_105 ].freeze

  test "the walks complete milestone 5's commands and run its timers on due jobs" do
    commands = Set.new(QUESTIONS_AND_APPROVALS)
    action_events = Set.new(%w[action.requested action.lease_granted])
    timed_out = Set.new([ %w[approval queue], %w[approval run], %w[question queue], %w[question run] ])
    walks = QUESTIONS_AND_APPROVALS_SEEDS.lazy.map { |seed| Walk.new(seed: seed, steps: STEPS).run }
    finishing = Walk.new(seed: 10_121, steps: STEPS).run_finishing
    assert_empty partition_problems(finishing.workspace_id, database_now), finishing.to_s
    assert_empty Leverage::Replay.diff(finishing.workspace_id), finishing.to_s
    assert_empty Leverage::LogAudit.call(finishing.workspace_id), finishing.to_s

    [ finishing ].each.chain(walks).each do |walk|
      commands.subtract(walk.log.select { |step| step.answer == "completed" }.map(&:command))
      events = Event.where(workspace_id: walk.workspace_id)
      action_events.subtract(events.where(type: action_events.to_a).distinct.pluck(:type))
      timed_out.subtract(events.where(type: "job.timed_out").joins("JOIN jobs ON jobs.id = events.subject_id")
        .pluck(Arel.sql("jobs.kind"), Arel.sql("CASE WHEN jobs.claimed_at IS NULL THEN 'queue' ELSE 'run' END")))
      break if commands.empty? && action_events.empty? && timed_out.empty?
    end
    missing = { commands: commands.to_a, action_events: action_events.to_a, job_timeouts: timed_out.to_a }.reject do |_, outcomes|
      outcomes.empty?
    end
    assert_empty missing, "the walks never reached these outcomes"
  end

  # The commands that withdrew a check of a waiting command (rule 11):
  # the command whose key wrote the withdrawn check.finished, or the lease
  # timer whose end came with it.
  def waiting_ends(workspace_id)
    withdrawn = Event.where(workspace_id: workspace_id, type: "check.finished").select { |event| event.payload["result"] == "withdrawn" }
    withdrawn.filter_map do |event|
      if event.command_id
        Command.where(workspace_id: workspace_id, key: event.command_id).pick(:command)
      else
        ends = Event.where(workspace_id: workspace_id, at: event.at, command_id: nil, task_id: event.task_id)
        { "task.lease_expired" => "builder_lease_expiry", "review.lease_expired" => "review_lease_expiry" }
          .find { |type, _| ends.exists?(type: type) }&.last
      end
    end
  end

  test "a walk is the same walk for the same seed" do
    first = Walk.new(seed: SEED, steps: 20).run
    second = Walk.new(seed: SEED, steps: 20).run
    strip = ->(walk) { walk.log.map { |step| [ step.action, step.command, step.answer.gsub(/\h{8}-\h{4}-\S+/, "") ] } }
    assert_equal strip.call(first), strip.call(second)
  end

  test "a walk's diagnostic omits request content" do
    walk = Walk.new(seed: 1)
    text = "A made-up private question."
    walk.log << Walk::Step.new(4, :holder_command, "ask_question", "builder", { "text" => text }, "completed")

    diagnostic = walk.to_s
    assert diagnostic.include?("ask_question by builder") && diagnostic.include?("-> completed"),
      "the diagnostic should identify the command, caller and outcome"
    refute diagnostic.include?(text), "the diagnostic disclosed request content"
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
