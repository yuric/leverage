require "digest"
require "json"

# A seeded random walk over the milestone-2 commands and timers (PRD test 2;
# milestone 2 plan EN-25): owners add, contract and cancel tasks and allow
# another round; builders claim, acknowledge, start and pass criteria,
# submit, release and heartbeat; reviewers claim reviews, acknowledge,
# pass, fail, release and heartbeat; leases are put at their due time
# (EN-18) and expire through the next command or the sweep; and a request
# is sometimes sent again with its key. Every command goes through
# Transitions.apply, so the whole log of the walk's workspace is made by
# the engine: the seats connect on their own through connect_seat, and only
# the workspace and its owner are inserted (they write no event).
#
# Most calls are ones the state allows; some are not, on purpose, and are
# refused or answered 404 or 422 (NotFound, Invalid), which writes nothing.
# Any other error ends the walk; Walk#to_s is the seed and every step.
#
#   walk = Walk.new(seed: 42).run
#   walk.workspace_id
#   puts walk
class Walk
  T = Leverage::Transitions

  # What the walk can do, with how often (out of the sum).
  ACTIONS = {
    add_task: 4, complete_contract: 4, cancel: 1, allow_another_round: 2,
    claim: 5, acknowledge: 6, start_criterion: 4, pass_criterion: 6, submit: 5, release: 1, heartbeat: 2,
    claim_review: 5, acknowledge_review: 5, verdict: 6, release_review: 1, heartbeat_review: 1,
    expire_builder: 2, expire_review: 2, sweep: 2, repeat: 2
  }.freeze
  RELEASE_REASONS = %w[unable_to_continue not_suited_to_this_seat stopping].freeze
  MAXIMUM_TASKS = 4

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
    @scenario = Scenario.new(lease_length_seconds: 600, maximum_rounds: 2)
    @owner = scenario.owner
    @builders = Array.new(2) { |index| connect("builder", index) }
    @reviewers = Array.new(2) { |index| connect("reviewer", index) }
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

  def add_task(index)
    return sweep(index) if tasks.size >= MAXIMUM_TASKS

    command(index, :add_task, "add_task", @owner, "title" => "Made-up task #{index}", "goal" => "A made-up goal.",
      "priority" => one(%w[low normal high]), "work_reference" => nil, "state" => "backlog")
  end

  def complete_contract(index)
    task = one(tasks.select { |candidate| candidate.state == "backlog" }) || one(tasks)
    return sweep(index) unless task

    builds = Array.new(1 + @random.rand(2)) { |number| { "text" => "Made-up criterion #{number + 1}.", "kind" => "build" } }
    command(index, :complete_contract, "complete_contract", @owner,
      "id" => task.id, "title" => task.title || "Made-up task", "goal" => task.goal || "A made-up goal.",
      "details" => "Made-up details.", "criteria" => builds + [ { "text" => "A reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil)
  end

  def cancel(index)
    task = one(live_tasks) || one(tasks)
    return sweep(index) unless task

    command(index, :cancel, "cancel", @owner, "id" => task.id)
  end

  def allow_another_round(index)
    held = Hold.where(workspace_id: workspace_id, reason: "rounds_exceeded", closed_at: nil).pluck(:task_id)
    task = Task.find_by(id: one(held)) || one(tasks)
    return sweep(index) unless task

    command(index, :allow_another_round, "allow_another_round", @owner, "id" => task.id)
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

  # --- timers ----------------------------------------------------------------

  # A running builder lease reaches its due time: the next command on the
  # task, or the sweep, ends it.
  def expire_builder(index)
    task = one(Task.where(workspace_id: workspace_id).where.not(lease_due_at: nil).to_a)
    return sweep(index) unless task

    scenario.make_due(task, at: scenario.database_now)
    @log << Step.new(index, :expire_builder, "make_due", "test", { "task" => task.id }, "due now")
  end

  def expire_review(index)
    review = one(Review.where(workspace_id: workspace_id, verdict: nil).where.not(lease_due_at: nil).to_a)
    return sweep(index) unless review

    scenario.make_due(review, at: scenario.database_now)
    @log << Step.new(index, :expire_review, "make_due", "test", { "review" => review.id }, "due now")
  end

  # The sweep's pass: both lease timers as commands of the app.
  def sweep(index)
    %w[builder_lease_expiry review_lease_expiry].each do |timer|
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

  def connect(role, index)
    request = request("connect_seat", @owner, "name" => "Made-up #{role} #{index}", "role" => role,
      "provider" => "claude", "model" => "made-up-model", "effort" => nil)
    outcome = T.apply(request)
    raise "connect_seat was #{outcome.outcome}" unless outcome.completed?

    Seat.find(outcome.result.fetch("seat_id"))
  end

  def command(index, action, name, caller, params)
    request = request(name, caller, params)
    @last = request
    @log << Step.new(index, action, name, caller_label(caller), params, answer(request))
  end

  def request(name, caller, params)
    @count += 1
    kind = caller.is_a?(User) ? "owner" : "seat"
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
    caller.is_a?(User) ? "owner" : "#{caller.role} #{caller.name}"
  end
end
