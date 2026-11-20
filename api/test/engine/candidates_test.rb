require "test_helper"
require_relative "provider_world"
require_relative "entries/call_spy"
require_relative "entries/handoff_support"

# Leverage::Candidates (PRD L650-L703; milestone 3 plan §2.1 rules 1 to 4
# and 8, HE-3, HE-4, HE-5, HE-35): a seat's candidates in order, whether
# one is available at a time, the next one after a stopped credential, the
# earliest reset and the due time of a credential hold, whether one is
# signed out, the model a run on one uses, and the wait_ready cause of a
# task. One test per sentence of those rules. It reads and writes nothing
# else, so every test builds its rows with Scenario.
class CandidatesTest < ActiveSupport::TestCase
  include CallSpy

  C = Leverage::Candidates

  # A gating whose provider rule refuses the given providers.
  class Refusing < Leverage::Gating::NoRules
    def initialize(*providers)
      super()
      @providers = providers
    end

    def provider_allowed?(task_id:, provider:) = !@providers.include?(provider)
  end

  # A gating that filters given tasks out of one seat's claims.
  class Filtering < Leverage::Gating::NoRules
    def initialize(seat, tasks)
      super()
      @seat_id = seat.id
      @tasks = tasks
    end

    def claimable_filter(seat_id:, kind:)
      Leverage::Gating::ClaimFilter.new(excluded_task_ids: seat_id == @seat_id ? @tasks : [], excluded_review_ids: [])
    end
  end

  setup do
    @scenario = Scenario.new
    @now = @scenario.database_now
  end

  # Four logins in the order of adding: above, own, between, below.
  def ladder
    above = @scenario.credential(provider: "claude")
    own = @scenario.credential(provider: "claude")
    between = @scenario.credential(provider: "codex")
    below = @scenario.credential(provider: "grok")
    [ above, own, between, below ]
  end

  # This workspace's events: a committing test elsewhere may leave others.
  def events = Event.where(workspace_id: @scenario.workspace_id)

  def limited(credential, reset_at: @now + 3600)
    @scenario.limit_credential(credential, reset_at: reset_at)
  end

  # --- Rule 1: candidates ----------------------------------------------------

  test "rule 1: the candidates are every added login at or after the seat's own, in position order, its own first" do
    above, own, between, below = ladder
    seat = @scenario.seat(credential: own)

    assert_equal [ own, between, below ].map(&:id), C.for(seat).map(&:id)
    refute_includes C.for(seat).map(&:id), above.id
  end

  test "rule 1: a credential whose add is still running is no candidate" do
    own = @scenario.credential
    running = @scenario.credential(added: false)
    seat = @scenario.seat(credential: own)

    assert_equal [ own.id ], C.for(seat).map(&:id)
    refute_includes Credential.added.map(&:id), running.id
    assert_includes Credential.added.map(&:id), own.id
  end

  test "rule 1: an API token keeps its place but is no candidate" do
    own = @scenario.credential
    @scenario.credential(kind: "api_token", provider: "claude_api")
    below = @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own)

    assert_equal [ own.id, below.id ], C.for(seat).map(&:id)
  end

  test "rule 1: a seat with no credential has no candidate and nothing is available to it" do
    @scenario.credential
    seat = @scenario.seat(provider: "claude")
    task = @scenario.task(state: "ready")

    assert_equal [], C.for(seat)
    assert_nil C.first_available(seat, task, @now)
    assert_nil C.due_at(seat, task, @now)
    refute C.any_signed_out?(seat)
  end

  test "rule 1: a signed-out login is still a candidate, and the order is position, not the order of the rows" do
    own = @scenario.credential
    first_below = @scenario.credential(provider: "codex")
    second_below = @scenario.credential(provider: "grok")
    first_below.update_columns(position: 9)
    @scenario.sign_out_credential(second_below)
    seat = @scenario.seat(credential: own)

    assert_equal [ own.id, second_below.id, first_below.id ], C.for(seat).map(&:id)
  end

  # --- Rule 2: available -------------------------------------------------------

  test "rule 2: a candidate is available when it is active and not limited" do
    credential = @scenario.credential

    assert C.available?(credential, @now)
    refute credential.limited?(@now)
  end

  test "rule 2: a signed-out candidate is not available" do
    credential = @scenario.sign_out_credential(@scenario.credential)

    refute C.available?(credential, @now)
    assert_equal "signed_out", credential.reload.state
  end

  test "rule 2: limited means limited_since is set and limited_until is null or later than the time" do
    credential = limited(@scenario.credential, reset_at: @now + 60)

    assert credential.limited?(@now)
    refute C.available?(credential, @now)
    refute credential.limited?(@now + 60), "a reset time that has come is no limit"
    assert C.available?(credential, @now + 61)
  end

  test "rule 2: a limit with no reset time is unavailable at any time" do
    credential = limited(@scenario.credential, reset_at: nil)

    assert_nil credential.limited_until
    refute C.available?(credential, @now)
    refute C.available?(credential, @now + 30.days)
  end

  test "rule 2: nothing is written when a reset time passes" do
    credential = limited(@scenario.credential, reset_at: @now - 1)
    before = [ credential.limited_since, credential.limited_until, events.count ]

    assert C.available?(credential, @now)
    credential.reload
    assert_equal before, [ credential.limited_since, credential.limited_until, events.count ]
  end

  # --- Rule 3: one piece of work ---------------------------------------------

  test "rule 3: a candidate of another provider group below the task's minimum strength rank is passed over" do
    own = limited(@scenario.credential(provider: "claude"))
    weak = @scenario.credential(provider: "codex", strength_rank: 1)
    strong = @scenario.credential(provider: "grok", strength_rank: 3)
    seat = @scenario.seat(credential: own, strength_rank: 3)
    task = @scenario.task(state: "ready")
    task.update_columns(minimum_strength_rank: 2)

    assert_equal strong.id, C.first_available(seat, task, @now).id
    assert_equal weak.id, C.first_available(seat, nil, @now).id, "with no work, rule 3 asks nothing"
  end

  test "rule 3: a candidate of the seat's own provider group is not passed over for its own rank" do
    own = limited(@scenario.credential(provider: "claude"))
    same_group = @scenario.credential(provider: "claude", strength_rank: 1)
    seat = @scenario.seat(credential: own, strength_rank: 3)
    task = @scenario.task(state: "ready")
    task.update_columns(minimum_strength_rank: 2)

    assert_equal same_group.id, C.first_available(seat, task, @now).id
  end

  test "rule 3: for a review, a candidate the provider rule refuses is passed over, and a task asks nothing" do
    own = limited(@scenario.credential(provider: "claude"))
    refused = @scenario.credential(provider: "codex")
    allowed = @scenario.credential(provider: "grok")
    seat = @scenario.seat(role: "reviewer", credential: own)
    task = @scenario.task(state: "in_review")
    review = Review.find_by!(task_id: task.id)
    Leverage::Gating.implementation = Refusing.new("codex")

    assert_equal allowed.id, C.first_available(seat, review, @now).id
    assert_equal refused.id, C.first_available(seat, task, @now).id
    assert_equal allowed.id, C.next_after(seat, review, own, @now).id
  end

  test "rule 3: the first available candidate is the seat's own when it is available" do
    own, below = @scenario.credential, @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own)

    assert_equal own.id, C.first_available(seat, nil, @now).id
    limited(own)
    assert_equal below.id, C.first_available(seat, nil, @now).id
  end

  # Milestone 4 plan WP9 (HE-41, RD-50, L913): rule 3 obeys the provider
  # rule's answer, asked of Gating for each candidate with the candidate's
  # own provider. Gating is a StandIn world whose answers stand for the
  # engine's; WP3 proves what the real comparison answers.
  test "rule 3 with a gating world: provider_allowed? is asked for each candidate of a review with its provider, and every refusal is passed over" do
    own = limited(@scenario.credential(provider: "claude"))
    gemini = @scenario.credential(provider: "gemini")
    codex = @scenario.credential(provider: "codex")
    seat = @scenario.seat(role: "reviewer", credential: own)
    task = @scenario.task(state: "in_review")
    review = Review.find_by!(task_id: task.id)
    Leverage::Gating.implementation = ProviderWorld.new(built_by: { task.id => %w[claude gemini] })

    asked = spy_on(Leverage::Gating, :provider_allowed?) { assert_equal codex.id, C.first_available(seat, review, @now).id }
    assert_equal %w[gemini codex], asked.map { |call| call.keywords.fetch(:provider) },
      "the limited one is not available, so it is not asked about"
    assert(asked.all? { |call| call.keywords.fetch(:task_id) == task.id })
    assert_nil C.next_after(seat, review, codex, @now), "with codex stopped, nothing the world allows is left"
    assert_equal codex.id, C.next_after(seat, review, gemini, @now).id

    Leverage::Gating.implementation = ProviderWorld.new(rule_id: nil, built_by: { task.id => %w[claude gemini] })
    assert_equal gemini.id, C.first_available(seat, review, @now).id, "with the rule off nothing is refused"
  end

  test "rule 3 with a gating world: a reviewer's limit with no candidate the world allows below releases the review (L913)" do
    extend HandoffSupport
    @scenario.helper
    own = @scenario.credential(provider: "codex")
    claude = @scenario.credential(provider: "claude")
    seat = @scenario.seat(role: "reviewer", credential: own)
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: seat)
    Leverage::Gating.implementation = ProviderWorld.new(built_by: { task.id => %w[claude] })

    assert C.available?(claude, @now)
    before = @scenario.workspace.reload.last_seq
    assert report_limit(own, seat, review: review, reset_at: @scenario.database_now + 3600).completed?
    assert_nil review.reload.reviewer_seat_id
    assert_equal %w[credential.limit_reached review.released], events.where("seq > ?", before).order(:seq).map(&:type)
  end

  # --- Rule 4: the next candidate ------------------------------------------------

  test "rule 4: the next candidate after a stopped one is the first available one below it" do
    _above, own, between, below = ladder
    seat = @scenario.seat(credential: own)
    limited(between)
    next_below = @scenario.credential(provider: "codex")
    limited(below)

    assert_equal next_below.id, C.next_after(seat, nil, between, @now).id
  end

  test "rule 4: with none below, it goes back to the seat's own credential when that is available" do
    _above, own, between, below = ladder
    seat = @scenario.seat(credential: own)
    limited(below)

    assert_equal own.id, C.next_after(seat, nil, below, @now).id
    refute_equal between.id, C.next_after(seat, nil, below, @now).id
  end

  test "rule 4: with none below and the seat's own unavailable, nobody, even when one between them is available" do
    _above, own, between, below = ladder
    seat = @scenario.seat(credential: own)
    limited(own)
    limited(below)

    assert C.available?(between, @now)
    assert_nil C.next_after(seat, nil, below, @now)
  end

  test "rule 4: accounts above the stopped one are not tried" do
    above = @scenario.credential
    own = @scenario.credential
    stopped = @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own)
    limited(own)

    assert C.available?(above, @now)
    assert_nil C.next_after(seat, nil, stopped, @now)
  end

  test "rule 4: the stopped credential is never the answer, even before it is marked" do
    own = @scenario.credential
    seat = @scenario.seat(credential: own)

    assert C.available?(own, @now)
    assert_nil C.next_after(seat, nil, own, @now)
  end

  test "rule 4: when the seat's own stopped, the next is the first available one below it" do
    own = @scenario.credential
    signed_out = @scenario.sign_out_credential(@scenario.credential(provider: "codex"))
    below = @scenario.credential(provider: "grok")
    seat = @scenario.seat(credential: own)
    limited(own)

    refute C.available?(signed_out, @now)
    assert_equal below.id, C.next_after(seat, nil, own, @now).id
  end

  # --- Rule 8: the due time ------------------------------------------------------

  def held_task(seat)
    @scenario.task(state: "working", builder: seat)
  end

  def last_effective(task) = Event.where(task_id: task.id).maximum(:effective_at)

  test "rule 8: with a candidate available, the hold is due at once, at the task's last effective time" do
    own = limited(@scenario.credential)
    @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own)
    task = held_task(seat)

    assert_equal last_effective(task), C.due_at(seat, task, @now)
  end

  test "rule 8: a limit on a lower account after the seat's own is limited, with one between available, is due at once" do
    _above, own, between, below = ladder
    seat = @scenario.seat(credential: own)
    task = held_task(seat)
    limited(own)
    limited(below)

    assert_nil C.next_after(seat, task, below, @now)
    assert C.available?(between, @now)
    assert_equal last_effective(task), C.due_at(seat, task, @now)
  end

  test "rule 8: otherwise the earliest reset among the signed-in candidates" do
    own = limited(@scenario.credential, reset_at: @now + 900)
    soon = limited(@scenario.credential(provider: "codex"), reset_at: @now + 300)
    seat = @scenario.seat(credential: own)
    task = held_task(seat)

    assert_equal (@now + 300).to_i, C.due_at(seat, task, @now).to_i
    assert_equal soon.id, C.earliest_reset(seat, task, @now).id
  end

  test "rule 8: a signed-out candidate's reset time is not a due time" do
    own = limited(@scenario.credential, reset_at: @now + 900)
    out = limited(@scenario.credential(provider: "codex"), reset_at: @now + 300)
    @scenario.sign_out_credential(out)
    seat = @scenario.seat(credential: own)
    task = held_task(seat)

    assert_equal (@now + 900).to_i, C.due_at(seat, task, @now).to_i
    assert_equal own.id, C.earliest_reset(seat, task, @now).id
  end

  test "rule 8: a candidate rule 3 passes over gives no due time" do
    own = limited(@scenario.credential(provider: "claude"), reset_at: nil)
    weak = limited(@scenario.credential(provider: "codex", strength_rank: 1), reset_at: @now + 300)
    seat = @scenario.seat(credential: own, strength_rank: 3)
    task = held_task(seat)
    task.update_columns(minimum_strength_rank: 2)

    assert_nil C.due_at(seat, task, @now)
    assert_nil C.earliest_reset(seat, task, @now)
    assert_equal weak.id, C.earliest_reset(seat, nil, @now).id
  end

  test "rule 8: never before the task's last effective time" do
    own = limited(@scenario.credential, reset_at: @now - 60)
    seat = @scenario.seat(credential: own)
    task = held_task(seat)
    earlier = @now - 3600

    assert_equal last_effective(task), C.due_at(seat, task, earlier)
  end

  test "rule 8: no candidate with a reset time means no due time" do
    own = limited(@scenario.credential, reset_at: nil)
    @scenario.sign_out_credential(@scenario.credential(provider: "codex"))
    seat = @scenario.seat(credential: own)
    task = held_task(seat)

    assert_nil C.due_at(seat, task, @now)
    assert_nil C.earliest_reset(seat, task, @now)
  end

  # --- Signed out, and the model -----------------------------------------------

  test "any_signed_out? asks the seat's candidates only" do
    above = @scenario.credential
    own = @scenario.credential
    below = @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own)
    @scenario.sign_out_credential(above)

    refute C.any_signed_out?(seat)
    @scenario.sign_out_credential(below)
    assert C.any_signed_out?(seat)
  end

  test "any_signed_out? with a piece of work leaves out a signed-out login rule 3 passes over for it (review)" do
    own = @scenario.credential(provider: "claude", strength_rank: 3)
    weak = @scenario.credential(provider: "codex", strength_rank: 1)
    seat = @scenario.seat(credential: own, strength_rank: 3)
    task = @scenario.task(state: "working", builder: seat)
    task.update_columns(minimum_strength_rank: 3)
    @scenario.sign_out_credential(weak)

    assert C.any_signed_out?(seat), "with no work every candidate counts"
    refute C.any_signed_out?(seat, task)
    assert_nil C.signed_out_for(seat, task)
    weak.update_columns(strength_rank: 3)
    assert C.any_signed_out?(seat, task)
    assert_equal weak.id, C.signed_out_for(seat, task).id
  end

  test "HE-5: within the seat's provider group the seat's model is used, in another the credential's" do
    own = @scenario.credential(provider: "claude", model: "credential-model")
    same = @scenario.credential(provider: "claude", model: "other-claude-model")
    other = @scenario.credential(provider: "grok", model: "grok-made-up-model")
    bare = @scenario.credential(provider: "codex", model: nil)
    seat = @scenario.seat(credential: own, model: "seat-model")
    plain = @scenario.seat(credential: own, model: "")

    assert_equal "seat-model", C.model_for(seat, own)
    assert_equal "seat-model", C.model_for(seat, same)
    assert_equal "grok-made-up-model", C.model_for(seat, other)
    assert_nil C.model_for(seat, bare), "a credential with no model leaves the tool's default"
    assert_nil C.model_for(plain, same), "a seat with no model set is null too"
  end

  test "HE-5: the effort follows the same rule as the model" do
    own = @scenario.credential(provider: "claude")
    other = @scenario.credential(provider: "codex", effort: "high")
    seat = @scenario.seat(credential: own, effort: "low")

    assert_equal "low", C.effort_for(seat, own)
    assert_equal "high", C.effort_for(seat, other)
    assert_nil C.effort_for(@scenario.seat(credential: own, effort: ""), own)
  end

  # --- HE-35: the cause of a wait_ready step -----------------------------------------

  test "HE-35: credential_limit when an eligible builder has no available candidate and none signed out" do
    own = limited(@scenario.credential)
    @scenario.seat(credential: own)
    task = @scenario.task(state: "ready")

    assert_equal "credential_limit", C.wait_cause(task, @now)
  end

  test "HE-35: null when one eligible builder has an available candidate" do
    @scenario.seat(credential: limited(@scenario.credential))
    @scenario.seat(credential: @scenario.credential(provider: "codex"))
    task = @scenario.task(state: "ready")

    assert_nil C.wait_cause(task, @now)
  end

  test "HE-35: null when a candidate of an eligible builder is signed out" do
    own = limited(@scenario.credential)
    @scenario.sign_out_credential(@scenario.credential(provider: "codex"))
    @scenario.seat(credential: own)
    task = @scenario.task(state: "ready")

    assert_nil C.wait_cause(task, @now)
  end

  test "HE-35: a signed-out candidate the task's minimum rank passes over does not stop credential_limit (review)" do
    own = limited(@scenario.credential(provider: "claude", strength_rank: 3))
    @scenario.sign_out_credential(@scenario.credential(provider: "codex", strength_rank: 1))
    @scenario.seat(credential: own, strength_rank: 3)
    task = @scenario.task(state: "ready")
    task.update_columns(minimum_strength_rank: 3)

    assert_equal "credential_limit", C.wait_cause(task, @now)
  end

  test "HE-35: a seat that connects on its own always counts as having one" do
    @scenario.seat(credential: limited(@scenario.credential))
    @scenario.seat(provider: "claude")
    task = @scenario.task(state: "ready")

    assert_nil C.wait_cause(task, @now)
  end

  test "HE-35: null when no builder would be eligible even with accounts left out" do
    own = limited(@scenario.credential)
    paused = @scenario.pause_seat(@scenario.seat(credential: own))
    weak = @scenario.seat(credential: own, strength_rank: 1)
    busy = @scenario.seat(credential: own)
    @scenario.task(state: "working", builder: busy)
    @scenario.seat(role: "reviewer", credential: own)
    task = @scenario.task(state: "ready")
    task.update_columns(minimum_strength_rank: 2)

    assert paused.reload.paused
    assert_nil C.wait_cause(task, @now), "paused, too weak, busy or a reviewer: none counts"
    weak.update_columns(strength_rank: 2)
    assert_equal "credential_limit", C.wait_cause(task, @now)
  end

  test "HE-35: a seat that gating filters out of the claim does not count" do
    @scenario.seat(credential: limited(@scenario.credential))
    alone = @scenario.seat(provider: "claude")
    task = @scenario.task(state: "ready")
    Leverage::Gating.implementation = Filtering.new(alone, [ task.id ])

    assert_equal "credential_limit", C.wait_cause(task, @now)
    Leverage::Gating.implementation = Leverage::Gating::NoRules.new
    assert_nil C.wait_cause(task, @now)
  end

  # --- The Scenario builders the engine packages build on ---------------------

  test "Scenario: a seat's run is on its own credential unless the test says otherwise" do
    own = @scenario.credential
    other = @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own)

    assert_equal own.id, seat.run_credential_id
    assert_nil @scenario.seat(credential: own, token: false).run_credential_id, "no token, no run"
    assert_nil @scenario.seat(provider: "claude").run_credential_id
    assert_nil @scenario.seat(credential: own, run_credential_id: nil).run_credential_id

    @scenario.run(seat, on: other)
    seat.reload
    assert_equal [ other.id, "running" ], [ seat.run_credential_id, seat.run_state ]
  end

  test "Scenario: a limited credential sets both columns, and writes credential.limit_reached when a seat ran on it" do
    credential = @scenario.credential
    seat = @scenario.seat(credential: credential)
    task = @scenario.task(state: "working", builder: seat)
    @scenario.limit_credential(credential, reset_at: @now + 600, seat: seat, task: task, window: "weekly")

    credential.reload
    assert credential.limited_since
    assert_equal (@now + 600).to_i, credential.limited_until.to_i
    event = events.where(type: "credential.limit_reached").sole
    assert_equal [ credential.id, task.id, seat.id, "weekly" ],
      [ event.subject_id, event.task_id, event.payload["seat_id"], event.payload["window"] ]

    quiet = @scenario.limit_credential(@scenario.credential, reset_at: nil)
    assert quiet.limited_since
    assert_equal 1, events.where(type: "credential.limit_reached").count
  end

  test "Scenario: a credential made with limited_until alone gets limited_since too" do
    credential = @scenario.credential(limited_until: @now + 3600)

    assert credential.limited_since
    assert credential.limited?(@now)
  end

  test "Scenario: a signed-out credential writes credential.signed_out" do
    credential = @scenario.sign_out_credential(@scenario.credential)

    assert_equal "signed_out", credential.state
    assert_equal [ credential.id, nil ],
      events.where(type: "credential.signed_out").sole.then { |event| [ event.subject_id, event.payload["seat_id"] ] }
  end

  test "Scenario: an open credential hold with its item, or without" do
    credential = limited(@scenario.credential, reset_at: nil)
    seat = @scenario.seat(credential: credential)
    task = @scenario.task(state: "working", builder: seat)
    hold = @scenario.hold(task, reason: "credential_limit", credential: credential)

    assert_equal [ "credential_limit", credential.id, nil ], [ hold.reason, hold.credential_id, hold.closed_at ]
    assert_equal "limit_with_no_reset_time", InboxItem.find_by!(hold_id: hold.id).kind

    other = @scenario.task(state: "working", builder: @scenario.seat(credential: credential))
    quiet = @scenario.hold(other, reason: "credential_limit", credential: credential, item: false)
    refute InboxItem.exists?(hold_id: quiet.id)
  end

  test "Scenario: a paused seat writes seat.paused" do
    seat = @scenario.pause_seat(@scenario.seat)

    assert seat.paused
    assert events.exists?(type: "seat.paused", subject_id: seat.id)
  end

  test "Scenario: a task in the Imaginarium, and a Finishing row whose builder holds it" do
    idea = @scenario.task(state: "imaginarium")
    builder = @scenario.seat
    finishing = @scenario.finishing_task(builder: builder)

    assert_equal "imaginarium", idea.state
    assert_equal [ "finishing", builder.id, false ],
      [ finishing.state, finishing.holder_seat_id, finishing.lease_due_at.nil? ]
    assert Event.exists?(task_id: finishing.id, type: "task.claimed")
  end
end
