require "digest"
require "json"

# A seeded random walk over the commands and timers of milestones 2 and 3
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
    progress: 40, add_task: 4, complete_contract: 4, cancel: 1, allow_another_round: 2,
    claim: 5, acknowledge: 6, start_criterion: 4, pass_criterion: 6, submit: 5, release: 1, heartbeat: 2,
    claim_review: 5, acknowledge_review: 5, verdict: 6, release_review: 1, heartbeat_review: 1,
    expire_builder: 2, expire_review: 2, sweep: 3, repeat: 2,
    report_limit: 6, report_signed_out: 3, pass_reset: 3, verify: 2, sign_in_again: 2, answer_request: 5,
    promote: 2, edit_contract: 3, hold: 2, resume: 2, pause_seat: 2, resume_seat: 2, change_seat: 2
  }.freeze
  RELEASE_REASONS = %w[unable_to_continue not_suited_to_this_seat stopping].freeze
  MAXIMUM_TASKS = 8
  LIVE_TASKS = 3
  # The logins the helper adds, in order (their positions): the builders on
  # logins run on the first two, the reviewer on a login on the third. So
  # the first builder has three candidates, the second two and the
  # reviewer one: reports reach a handoff, a hold and a released review.
  LOGINS = %w[claude codex grok].freeze
  TIMERS = %w[builder_lease_expiry review_lease_expiry credential_hold_release seat_run_placement].freeze
  PASSED = { "outcome" => "finished", "checks" => [ { "check" => "signed_in", "passed" => true, "failure" => nil },
                                                    { "check" => "test_prompt", "passed" => true, "failure" => nil } ],
             "tool_version" => "0.0.0-walk", "plan" => nil, "account_email" => nil }.freeze
  SIGNED_OUT = { "outcome" => "failed", "checks" => [ { "check" => "signed_in", "passed" => false, "failure" => "not_signed_in" } ],
                 "tool_version" => "0.0.0-walk", "plan" => nil, "account_email" => nil }.freeze

  Step = Data.define(:index, :action, :command, :caller, :params, :answer)

  attr_reader :seed, :scenario, :log

  def initialize(seed:, steps: 60)
    @seed = seed
    @random = Random.new(seed)
    @steps = steps
    @log = []
    @last = nil
    @count = 0
  end

  def workspace_id = scenario.workspace_id

  def run
    @scenario = Scenario.new(lease_length_seconds: 600, maximum_rounds: 1 + @random.rand(2))
    @owner = scenario.owner
    @helper = make_helper
    @logins = LOGINS.each_with_index.map { |provider, index| add_login(provider, index) }
    @builders = [ connect("builder", 0, @logins[0]), connect("builder", 1, @logins[1]), connect("builder", 2) ]
    @reviewers = [ connect("reviewer", 0, @logins[2]), connect("reviewer", 1) ]
    @steps.times { |index| send(pick, index) }
    self
  rescue StandardError => error
    raise Failed, "#{error.class}: #{error.message}\n#{self}", error.backtrace
  end

  # A walk ended by an error that is not a refusal, a 404 or a 422.
  class Failed < StandardError; end

  def to_s
    lines = log.map do |step|
      "  #{step.index}: #{step.action} #{step.command} by #{step.caller} #{step.params.to_json} -> #{step.answer}"
    end
    ([ "walk with seed #{seed} (SEED=#{seed} reruns it as the first walk):" ] + lines).join("\n")
  end

  private

  def pick
    total = ACTIONS.values.sum
    point = @random.rand(total)
    ACTIONS.each do |action, weight|
      return action if point < weight

      point -= weight
    end
  end

  def one(list) = list.empty? ? nil : list[@random.rand(list.size)]
  def chance(fraction) = @random.rand < fraction

  # --- reading the walk's state -------------------------------------------

  def tasks = Task.where(workspace_id: workspace_id).order(:created_at, :id).to_a
  def live_tasks = tasks.reject { |task| %w[done cancelled].include?(task.state) }

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

  # A task in the Backlog, or now and then an idea in the Imaginarium.
  def add_task(index)
    return sweep(index) if tasks.size >= MAXIMUM_TASKS

    command(index, :add_task, "add_task", @owner, "title" => "Made-up task #{index}", "goal" => "A made-up goal.",
      "priority" => one(%w[low normal high]), "work_reference" => nil, "state" => chance(0.2) ? "imaginarium" : "backlog")
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
    { "id" => task.id, "title" => task.title || "Made-up task", "goal" => task.goal || "A made-up goal.",
      "details" => "Made-up details.", "criteria" => builds + [ { "text" => "A reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }
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
    backlog = tasks.select { |task| task.state == "backlog" }
    useful << -> { complete_contract(index) } if backlog.any?
    useful << -> { add_task(index) } if live_tasks.size < LIVE_TASKS && tasks.size < MAXIMUM_TASKS
    ready = tasks.any? { |task| task.state == "ready" }
    @builders.each do |seat|
      useful << -> { build(index, seat) } if ready || held_by(seat)
    end
    unclaimed = open_reviews.any? { |review| review.reviewer_seat_id.nil? }
    @reviewers.each do |seat|
      useful << -> { review(index, seat) } if unclaimed || review_of(seat)
    end
    useful.empty? ? sweep(index) : one(useful).call
  end

  def build(index, seat)
    task = held_by(seat)
    return command(index, :progress, "claim", seat, {}) unless task
    return acknowledge_as(index, seat, task) unless Leverage::Briefing.acknowledgement(task, seat: seat) == :current

    criterion = build_criteria(task).reject { |candidate| candidate.state == "passed" }.first
    return command(index, :progress, "submit", seat, "id" => task.id, "handoff_note" => "A made-up note.",
      "work_reference" => nil) unless criterion

    name = criterion.state == "started" || chance(0.5) ? "pass_criterion" : "start_criterion"
    params = { "id" => task.id, "cid" => criterion.id }
    params["evidence"] = { "kind" => "link", "value" => "https://example.test/work/#{index}" } if name == "pass_criterion"
    command(index, :progress, name, seat, params)
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

  # --- the owner's controls (milestone 3) -------------------------------------

  def promote(index)
    task = one(tasks.select { |candidate| candidate.state == "imaginarium" }) || one(tasks)
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

  def seats = @builders + @reviewers

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

  # The helper picks up and answers its oldest unfinished request: a start
  # issues the seat's token first; Verify and Sign in again pass, or find
  # the login signed out; anything else finishes.
  def answer_request(index)
    request = HelperRequest.where(workspace_id: workspace_id, state: %w[queued picked_up]).order(:created_at, :id).first
    return sweep(index) unless request

    if request.kind == "start_seat"
      command(index, :answer_request, "issue_seat_token", @helper, "id" => request.id)
    end
    result = %w[verify open_sign_in].include?(request.kind) && chance(0.3) ? SIGNED_OUT : PASSED
    result = result.merge("checks" => []) unless %w[verify open_sign_in run_add_checks].include?(request.kind)
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

  # The sweep's pass: the timers as commands of the app.
  def sweep(index)
    TIMERS.each do |timer|
      request = T::Request.new(command: timer, workspace_id: workspace_id, caller_kind: nil, caller_id: nil, key: nil,
        request_hash: nil, params: {})
      @log << Step.new(index, :sweep, timer, "app", {}, answer(request))
    end
  end

  # The last request, sent again with its key: a repeat writes nothing.
  def repeat(index)
    return claim(index) unless @last

    @log << Step.new(index, :repeat, @last.command, @last.caller_kind, @last.params, answer(@last))
  end

  # --- applying ---------------------------------------------------------------

  # A seat on a login (run by the app), or one that connects on its own.
  def connect(role, index, login = nil)
    params = { "name" => "Made-up #{role} #{index}", "role" => role, "provider" => login&.provider || "claude",
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
    "rejected #{error.class.name.demodulize}: #{error.message}"
  end

  def caller_label(caller)
    case caller
    when User then "owner"
    when Helper then "helper"
    else "#{caller.role} #{caller.name}"
    end
  end
end
