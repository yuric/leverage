require "digest"
require "json"

# A seeded random walk over the commands and timers of milestones 2 to 6
# (PRD test 2; milestone 2 plan EN-25, milestone 3 plan HT-3): owners add,
# contract and cancel tasks and allow another round; builders claim,
# acknowledge, start and pass criteria, submit, release and heartbeat;
# reviewers claim reviews, acknowledge, pass, fail, release and heartbeat;
# leases are put at their due time (EN-18) and expire through the next
# command or the sweep; and a request is sometimes sent again with its key.
#
# Milestone 3 adds the handoff and the owner's controls: the helper reports
# limits and sign-outs of the runs it starts, picks up start requests and
# answers Verify and Sign in again; the owner adds ideas and promotes them,
# edits contracts, holds and resumes tasks, and pauses, resumes and changes
# agents; the sweep also runs the credential hold release and the seats'
# placement; and a reset time is passed (pass_reset: the credential's
# limited_until is put at the database's now, as make_due puts a lease,
# EN-18).
#
# Milestone 4 (its plan RT-3) adds the rules: the shipped rules come from
# the one-time write (install_shipped_rules), some of them are turned off,
# and up to two custom rules are added at drawn moments, blocking or only
# noting; an orchestrator claims check jobs and answers drawn verdicts, or
# none (its job then times out), and a planner drafts contracts. The owner
# lets checks through once, runs them again, asks for drafts, and adds,
# saves, switches, reverts and removes rules; the helper reports a job's
# limits and sign-outs and stopped runs, a new helper token is issued and
# a spare agent removed (each a row of rule 11's table: what ends a
# waiting command from outside); the orchestrator polls or stops polling;
# and the sweep also runs the check and draft timers and the two
# workspace timers.
#
# Milestone 5 (AT-3) draws contracts with outward actions, project
# membership and budget caps. Builders ask questions, request access,
# report spend and carry out approved actions. Orchestrators answer or
# stay silent. An owner answers the choices in open Needs you items,
# overturns decisions and changes project, task and workspace settings.
#
# Milestone 6 (CT-2) adds an API token, rename, reorder, removal, Refresh,
# the usage timer and readings whose state, window and figures vary. The
# earlier coverage walks keep their original draws and request mix.
#
# Every command goes through Transitions.apply, so the whole log of the
# walk's workspace is made by the engine: the helper is made by
# issue_helper_token, the logins by add_credential and the helper's passed
# checks, and the seats by connect_seat (two builders and a reviewer on
# logins, run by the app; one builder and one reviewer that connect on
# their own); only the workspace and its owner are inserted (they write no
# event).
#
# Most steps move a seat forward (progress: the call its state calls for
# next, so walks reach review, rework, the round limit and Done); the rest
# are drawn at random, and some are calls the state does not allow, on
# purpose, which are refused or answered 404 or 422 (NotFound, Invalid) and
# write nothing.
# Any other error ends the walk; Walk#to_s is the seed and every step.
#
#   walk = Walk.new(seed: 42).run
#   walk.workspace_id
#   puts walk
class Walk
  T = Leverage::Transitions

  # What the walk can do, with how often (out of the sum).
  ACTIONS = {
    progress: 50, add_task: 4, complete_contract: 4, cancel: 1, allow_another_round: 2,
    claim: 5, acknowledge: 6, start_criterion: 4, pass_criterion: 6, submit: 5, release: 1, heartbeat: 2,
    claim_review: 5, acknowledge_review: 5, verdict: 6, release_review: 1, heartbeat_review: 1,
    expire_builder: 2, expire_review: 2, sweep: 3, repeat: 2,
    report_limit: 6, report_signed_out: 3, pass_reset: 3, verify: 2, sign_in_again: 2, answer_request: 5,
    promote: 2, edit_contract: 3, hold: 2, resume: 2, pause_seat: 2, resume_seat: 2, change_seat: 2,
    claim_job: 5, job_result: 6, expire_job: 4, override_check: 2, rerun_check: 2, draft_contract: 2,
    add_rule: 1, save_rule: 1, switch_rule: 2, revert_rule: 1, remove_rule: 1, report_job_limit: 3,
    report_job_signed_out: 2, poll: 3, stop_polling: 1, report_run_stopped: 1, start_seat: 1,
    new_helper_token: 1, remove_seat: 1, end_waiting: 6,
    holder_command: 12, answer_needs_you: 12, review_decision: 4, project_command: 10,
    task_settings: 5, workspace_settings: 2, delete_content: 3
  }.freeze
  CREDENTIAL_ACTIONS = {
    rename_credential: 2, remove_credential: 3, reorder_credentials: 3, refresh_usage: 2,
    report_reading: 6, usage_read_due: 2
  }.freeze
  # The moments a custom rule is added at (RD-21, AP-1), and the verdicts an
  # orchestrator draws (nil: it answers none, and the job times out).
  # Submit and the pass are drawn twice as often: a task reaches them less
  # often than Ready or a claim, and rule 11's ends of a builder's and a
  # reviewer's waiting command need them. "Every task needs specific
  # details" gates every contract, so it is off in more walks than the
  # other shipped rules, for the walks to reach the later moments.
  MOMENTS = %w[task.before_ready task.before_claim task.before_submit task.before_submit task.before_done
               task.before_done action.requested].freeze
  OFF = { "specific_details" => 0.6 }.freeze
  VERDICTS = [ "passed", "passed", "failed", nil ].freeze
  APPROVALS = [ "approve", "approve", "stop", "pass_to_owner", nil ].freeze
  QUESTION_BASES = [ "record", "decision", "passed_on", nil ].freeze
  JOB_TIMERS = Leverage::Timers::JOB_TIMERS.keys.freeze
  WORKSPACE_TIMERS = %w[orchestrator_offline reviewer_eligibility].freeze
  RELEASE_REASONS = %w[unable_to_continue not_suited_to_this_seat stopping].freeze
  MAXIMUM_TASKS = 8
  LIVE_TASKS = 3
  MAXIMUM_PROJECTS = 2
  CAP_AMOUNTS = [ nil, 0.10, 1.00 ].freeze
  SPEND_AMOUNTS = [ 0, 0.01, 0.10, 1.00 ].freeze
  # The logins the helper adds, in order (their positions): the builders on
  # logins run on the first two, the reviewer on a login on the third. So
  # the first builder has three candidates, the second two and the
  # reviewer one: reports reach a handoff, a hold and a released review.
  LOGINS = %w[claude codex grok].freeze
  TIMERS = %w[builder_lease_expiry review_lease_expiry credential_hold_release seat_run_placement].freeze +
    JOB_TIMERS + WORKSPACE_TIMERS
  PASSED = { "outcome" => "finished", "checks" => [ { "check" => "signed_in", "passed" => true, "failure" => nil },
                                                    { "check" => "test_prompt", "passed" => true, "failure" => nil } ],
             "tool_version" => "0.0.0-walk", "plan" => nil, "account_email" => nil }.freeze
  SIGNED_OUT = { "outcome" => "failed", "checks" => [ { "check" => "signed_in", "passed" => false, "failure" => "not_signed_in" } ],
                 "tool_version" => "0.0.0-walk", "plan" => nil, "account_email" => nil }.freeze

  Step = Data.define(:index, :action, :command, :caller, :params, :answer)

  attr_reader :seed, :scenario, :log, :credential_step_problems

  def initialize(seed:, steps: 60, credentials: false)
    @seed = seed
    @random = Random.new(seed)
    @steps = steps
    @log = []
    @credential_step_problems = []
    @credentials = credentials
    @actions = credentials ? ACTIONS.merge(CREDENTIAL_ACTIONS) : ACTIONS
    @last = nil
    @count = 0
  end

  def workspace_id = scenario.workspace_id

  def run
    @scenario = Scenario.new(lease_length_seconds: 600, maximum_rounds: 1 + @random.rand(2))
    @owner = scenario.owner
    @helper = make_helper
    @logins = LOGINS.each_with_index.map { |provider, index| add_login(provider, index) }
    add_token if @credentials
    check_first_reads
    @builders = [ connect("builder", 0, @logins[0]), connect("builder", 1, @logins[1]), connect("builder", 2) ]
    # The reviewer that connects on its own is on a provider no builder
    # uses, so the provider rule (RD-50) leaves it the reviews it refuses
    # the others.
    @reviewers = [ connect("reviewer", 0, @logins[2]), connect("reviewer", 1, provider: "gemini") ]
    @orchestrator = connect("orchestrator", 0, chance(0.5) ? @logins[1] : nil)
    @planner = connect("planner", 0)
    @spare = connect("builder", 3)
    @builders << @spare
    draw_rules
    yield if block_given?
    first = log.empty? ? 0 : log.last.index + 1
    (first...@steps).each { |index| send(pick, index) }
    self
  rescue StandardError => error
    raise Failed, "#{error.class}\n#{self}", error.backtrace, cause: nil
  end

  # Begin a seeded walk with a busy-builder handoff, an approval job
  # that misses while claimed, and two ways of completing an action.
  # Prep commands use the same real pipeline and count as walk steps.
  def run_finishing
    run do
      use_guided_rules("orchestrator_approves_actions")
      builder = @builders.fetch(2)
      task = guided_contract([
        { "kind" => "publish", "description" => "Made-up first action." },
        { "kind" => "send", "description" => "Made-up second action." }
      ])
      guided("claim", builder)
      guided_step { |index| build(index, builder) } until task.reload.state == "in_review"
      guided_pass_review

      # The task is awaiting approval and its previous builder takes a
      # different task, so approval does not immediately grant its lease.
      other = guided_contract([])
      guided("claim", builder)
      guided("claim_job", @orchestrator)
      expire_guided_job
      2.times { guided_approve_job }

      guided("release", builder, "id" => other.id, "reason" => "stopping")
      guided_step { |index| acknowledge_as(index, builder, task.reload) }
      first, second = Leverage::Actions.for_task(task).to_a
      guided("start_action", builder, "id" => task.id, "aid" => first.id)
      guided("report_action_done", builder, "id" => task.id, "aid" => first.id)
      guided("release", builder, "id" => task.id, "reason" => "stopping")
      guided("mark_action_done", @owner, "id" => second.id)
    end
  end

  # A walk ended by an error that is not a refusal, a 404 or a 422.
  class Failed < StandardError; end

  def to_s
    lines = log.map do |step|
      "  #{step.index}: #{step.action} #{step.command} by #{step.caller} -> #{step.answer}"
    end
    ([ "walk with seed #{seed} (SEED=#{seed} reruns it as the first walk):" ] + lines).join("\n")
  end

  private

  # Set up rare starting paths with the same commands the random walk
  # uses, then let the seed draw the remaining steps normally.
  def use_guided_rules(key)
    rules.each do |rule|
      enabled = rule.key == key
      next if rule.enabled == enabled

      guided(enabled ? "enable_rule" : "disable_rule", @owner, "id" => rule.id)
    end
  end

  def guided_contract(actions)
    guided("add_task", @owner, "title" => "Made-up coverage task", "state" => "backlog")
    task = tasks.last
    guided("complete_contract", @owner, contract(task).merge("actions" => actions, "budget_cap" => nil))
    task
  end

  def guided_pass_review
    reviewer = @reviewers.last
    guided("claim_review", reviewer)
    review = review_of(reviewer)
    guided("acknowledge_review_briefing", reviewer, "id" => review.id,
      "briefing_hash" => Leverage::Briefing.hash_for(review, reviewer))
    guided("pass_review", reviewer, "id" => review.id, "verdict" => "passed", "failed_criteria" => [],
      "notes" => "Made-up notes.", "tokens" => 10, "spend" => 0)
  end

  def guided_approve_job
    guided("claim_job", @orchestrator)
    job = job_of(@orchestrator)
    fields = { "decision" => "approve", "reason" => "A made-up reason." }
    guided("submit_job_result", @orchestrator, "id" => job.id, "result" => fields, "tokens" => 10, "spend" => 0)
  end

  def expire_guided_job
    make_job_due(log.last.index + 1, job_of(@orchestrator))
    sweep(log.last.index + 1)
  end

  def guided(name, caller, params = {})
    guided_step { |index| command(index, :guided, name, caller, params) }
  end

  def guided_step
    index = log.empty? ? 0 : log.last.index + 1
    raise "guided steps exceeded the walk length" if index >= @steps

    yield index
    raise "guided step did not complete" unless log.last.answer == "completed"
  end

  def pick
    total = @actions.values.sum
    point = @random.rand(total)
    @actions.each do |action, weight|
      return action if point < weight

      point -= weight
    end
  end

  def one(list) = list.empty? ? nil : list[@random.rand(list.size)]
  def chance(fraction) = @random.rand < fraction

  # --- reading the walk's state -------------------------------------------

  def tasks = Task.where(workspace_id: workspace_id).order(:created_at, :id).to_a
  def live_tasks = tasks.reject { |task| %w[done cancelled].include?(task.state) }

  def projects = Project.where(workspace_id: workspace_id, content_deleted_at: nil).order(:created_at, :id).to_a

  def held_by(seat) = Task.find_by(workspace_id: workspace_id, holder_seat_id: seat.id)

  def open_reviews = Review.where(workspace_id: workspace_id, verdict: nil).order(:created_at, :id).to_a

  def review_of(seat) = Review.find_by(workspace_id: workspace_id, reviewer_seat_id: seat.id, verdict: nil)

  def build_criteria(task)
    Criterion.where(task_id: task.id, kind: "build", removed_at: nil).order(:position).to_a
  end

  # The task a builder works on: the one it holds, or now and then any
  # other, so that refusals are walked too.
  def builder_and_task
    seat = one(@builders)
    task = held_by(seat)
    task = one(tasks) if task.nil? || chance(0.1)
    [ seat, task ]
  end

  def reviewer_and_review
    seat = one(@reviewers)
    review = review_of(seat)
    review = one(open_reviews) if review.nil? || chance(0.1)
    [ seat, review ]
  end

  # --- the owner -----------------------------------------------------------

  # A task in the Backlog, or now and then an idea in Ideas.
  def add_task(index)
    return sweep(index) if tasks.size >= MAXIMUM_TASKS

    command(index, :add_task, "add_task", @owner, "title" => "Made-up task #{index}",
      "priority" => one(%w[low normal high]), "work_reference" => nil, "state" => chance(0.2) ? "ideas" : "backlog",
      "project_id" => one([ nil, *projects ])&.id)
  end

  def complete_contract(index)
    task = one(tasks.select { |candidate| candidate.state == "backlog" }) || one(tasks)
    return progress(index) unless task

    command(index, :complete_contract, "complete_contract", @owner, contract(task))
  end

  # A contract of one or two build criteria and the review; the first
  # criterion's text changes now and then, so an edit resets it.
  def contract(task)
    builds = Array.new(1 + @random.rand(2)) do |number|
      { "text" => "Made-up criterion #{number + 1}#{" (changed)" if chance(0.3)}.", "kind" => "build" }
    end
    { "id" => task.id, "title" => task.title || "Made-up task",
      "details" => "Made-up details.", "criteria" => builds + [ { "text" => "A reviewer agrees.", "kind" => "review" } ],
      "actions" => action_definitions, "minimum_strength_rank" => nil, "budget_cap" => one(CAP_AMOUNTS),
      "work_reference" => nil }
  end

  def action_definitions
    Array.new(@random.rand(3)) do |number|
      { "kind" => one(%w[publish pay send delete]), "description" => "Made-up action #{number + 1}." }
    end
  end

  def cancel(index)
    task = one(live_tasks) || one(tasks)
    return progress(index) unless task

    command(index, :cancel, "cancel", @owner, "id" => task.id)
  end

  def allow_another_round(index)
    held = Hold.where(workspace_id: workspace_id, reason: "rounds_exceeded", closed_at: nil).pluck(:task_id)
    task = Task.find_by(id: one(held)) || one(tasks)
    return progress(index) unless task

    command(index, :allow_another_round, "allow_another_round", @owner, "id" => task.id)
  end

  # --- moving a seat forward ---------------------------------------------------

  # The call a seat's state calls for next: a builder claims, acknowledges,
  # starts and passes its criteria, and submits; a reviewer claims a
  # review, acknowledges it and gives a verdict.
  def progress(index)
    useful = []
    underway = []
    all = tasks
    useful << -> { complete_contract(index) } if all.any? { |task| task.state == "backlog" }
    useful << -> { add_task(index) } if live_tasks.size < LIVE_TASKS && all.size < MAXIMUM_TASKS
    ready = all.any? { |task| task.state == "ready" }
    @builders.each do |seat|
      held = held_by(seat)
      next unless ready || held

      move = -> { build(index, seat) }
      useful << move
      underway << move if held && !Leverage::Holds.held?(held) && %w[working finishing].include?(held.state)
    end
    unclaimed = open_reviews.any? { |review| review.reviewer_seat_id.nil? }
    @reviewers.each do |seat|
      held = review_of(seat)
      next unless unclaimed || held

      move = -> { review(index, seat) }
      useful << move
      underway << move
    end
    job_seats.each do |seat|
      move = -> { work_job(index, seat) }
      job = job_of(seat)
      queued = job ? [] : queued_jobs(seat.role)
      next unless job || queued.any?

      useful << move
      underway << move if (job ? [ job ] : queued).any? { |each| each.kind == "approval" }
    end
    useful << -> { answer_hold(index) } if rule_holds.any?
    needs_you = owner_offers
    useful << -> { take_owner_offer(index, needs_you) } if needs_you.any?
    # Give in-flight work a better chance of reaching a verdict and
    # Finishing before other commands interrupt it.
    choices = underway.any? && chance(0.60) ? underway : useful
    choices.empty? ? sweep(index) : one(choices).call
  end

  def build(index, seat)
    task = held_by(seat)
    return command(index, :progress, "claim", seat, {}) unless task
    return acknowledge_as(index, seat, task) unless Leverage::Briefing.acknowledgement(task, seat: seat) == :current

    return finish(index, seat, task) if task.state == "finishing"

    criterion = build_criteria(task).reject { |candidate| candidate.state == "passed" }.first
    return command(index, :progress, "submit", seat, "id" => task.id, "handoff_note" => "A made-up note.",
      "work_reference" => nil) unless criterion

    name = criterion.state == "started" || chance(0.5) ? "pass_criterion" : "start_criterion"
    params = { "id" => task.id, "cid" => criterion.id }
    params["evidence"] = { "kind" => "link", "value" => "https://example.test/work/#{index}" } if name == "pass_criterion"
    command(index, :progress, name, seat, params)
  end

  def finish(index, seat, task)
    action = Leverage::Actions.first_approved_open(task)
    return heartbeat(index) unless action
    return command(index, :finish, "release", seat, "id" => task.id, "reason" => "stopping") if chance(0.30)

    name = action.state == "started" ? "report_action_done" : "start_action"
    command(index, :finish, name, seat, "id" => task.id, "aid" => action.id)
  end

  def acknowledge_as(index, seat, task)
    command(index, :progress, "acknowledge_briefing", seat, "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat))
  end

  def review(index, seat)
    review = review_of(seat)
    return command(index, :progress, "claim_review", seat, {}) unless review

    task = Task.find(review.task_id)
    if Leverage::Briefing.acknowledgement(task, seat: seat, review: review) == :current
      verdict_on(index, seat, review)
    else
      command(index, :progress, "acknowledge_review_briefing", seat, "id" => review.id,
        "briefing_hash" => Leverage::Briefing.hash_for(review, seat))
    end
  end

  # --- builders ------------------------------------------------------------

  def claim(index)
    command(index, :claim, "claim", one(@builders), {})
  end

  def acknowledge(index)
    seat, task = builder_and_task
    return claim(index) unless task

    hash = chance(0.1) ? "made-up-hash-#{index}" : Leverage::Briefing.hash_for(task, seat)
    command(index, :acknowledge, "acknowledge_briefing", seat, "id" => task.id, "briefing_hash" => hash)
  end

  def start_criterion(index)
    seat, task = builder_and_task
    criterion = task && one(build_criteria(task))
    return claim(index) unless criterion

    command(index, :start_criterion, "start_criterion", seat, "id" => task.id, "cid" => criterion.id)
  end

  def pass_criterion(index)
    seat, task = builder_and_task
    return claim(index) unless task

    criteria = build_criteria(task)
    criterion = one(criteria.reject { |candidate| candidate.state == "passed" }) || one(criteria)
    return claim(index) unless criterion

    command(index, :pass_criterion, "pass_criterion", seat, "id" => task.id, "cid" => criterion.id,
      "evidence" => { "kind" => "link", "value" => "https://example.test/work/#{index}" })
  end

  def submit(index)
    seat, task = builder_and_task
    return claim(index) unless task

    command(index, :submit, "submit", seat, "id" => task.id, "handoff_note" => "A made-up note.",
      "work_reference" => nil)
  end

  def release(index)
    seat, task = builder_and_task
    return claim(index) unless task

    command(index, :release, "release", seat, "id" => task.id, "reason" => one(RELEASE_REASONS))
  end

  def heartbeat(index)
    seat, task = builder_and_task
    return claim(index) unless task

    command(index, :heartbeat, "heartbeat", seat, "id" => task.id)
  end

  # --- reviewers -----------------------------------------------------------

  def claim_review(index)
    command(index, :claim_review, "claim_review", one(@reviewers), {})
  end

  def acknowledge_review(index)
    seat, review = reviewer_and_review
    return claim_review(index) unless review

    hash = chance(0.1) ? "made-up-hash-#{index}" : Leverage::Briefing.hash_for(review, seat)
    command(index, :acknowledge_review, "acknowledge_review_briefing", seat, "id" => review.id, "briefing_hash" => hash)
  end

  def verdict(index)
    seat, review = reviewer_and_review
    return claim_review(index) unless review

    verdict_on(index, seat, review)
  end

  def verdict_on(index, seat, review)
    criteria = build_criteria(Task.find(review.task_id)).map(&:id)
    if chance(0.5) || criteria.empty?
      command(index, :verdict, "pass_review", seat, "id" => review.id, "verdict" => "passed", "failed_criteria" => [],
        "notes" => "Made-up notes.", "tokens" => 10, "spend" => 0.01)
    else
      failed = criteria.select { chance(0.5) }.presence || [ one(criteria) ]
      command(index, :verdict, "fail_review", seat, "id" => review.id, "verdict" => "failed",
        "failed_criteria" => failed, "notes" => "Made-up notes.", "tokens" => 10, "spend" => 0.01)
    end
  end

  def release_review(index)
    seat, review = reviewer_and_review
    return claim_review(index) unless review

    command(index, :release_review, "release_review", seat, "id" => review.id)
  end

  def heartbeat_review(index)
    seat, review = reviewer_and_review
    return claim_review(index) unless review

    command(index, :heartbeat_review, "heartbeat_review", seat, "id" => review.id)
  end

  # --- rules, checks and jobs (milestone 4) -------------------------------------

  # The shipped rules from the one-time write, some of them turned off, and
  # up to two custom rules at drawn moments, blocking or only noting.
  def draw_rules
    outcome = T.apply(T::Request.new(command: "install_shipped_rules", workspace_id: workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: {}))
    raise "install_shipped_rules was #{outcome.outcome}" unless outcome.completed?

    Rule.where(workspace_id: workspace_id).order(:created_at, :key).each do |rule|
      setup("disable_rule", @owner, "id" => rule.id) if chance(OFF.fetch(rule.key, 0.3))
    end
    @random.rand(3).times do |number|
      setup("add_rule", @owner, rule_body(one(MOMENTS), number))
      rule = Rule.where(workspace_id: workspace_id).where("key LIKE 'custom_%'").order(:created_at, :key).last
      setup("save_rule", @owner, save_body(rule, "on_fail" => "warn").merge("id" => rule.id)) if chance(0.4)
    end
  end

  def rule_body(hook, number)
    { "name" => "Made-up rule #{number + 1}", "instruction" => "Made-up instruction: the work says what it changed.",
      "hook" => hook, "scope" => { "kind" => "all_tasks", "project_ids" => nil, "action_kinds" => nil } }
  end

  # A SaveRuleRequest with every field as the current version has it, and
  # overrides.
  def save_body(rule, overrides = {})
    version = RuleVersion.find_by!(rule_id: rule.id, version: rule.reload.current_version)
    { "name" => version.name, "instruction" => version.instruction, "parameters" => version.parameters,
      "scope" => { "kind" => version.scope_kind, "project_ids" => nil, "action_kinds" => nil },
      "on_fail" => version.on_fail, "route" => version.route, "queue_timeout_seconds" => version.queue_timeout_seconds,
      "run_timeout_seconds" => version.run_timeout_seconds }.merge(overrides)
  end

  def job_seats = [ @orchestrator, @planner ]

  def job_of(seat) = Job.find_by(workspace_id: workspace_id, claimed_by_seat_id: seat.id, state: "claimed")

  def queued_jobs(role) = in_log_order(Job.where(workspace_id: workspace_id, state: "queued", seat_role: role).to_a)

  def rule_holds
    in_log_order(Hold.where(workspace_id: workspace_id, closed_at: nil,
      reason: %w[check_error rerun_limit claim_gate_failed contract_incomplete]).to_a)
  end

  # Rows in the order of the log, so a walk is the same walk for its seed:
  # rows made in one command share their created_at, and their ids are
  # random. A row's order is the seq of the first event about it (a
  # requeued job's is its check.queued), then its created_at.
  def in_log_order(rows)
    ids = rows.map(&:id)
    seqs = Event.where(workspace_id: workspace_id, subject_id: ids).group(:subject_id).minimum(:seq)
    Event.where(workspace_id: workspace_id, type: "check.queued").where("payload->>'job_id' IN (?)", ids.presence || [ "" ])
      .pluck(Arel.sql("payload->>'job_id'"), :seq).each { |id, seq| seqs[id] = [ seqs[id], seq ].compact.min }
    rows.sort_by { |row| [ seqs.fetch(row.id, Float::INFINITY), row.created_at ] }
  end

  def rules = Rule.where(workspace_id: workspace_id, removed_at: nil).order(:created_at, :key).to_a

  # A job seat claims a job, or answers the one it holds.
  def work_job(index, seat)
    job_of(seat) ? answer_job(index, seat) : command(index, :progress, "claim_job", seat, {})
  end

  def claim_job(index)
    command(index, :claim_job, "claim_job", one(job_seats), {})
  end

  def job_result(index)
    seat = one(job_seats)
    job_of(seat) ? answer_job(index, seat) : claim_job(index)
  end

  # A drawn verdict for a check (none now and then: the job will time
  # out), or a contract for a draft.
  def answer_job(index, seat)
    job = job_of(seat)
    result = drawn_job_result(job)
    unless result
      @log << Step.new(index, :job_result, "none", seat.role, { "job" => job.id }, "no answer")
      return
    end

    command(index, :job_result, "submit_job_result", seat, "id" => job.id, "result" => result, "tokens" => 10,
      "spend" => one(SPEND_AMOUNTS))
  end

  def drawn_job_result(job)
    case job.kind
    when "contract_draft"
      contract(Task.find(job.task_id)).except("id", "work_reference", "minimum_strength_rank", "budget_cap")
    when "question"
      basis = one(QUESTION_BASES)
      return unless basis
      return { "outcome" => "passed_on", "answer" => nil, "basis" => nil } if basis == "passed_on"

      { "outcome" => "answered", "answer" => "A made-up answer.", "basis" => basis }
    when "approval"
      decision = one(APPROVALS)
      { "decision" => decision, "reason" => "A made-up reason." } if decision
    when "rule_check"
      verdict = one(VERDICTS)
      { "result" => verdict, "reason" => "A made-up reason." } if verdict
    else
      raise ArgumentError, "unexpected job kind #{job.kind}"
    end
  end

  # A queued or claimed job reaches its queue or run due time (EN-18): its
  # attempt's and its own times move back by what is left.
  def expire_job(index)
    job = one(in_log_order(Job.where(workspace_id: workspace_id, state: %w[queued claimed]).to_a))
    return progress(index) unless job

    make_job_due(index, job)
  end

  def make_job_due(index, job)
    kind = job.state == "queued" ? :queue : :run
    due = Leverage::Timers.job_due_at(job, kind)
    return progress(index) unless due

    shift = scenario.database_now - due
    attempt = RuleCheckAttempt.find_by(job_id: job.id)
    if kind == :queue
      job.update_columns(queued_at: job.queued_at + shift)
      attempt&.update_columns(queued_at: attempt.queued_at + shift)
    else
      job.update_columns(claimed_at: job.claimed_at + shift)
      attempt&.update_columns(started_at: attempt.started_at + shift) if attempt&.started_at
    end
    @log << Step.new(index, :expire_job, "make_due", "test", { "job" => job.id, "kind" => kind }, "due now")
  end

  # The owner answers a rule's hold: lets the check through once, or runs
  # it again.
  def answer_hold(index)
    hold = one(rule_holds)
    check = hold.rule_check_id && RuleCheck.find_by(id: hold.rule_check_id)
    check ||= checks_of(%w[failed error]).reverse.find { |row| row.task_id == hold.task_id && row.rule_id == hold.rule_id }
    return override_check(index) unless check

    name = hold.reason == "check_error" && chance(0.5) ? "rerun_check" : "override_check"
    params = { "id" => check.id }
    params["reason"] = "A made-up reason." if name == "override_check"
    command(index, :progress, name, @owner, params)
  end

  def checks_of(results) = in_log_order(RuleCheck.where(workspace_id: workspace_id, result: results).to_a)

  def all_checks = in_log_order(RuleCheck.where(workspace_id: workspace_id).to_a)

  def override_check(index)
    check = one(checks_of(%w[failed error])) || one(all_checks)
    return progress(index) unless check

    command(index, :override_check, "override_check", @owner, "id" => check.id, "reason" => "A made-up reason.")
  end

  def rerun_check(index)
    check = one(checks_of(%w[error])) || one(all_checks)
    return progress(index) unless check

    command(index, :rerun_check, "rerun_check", @owner, "id" => check.id)
  end

  def draft_contract(index)
    task = one(tasks.select { |candidate| candidate.state == "backlog" }) || one(tasks)
    return add_task(index) unless task

    command(index, :draft_contract, "draft_contract", @owner, "id" => task.id)
  end

  def add_rule(index)
    command(index, :add_rule, "add_rule", @owner, rule_body(one(MOMENTS), index))
  end

  # A new version: a model rule's instruction reworded, an app rule's
  # parameter changed, or a custom gate between blocking and noting.
  def save_rule(index)
    rule = one(rules)
    return add_rule(index) unless rule

    version = RuleVersion.find_by!(rule_id: rule.id, version: rule.current_version)
    changes = if version.checker == "model" && version.instruction
      { "instruction" => "#{version.instruction} Reworded #{index}." }
    elsif version.parameters.present?
      { "parameters" => version.parameters.transform_values { 1 + @random.rand(2) } }
    else
      {}
    end
    changes["on_fail"] = version.on_fail == "block" ? "warn" : "block" if rule.key.start_with?("custom_") && chance(0.3)
    command(index, :save_rule, "save_rule", @owner, save_body(rule, changes).merge("id" => rule.id))
  end

  def switch_rule(index)
    rule = one(rules)
    return add_rule(index) unless rule

    command(index, :switch_rule, rule.reload.enabled ? "disable_rule" : "enable_rule", @owner, "id" => rule.id)
  end

  def revert_rule(index)
    rule = one(rules.reject { |candidate| candidate.key.start_with?("custom_") })
    return save_rule(index) unless rule

    command(index, :revert_rule, "revert_rule", @owner, "id" => rule.id)
  end

  def remove_rule(index)
    rule = one(rules.select { |candidate| candidate.key.start_with?("custom_") })
    return add_rule(index) unless rule

    command(index, :remove_rule, "remove_rule", @owner, "id" => rule.id)
  end

  # The run of a job seat on a login meets a limit or is found signed
  # out while it holds its job.
  def report_job_limit(index)
    reset = chance(0.25) ? nil : (scenario.database_now + (1 + @random.rand(3)) * 600).utc.iso8601(6)
    job_report(index, :report_job_limit, "report_job_limit", "window" => one(%w[five_hour weekly]), "reset_at" => reset)
  end

  def report_job_signed_out(index)
    job_report(index, :report_job_signed_out, "report_job_signed_out", {})
  end

  def job_report(index, action, name, fields)
    seat = one(job_seats.select { |candidate| candidate.reload.credential_id && job_of(candidate) })
    return progress(index) unless seat

    job = job_of(seat)
    credential_id = job.credential_id || seat.credential_id
    params = { "id" => credential_id, "credential_id" => credential_id, "seat_id" => seat.id, "task_id" => nil,
               "review_id" => nil, "job_id" => job.id, "observed_at" => (scenario.database_now - 1).utc.iso8601(6),
               "tool_version" => "0.0.0-walk" }
    command(index, action, name, @helper, params.merge(fields))
  end

  # One of the ends rule 11's table gives a waiting command, drawn for the
  # command that waits (milestone 4 plan §2.1, rule 11; WP12's walk step
  # for each row): the owner cancels the task, edits its contract, holds
  # it, pauses or turns off its seat, or the spare seat is removed; the
  # builder releases, or its lease ends; the reviewer releases, its lease
  # ends, its run stops, its account meets a limit or a sign-out, or a new
  # helper token is issued.
  def end_waiting(index)
    waiting = PendingTransition.where(workspace_id: workspace_id, state: "pending").order(:created_at, :id).to_a
    seats_waiting = waiting.select { |candidate| candidate.requester_kind == "seat" }
    pending = one(seats_waiting.any? && chance(0.8) ? seats_waiting : waiting)
    return progress(index) unless pending

    task = Task.find(pending.task_id)
    seat = pending.requester_kind == "seat" ? Seat.find(pending.requester_id) : nil
    review = Review.find_by(workspace_id: workspace_id, task_id: task.id, verdict: nil, reviewer_seat_id: seat&.id) if seat
    owner = [ -> { command(index, :end_waiting, "cancel", @owner, "id" => task.id) },
              -> { command(index, :end_waiting, "edit_contract", @owner, contract(task)) } ]
    held = if seat && review
      reviewer_ends(index, seat, review)
    elsif seat
      builder_ends(index, seat, task)
    else
      []
    end
    one(held.empty? || chance(0.2) ? owner : held).call
  end

  def builder_ends(index, seat, task)
    ends = [ -> { command(index, :end_waiting, "release", seat, "id" => task.id, "reason" => one(RELEASE_REASONS)) },
             -> { command(index, :end_waiting, "change_seat", @owner, "id" => seat.id, "enabled" => false) },
             -> { command(index, :end_waiting, "hold", @owner, "id" => task.id) },
             -> { command(index, :end_waiting, "pause_seat", @owner, "id" => seat.id) } ]
    ends << -> { command(index, :end_waiting, "remove_seat", @owner, "id" => seat.id) } if seat.id == @spare.id
    if task.lease_due_at
      ends << lambda do
        scenario.make_due(task, at: scenario.database_now)
        timer(index, "builder_lease_expiry")
      end
    end
    ends
  end

  def reviewer_ends(index, seat, review)
    ends = [ -> { command(index, :end_waiting, "release_review", seat, "id" => review.id) },
             -> { new_helper_token(index) } ]
    if review.lease_due_at
      ends << lambda do
        scenario.make_due(review, at: scenario.database_now)
        timer(index, "review_lease_expiry")
      end
    end
    if seat.credential_id
      ends << lambda do
        command(index, :end_waiting, "report_run_stopped", @helper, "id" => seat.id, "credential_id" => seat.credential_id,
          "observed_at" => (scenario.database_now - 1).utc.iso8601(6), "stop_reason" => "stopped")
      end
      credential_id = review.credential_id || seat.credential_id
      %w[report_limit report_signed_out].each do |name|
        ends << lambda do
          params = { "id" => credential_id, "credential_id" => credential_id, "seat_id" => seat.id, "task_id" => nil,
                     "review_id" => review.id, "job_id" => nil, "observed_at" => (scenario.database_now - 1).utc.iso8601(6),
                     "tool_version" => "0.0.0-walk" }
          params.merge!("window" => "five_hour", "reset_at" => nil) if name == "report_limit"
          command(index, :end_waiting, name, @helper, params)
        end
      end
    end
    ends
  end

  # One timer, as the sweep runs it.
  def timer(index, name, action: :end_waiting)
    request = T::Request.new(command: name, workspace_id: workspace_id, caller_kind: nil, caller_id: nil, key: nil,
      request_hash: nil, params: {})
    @log << Step.new(index, action, name, "app", {}, answer(request))
  end

  # The orchestrator polls GET /v1/next (RD-15), or has not for over 90
  # seconds (its last poll is put back, as make_due puts a lease).
  def poll(index)
    seat = one(job_seats)
    seat.update_columns(last_polled_at: scenario.database_now)
    @log << Step.new(index, :poll, "poll", seat.role, {}, "polled now")
  end

  def stop_polling(index)
    seat = one(job_seats)
    seat.update_columns(last_polled_at: scenario.database_now - 100)
    @log << Step.new(index, :stop_polling, "poll", seat.role, {}, "last polled 100 s ago")
  end

  # The helper reports a seat's run stopped (a held review is released,
  # rule 11), and the owner starts a seat again.
  def report_run_stopped(index)
    seat = one(seats.select(&:credential_id))
    command(index, :report_run_stopped, "report_run_stopped", @helper, "id" => seat.id,
      "credential_id" => seat.credential_id, "observed_at" => (scenario.database_now - 1).utc.iso8601(6),
      "stop_reason" => "stopped")
  end

  def start_seat(index)
    seat = one(seats.select(&:credential_id))
    command(index, :start_seat, "start_seat", @owner, "id" => seat.id)
  end

  # A new helper token: every running seat's run counts as stopped
  # (SeatRuns.reconcile), and the new helper reports from then on.
  def new_helper_token(index)
    answer = setup_answer(index, :new_helper_token, "issue_helper_token", @owner, "name" => "Made-up Mac #{index}")
    @helper = Helper.find(answer.fetch("helper_id")) if answer
  end

  # The spare builder is removed, once: a waiting command it held ends
  # (rule 11).
  def remove_seat(index)
    return pause_seat(index) if @spare.reload.removed_at

    command(index, :remove_seat, "remove_seat", @owner, "id" => @spare.id)
  end

  # --- the owner's controls (milestone 3) -------------------------------------

  def promote(index)
    task = one(tasks.select { |candidate| candidate.state == "ideas" }) || one(tasks)
    return add_task(index) unless task

    command(index, :promote, "promote", @owner, "id" => task.id)
  end

  def edit_contract(index)
    task = one(live_tasks) || one(tasks)
    return progress(index) unless task

    command(index, :edit_contract, "edit_contract", @owner, contract(task))
  end

  def hold(index)
    task = one(live_tasks) || one(tasks)
    return progress(index) unless task

    command(index, :hold, "hold", @owner, "id" => task.id)
  end

  def resume(index)
    held = Hold.where(workspace_id: workspace_id, reason: "owner_hold", closed_at: nil).pluck(:task_id)
    task = Task.find_by(id: one(held)) || one(tasks)
    return progress(index) unless task

    command(index, :resume, "resume", @owner, "id" => task.id)
  end

  def seats = @builders + @reviewers + job_seats

  def pause_seat(index)
    command(index, :pause_seat, "pause_seat", @owner, "id" => one(seats).id)
  end

  def resume_seat(index)
    seat = one(Seat.where(workspace_id: workspace_id, paused: true).to_a) || one(seats)
    command(index, :resume_seat, "resume_seat", @owner, "id" => seat.id)
  end

  # Turns an agent back on, or now and then off; moves an agent the app
  # runs to another login; or changes its model.
  def change_seat(index)
    seat = one(seats).reload
    params = { "id" => seat.id }
    if !seat.enabled
      params["enabled"] = true
    elsif chance(0.2)
      params["enabled"] = false
    elsif seat.credential_id && chance(0.6)
      params["credential_id"] = one(@logins).id
    else
      params["model"] = one([ "made-up-model", "another-made-up-model", nil ])
    end
    command(index, :change_seat, "change_seat", @owner, params)
  end

  # --- questions, approvals, projects and settings (milestone 5) ------------

  def holder_command(index)
    holders = @builders.filter_map do |seat|
      task = held_by(seat)
      [ seat, task ] if task && %w[working finishing].include?(task.state)
    end
    seat, task = one(holders)
    return progress(index) unless task

    name, fields = one([
      [ "ask_question", { "text" => "A made-up question.", "assumption" => "A made-up assumption.", "blocking" => chance(0.5) } ],
      [ "request_access", { "description" => "Made-up access." } ],
      [ "report_cost", { "tokens" => 1 + @random.rand(50), "spend" => one(SPEND_AMOUNTS) } ]
    ])
    command(index, :holder_command, name, seat, fields.merge("id" => task.id))
  end

  # The same choices the app reads, including the guard on Offer again.
  def owner_offers
    items = Leverage::Reads::Inbox.call(workspace_id).fetch(:items)
    items.select { |item| %w[question_passed_on approval stopped_action unconfirmed_action
                             access_request task_budget_reached project_budget_reached].include?(item.fetch(:kind)) }
      .flat_map { |item| item.fetch(:choices).map { |choice| [ item, choice ] } }
  end

  def answer_needs_you(index)
    offers = owner_offers
    offers.empty? ? progress(index) : take_owner_offer(index, offers)
  end

  def take_owner_offer(index, offers)
    recoveries = offers.select { |_item, choice| %w[offer_again mark_done].include?(choice) }
    item, choice = one(recoveries.any? && chance(0.75) ? recoveries : offers)
    name, params = owner_request(item, choice)
    command(index, :answer_needs_you, name, @owner, params)
  end

  def owner_request(item, choice)
    about_id = item.fetch(:about_id)
    facts = item.fetch(:facts)
    action_id = facts["action_id"] || Array(facts["action_ids"]).first
    case choice
    when "answer" then [ "answer_question", { "id" => facts.fetch("question_id"), "answer" => "A made-up owner answer." } ]
    when "approve", "stop", "waive" then [ "#{choice}_action", { "id" => action_id } ]
    when "mark_done" then [ "mark_action_done", { "id" => action_id } ]
    when "offer_again" then [ "offer_task_again", { "id" => about_id } ]
    when "return_for_rework"
      criteria = build_criteria(Task.find(about_id))
      [ choice, { "id" => about_id, "criterion_ids" => criteria.select { chance(0.5) }.map(&:id) } ]
    when "override_once" then [ "override_check", { "id" => facts.fetch("rule_check_id"), "reason" => "A made-up reason." } ]
    when "mark_access_granted" then [ "grant_access", { "id" => about_id } ]
    when "raise_cap" then [ "change_task_cap", { "id" => about_id, "budget_cap" => nil } ]
    when "change_budget" then [ choice, { "id" => about_id, "budget" => nil } ]
    when "resume_project", "cancel" then [ choice, { "id" => about_id } ]
    else raise ArgumentError, "unexpected Needs you choice #{choice}"
    end
  end

  def review_decision(index)
    questions = in_log_order(Question.where(workspace_id: workspace_id, outcome: "answered", answered_by_kind: "seat").to_a)
    actions = tasks.flat_map do |task|
      Leverage::Actions.for_task(task).where(state: %w[approved started done], approved_by_kind: "seat").to_a
    end
    decision = one(actions.any? && chance(0.7) ? actions : questions + actions)
    return progress(index) unless decision

    name = decision.is_a?(Question) ? "overturn_answer" : "overturn_approval"
    command(index, :review_decision, name, @owner, "id" => decision.id)
  end

  def project_command(index)
    all = projects
    room = Project.where(workspace_id: workspace_id).count < MAXIMUM_PROJECTS
    if room && (all.empty? || chance(0.4))
      return command(index, :project_command, "create_project", @owner, "name" => "Made-up project #{index}",
        "goal" => "A made-up project goal.", "budget" => one(CAP_AMOUNTS))
    end

    project = one(all)
    return progress(index) unless project

    name, fields = one([
      [ project.paused? ? "resume_project" : "pause_project", {} ],
      [ "change_budget", { "budget" => one(CAP_AMOUNTS) } ],
      [ "edit_brief", { "entries" => [ { "kind" => one(%w[rule decision lesson]), "text" => "Made-up brief #{index}." } ] } ]
    ])
    command(index, :project_command, name, @owner, fields.merge("id" => project.id))
  end

  def task_settings(index)
    task = one(live_tasks) || one(tasks)
    return progress(index) unless task

    name, fields = one([
      [ "change_task_priority", { "priority" => one(%w[low normal high]) } ],
      [ "change_task_project", { "project_id" => one([ nil, *projects ])&.id } ],
      [ "change_task_cap", { "budget_cap" => one(CAP_AMOUNTS) } ]
    ])
    command(index, :task_settings, name, @owner, fields.merge("id" => task.id))
  end

  def workspace_settings(index)
    fields = one([
      { "lease_length_seconds" => one([ 300, 900 ]) },
      { "check_queue_timeout_seconds" => one([ 30, 600 ]) },
      { "check_run_timeout_seconds" => one([ 60, 600 ]) },
      { "recovery_time_ceiling_seconds" => one([ nil, 180 ]) }
    ])
    command(index, :workspace_settings, "change_workspace_settings", @owner, fields)
  end

  def delete_content(index)
    ended = tasks.select { |task| %w[done cancelled].include?(task.state) && task.content_deleted_at.nil? }
    target = one(ended + projects)
    return progress(index) unless target

    key = target.is_a?(Task) ? "task_id" : "project_id"
    command(index, :delete_content, "delete_content", @owner, key => target.id)
  end

  # --- the helper (milestone 3) -------------------------------------------------

  # The run on a login meets a limit (with a reset time, or now and then
  # none) or is found signed out, while it holds work: its task's or its
  # review's credential. Now and then any seat and task, for the refusals.
  def report_limit(index)
    reset = chance(0.25) ? nil : (scenario.database_now + (1 + @random.rand(3)) * 600).utc.iso8601(6)
    report(index, :report_limit, "report_limit", "window" => one(%w[five_hour weekly]), "reset_at" => reset)
  end

  def report_signed_out(index)
    report(index, :report_signed_out, "report_signed_out", {})
  end

  def report(index, action, name, fields)
    seat, task, review = running_work
    return progress(index) unless seat

    credential_id = (review || task).credential_id || seat.credential_id
    params = { "id" => credential_id, "credential_id" => credential_id, "seat_id" => seat.id,
               "task_id" => review ? nil : task.id, "review_id" => review&.id, "job_id" => nil,
               "observed_at" => (scenario.database_now - 1).utc.iso8601(6), "tool_version" => "0.0.0-walk" }
    command(index, action, name, @helper, params.merge(fields))
  end

  # A seat on a login and the work it holds: a task (Working) or an open
  # review; now and then any task, for the refusals.
  def running_work
    on_logins = seats.select(&:credential_id)
    busy = on_logins.select { |candidate| held_by(candidate) || review_of(candidate) }
    seat = one(busy.empty? || chance(0.1) ? on_logins : busy)
    task = held_by(seat)
    review = review_of(seat)
    return [ seat, task, nil ] if task && !chance(0.1)
    return [ seat, Task.find(review.task_id), review ] if review && !chance(0.1)

    task = one(tasks)
    task ? [ seat, task, nil ] : []
  end

  # A reset time passes: a login limited until a later time is put at the
  # database's now, as make_due puts a lease (EN-18).
  def pass_reset(index)
    credential = one(Credential.where(workspace_id: workspace_id).where("limited_until > clock_timestamp()").to_a)
    return sweep(index) unless credential

    credential.update_columns(limited_until: scenario.database_now)
    @log << Step.new(index, :pass_reset, "make_due", "test", { "credential" => credential.id }, "reset now")
  end

  def verify(index)
    command(index, :verify, "verify_credential", @owner, "id" => one(@logins).id)
  end

  def sign_in_again(index)
    credential = one(Credential.where(workspace_id: workspace_id, state: "signed_out").to_a) || one(@logins)
    command(index, :sign_in_again, "sign_in_again", @owner, "id" => credential.id)
  end

  def credentials = Credential.added.where(workspace_id: workspace_id).order(:position).to_a

  def rename_credential(index)
    credential = one(credentials)
    check_credential_steps(index, "rename_credential") do
      command(index, :rename_credential, "rename_credential", @owner, "id" => credential.id, "name" => "Made-up name #{index}")
    end
  end

  def remove_credential(index)
    all = credentials
    available = all.reject { |credential| Leverage::CredentialUse.in_use?(credential) }
    credential = one(available) || one(all)
    check_credential_steps(index, "remove_credential") do
      command(index, :remove_credential, "remove_credential", @owner, "id" => credential.id)
    end
  end

  def reorder_credentials(index)
    order = credentials.map(&:id).shuffle(random: @random)
    check_credential_steps(index, "reorder_credentials") do
      command(index, :reorder_credentials, "reorder_credentials", @owner, "order" => order)
    end
  end

  def refresh_usage(index)
    check_credential_steps(index, "refresh_usage") { command(index, :refresh_usage, "refresh_usage", @owner, {}) }
  end

  def report_reading(index)
    accounts = credentials
    limited = accounts.select(&:limited_since)
    credential = one(limited.empty? || chance(0.4) ? accounts : limited)
    state = one(%w[ok ok ok unavailable signed_out])
    params = { "id" => credential.id, "credential_id" => credential.id, "observed_at" => scenario.database_now.utc.iso8601(6),
      "state" => state, "figures" => state == "ok" ? reading_figures(credential) : [], "resets" => nil, "tool_version" => nil }
    check_credential_steps(index, "report_reading") { command(index, :report_reading, "report_reading", @helper, params) }
  end

  def reading_figures(credential)
    if credential.kind == "api_token"
      [ { "label" => "Made-up usage", "kind" => "activity", "window" => "spend", "percent_used" => nil,
          "reset_at" => nil, "value" => one([ 0, 12.5, 40 ]) } ]
    else
      %w[five_hour weekly].filter_map do |window|
        next if chance(0.25)

        { "label" => "Made-up usage", "kind" => "limit", "window" => window,
          "percent_used" => one([ 0, 40, 99.5, 100 ]), "reset_at" => nil, "value" => nil }
      end
    end
  end

  def usage_read_due(index)
    T::RecordPoll.helper(@helper)
    queued = HelperRequest.where(workspace_id: workspace_id, kind: "read_usage", state: "queued")
    before = queued.count
    check_credential_steps(index, "usage_read_due") { timer(index, "usage_read_due", action: :usage_read_due) }
    added = queued.count - before
    @log[-1] = @log.last.with(answer: "#{@log.last.answer}, queued #{added}") if added.positive?
  end

  # A credential command that affects no task opens and closes no step.
  # Readings, reorders and removals can change real holds, whose steps the
  # partition and log audit check.
  def check_credential_steps(index, name)
    steps = TaskStep.where(workspace_id: workspace_id).order(:id)
    columns = %i[id opening_event_id opened_at closing_event_id closed_at]
    before = steps.pluck(*columns)
    before_seq = scenario.workspace.reload.last_seq
    yield
    written = Event.where(workspace_id: workspace_id).where("seq > ?", before_seq)
    if !written.where.not(task_id: nil).exists? && steps.pluck(*columns) != before
      @credential_step_problems << "#{index}: #{name} changed steps without a task event"
    end
    if %w[refresh_usage usage_read_due].include?(name) && written.exists?
      @credential_step_problems << "#{index}: #{name} wrote events"
    end
  end

  # The helper picks up and answers its oldest unfinished request: a start
  # issues the seat's token first; Verify and Sign in again pass, or find
  # the login signed out; anything else finishes.
  def answer_request(index)
    requests = HelperRequest.where(workspace_id: workspace_id, state: %w[queued picked_up])
    requests = requests.where.not(kind: "read_usage") unless @credentials
    request = requests.order(:created_at, :id).first
    return sweep(index) unless request

    if request.kind == "start_seat"
      command(index, :answer_request, "issue_seat_token", @helper, "id" => request.id)
    end
    result = %w[verify open_sign_in].include?(request.kind) && chance(0.3) ? SIGNED_OUT : PASSED
    if request.kind == "read_usage"
      # Leave this read due so a later sweep can start a fresh request.
      result = result.merge("outcome" => "failed", "tool_version" => nil,
        "checks" => [ { "check" => "reading_taken", "passed" => false, "failure" => "timed_out" } ])
    elsif !%w[verify open_sign_in run_add_checks].include?(request.kind)
      result = result.merge("checks" => [])
    end
    command(index, :answer_request, "report_request_result", @helper, "id" => request.id, "result" => result)
  end

  # --- timers ----------------------------------------------------------------

  # A running builder lease reaches its due time: the next command on the
  # task, or the sweep, ends it.
  def expire_builder(index)
    task = one(Task.where(workspace_id: workspace_id).where.not(lease_due_at: nil).to_a)
    return progress(index) unless task

    scenario.make_due(task, at: scenario.database_now)
    @log << Step.new(index, :expire_builder, "make_due", "test", { "task" => task.id }, "due now")
  end

  def expire_review(index)
    review = one(Review.where(workspace_id: workspace_id, verdict: nil).where.not(lease_due_at: nil).to_a)
    return progress(index) unless review

    scenario.make_due(review, at: scenario.database_now)
    @log << Step.new(index, :expire_review, "make_due", "test", { "review" => review.id }, "due now")
  end

  # A command whose result the walk keeps: its log line, and its result
  # when it completed.
  def setup_answer(index, action, name, caller, params)
    built = request(name, caller, params)
    outcome = T.apply(built)
    @log << Step.new(index, action, name, caller_label(caller), params, outcome.outcome.to_s)
    outcome.completed? ? outcome.result : nil
  end

  # The sweep's pass: the timers as commands of the app.
  # Each timer's answer says how many events it wrote, so a test can see
  # that a timer acted, not only that it ran.
  def sweep(index)
    TIMERS.each do |timer|
      request = T::Request.new(command: timer, workspace_id: workspace_id, caller_kind: nil, caller_id: nil, key: nil,
        request_hash: nil, params: {})
      before = scenario.workspace.reload.last_seq
      said = answer(request)
      wrote = scenario.workspace.reload.last_seq - before
      @log << Step.new(index, :sweep, timer, "app", {}, wrote.positive? ? "#{said}, wrote #{wrote}" : said)
    end
    usage_read_due(index) if @credentials
  end

  # The last request, sent again with its key: a repeat writes nothing.
  def repeat(index)
    return claim(index) unless @last

    @log << Step.new(index, :repeat, @last.command, @last.caller_kind, @last.params, answer(@last))
  end

  # --- applying ---------------------------------------------------------------

  # A seat on a login (run by the app), or one that connects on its own.
  def connect(role, index, login = nil, provider: "claude")
    params = { "name" => "Made-up #{role} #{index}", "role" => role, "provider" => login&.provider || provider,
               "model" => "made-up-model", "effort" => nil }
    params["credential_id"] = login.id if login
    Seat.find(setup("connect_seat", @owner, params).fetch("seat_id"))
  end

  def make_helper
    Helper.find(setup("issue_helper_token", @owner, "name" => "Made-up Mac").fetch("helper_id"))
  end

  # A login the helper adds: add_credential, then its passed checks.
  def add_login(provider, index)
    id = SecureRandom.uuid
    added = setup("add_credential", @owner, "credential_id" => id, "kind" => "login", "provider" => provider,
      "name" => "Made-up #{provider} #{index}", "masked_label" => nil, "model" => nil, "effort" => nil, "strength_rank" => nil)
    setup("report_request_result", @helper, "id" => added.fetch("helper_request_id"), "result" => PASSED)
    Credential.find(id)
  end

  def add_token
    added = setup("add_credential", @owner, "credential_id" => SecureRandom.uuid, "kind" => "api_token",
      "provider" => "openai_api", "name" => "Made-up API token", "masked_label" => "••••••••", "model" => nil,
      "effort" => nil, "strength_rank" => nil)
    result = PASSED.merge("tool_version" => nil,
      "checks" => [ { "check" => "token_works", "passed" => true, "failure" => nil } ])
    setup("report_request_result", @helper, "id" => added.fetch("helper_request_id"), "result" => result)
  end

  def check_first_reads
    expected = credentials.map do |credential|
      [ credential.id, { "provider" => credential.provider, "credential_kind" => credential.kind } ]
    end.to_h
    requests = HelperRequest.where(workspace_id: workspace_id, kind: "read_usage")
    unless requests.count == expected.size && requests.where(state: "queued").pluck(:credential_id, :params).to_h == expected
      raise "Add did not queue one first usage read per credential"
    end
  end

  def setup(name, caller, params)
    outcome = T.apply(request(name, caller, params))
    raise "#{name} was #{outcome.outcome}" unless outcome.completed?

    outcome.result
  end

  def command(index, action, name, caller, params)
    request = request(name, caller, params)
    @last = request
    @log << Step.new(index, action, name, caller_label(caller), params, answer(request))
  end

  def request(name, caller, params)
    @count += 1
    kind = { User => "owner", Helper => "helper" }.fetch(caller.class, "seat")
    T::Request.new(command: name, workspace_id: workspace_id, caller_kind: kind, caller_id: caller.id,
      key: "walk-#{seed}-#{@count}", request_hash: Digest::SHA256.hexdigest(JSON.generate(params)), params: params)
  end

  # What a request came to, in words: completed, refused <code>, or
  # rejected (404 or 422), which writes nothing.
  def answer(request)
    outcome = T.apply(request)
    outcome.refused? ? "refused #{outcome.refusal.code}" : outcome.outcome.to_s
  rescue T::NotFound, T::Invalid => error
    "rejected #{error.class.name.demodulize}"
  end

  def caller_label(caller)
    case caller
    when User then "owner"
    when Helper then "helper"
    else "#{caller.role} #{caller.name}"
    end
  end
end
