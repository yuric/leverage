require "test_helper"
require_relative "entries/jobs_support"

# Test 3 (PRD L836) for the handoff rows (milestone 3 plan HT-2, HS-3): the
# two reports and the credential_hold_release timer, every task state, from
# StateTableCases. Finishing uses the same handoff as Working and keeps
# the holder. A report without a holder is refused with not_holder (HE-9).
#
# Milestone 4 (its plan §2.1 rule 11): a reviewer's row with no candidate
# releases the review, and a pass of it that waits on a model check is
# cancelled first with invalid_state (PendingTransitions.cancel, WP4's).
# The case of each such row sets up the waiting pass and asserts the call.
class StateTableHandoffTest < ActiveSupport::TestCase
  include JobsSupport

  COMMANDS = %w[report_limit report_signed_out credential_hold_release].freeze

  setup do
    use_scenario(lease_length_seconds: 3600)
    @own = scenario.credential(provider: "claude", model: "claude-model-1")
    @below = scenario.credential(provider: "codex")
    @builder = scenario.seat(role: "builder", credential: @own)
    @reviewer = scenario.seat(role: "reviewer", credential: @own)
  end

  StateTableCases.define(self, COMMANDS) do |kase|
    if kase.refusal then assert_refusal(kase)
    else assert_row(kase)
    end
  end

  private

  # The task of the case, in its state, held by the builder where a seat
  # can hold it.
  def task_in(from)
    case from
    when "finishing" then scenario.finishing_task(builder: @builder, actions: [ { kind: "send", state: "approved" } ])
    when "working" then scenario.task(state: "working", builder: @builder)
    else scenario.task(state: from, builder: @builder, reviewer: @reviewer)
    end
  end

  def params_for(kase, task, review: nil)
    case kase.command
    when "report_limit" then limit_params(@own, review ? @reviewer : @builder, task: (task unless review), review: review,
      reset_at: from_now(900))
    when "report_signed_out" then signed_out_params(@own, review ? @reviewer : @builder, task: (task unless review),
      review: review)
    else { "task_id" => task.id }
    end
  end

  def apply(kase, params)
    kase.command == "credential_hold_release" ? release_timer(params) : helper_command(kase.command, params)
  end

  def assert_refusal(kase)
    task = task_in(kase.from)
    review = kase.from == "in_review" && kase.command != "credential_hold_release" ? Review.find_by!(task_id: task.id) : nil
    params = params_for(kase, task, review: review)
    outcome = apply(kase, params)
    assert outcome.refused?, kase.name

    codes = refusal_codes(kase, params)
    assert_includes codes, "invalid_state"
    assert_equal T::Precedence.first(codes).code, outcome.refusal.code
  end

  def assert_row(kase)
    available = kase.guard.include?("candidate_available")
    scenario.limit_credential(@below, reset_at: from_now(1800)) unless available
    task = task_in(kase.from)
    review = scenario.review(task, reviewer: @reviewer) if kase.guard.include?("reviewer_holds_review")
    hold_on(task) if kase.command == "credential_hold_release"
    releases = review && !available
    pending = scenario.pending_transition(task, command: "pass_review", requester: @reviewer, params: { "id" => review.id }) if releases
    written = nil
    cancelled = answering(Leverage::PendingTransitions, :cancel) do
      answering(Leverage::PendingTransitions, :of, ->(asked) { pending if asked.id == task.id }) do
        written = events_written { assert_completed(apply(kase, params_for(kase, task, review: review))) }
      end
    end

    expected_cancels = releases ? [ [ pending.id, "invalid_state" ] ] : []
    assert_equal expected_cancels, cancelled.map { |call| [ call.arguments[1].id, call.arguments[2] ] }, kase.name
    expected = kase.events.dup
    expected << "inbox.opened" if kase.command == "report_signed_out" && kase.conditional_events.any? && !review
    assert_equal expected, written.map(&:type), kase.name
    assert_equal kase.to, task.reload.state
    assert_equal @builder.id, task.holder_seat_id if kase.from == "finishing"
  end

  # A credential_limit hold on the task whose due time has passed: the
  # seat's own login reset at the task's last event.
  def hold_on(task)
    scenario.limit_credential(@own, reset_at: from_now(3600))
    scenario.limit_credential(@below, reset_at: from_now(3600))
    scenario.hold(task, reason: "credential_limit", credential: @own, item: false)
    @own.update_columns(limited_until: Event.where(task_id: task.id).maximum(:effective_at))
  end

  def refusal_codes(kase, params)
    ActiveRecord::Base.transaction(requires_new: true) do
      request = if kase.command == "credential_hold_release"
        T::Request.new(command: kase.command, workspace_id: scenario.workspace_id, caller_kind: nil, caller_id: nil, key: nil,
          request_hash: nil, params: params)
      else
        helper_request(kase.command, params)
      end
      ctx = scenario.context(request: request)
      entry = T::Table.entry_for(kase.command).new
      entry.load(ctx)
      entry.refusals(ctx).map { |refusal| refusal.is_a?(T::Refusal) ? refusal.code : refusal.to_s }
    end
  end
end
