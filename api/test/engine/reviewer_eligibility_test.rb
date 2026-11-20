require "test_helper"
require_relative "provider_world"
require_relative "entries/handoff_support"

# "No reviewer is eligible" (PRD L201, L451, L938; contract decision SM-42;
# milestone 4 plan RD-50, RD-51, §2.1): Leverage::ReviewerEligibility opens
# the item while the provider rule is on and no enabled, connected
# reviewer seat may take a waiting review now (it never built the task, and
# the account its review would run on exists and is of a provider the rule
# allows), and resolves it when one may, or when the rule is off. It runs
# after the commands whose state rows carry the item's side events
# (REEVALUATED_BY), after any command that writes task.submitted,
# review.released or review.lease_expired, and in the reviewer_eligibility
# timer. Gating is a Gating::StandIn world (ProviderWorld) whose answers
# stand for the engine's; the rule's switch is its rules row.
class ReviewerEligibilityTest < ActiveSupport::TestCase
  include HandoffSupport

  RE = Leverage::ReviewerEligibility
  ITEM = "no_reviewer_eligible".freeze

  setup do
    use_scenario
    @rules = scenario.with_shipped_rules
    @rule = @rules.find { |rule| rule.key == "different_provider_review" }
    @claude = scenario.credential(provider: "claude")
    @builder = scenario.seat(role: "builder", credential: @claude)
    @task = scenario.task(state: "in_review", builder: @builder)
    @review = Review.find_by!(task_id: @task.id)
    Leverage::Gating.implementation = ProviderWorld.for(@rule)
  end

  def reviewer(provider, **columns)
    scenario.seat(role: "reviewer", credential: scenario.credential(provider: provider), **columns)
  end

  # ReviewerEligibility.reevaluate inside a command of the app (no caller,
  # no key). Returns the events it wrote.
  def reevaluate(**options)
    events_written do
      ActiveRecord::Base.transaction(requires_new: true) { RE.reevaluate(scenario.context, **options) }
    end
  end

  # after_command as the pipeline calls it, for a command of entry's name
  # run by the owner with a key. Returns the events it wrote.
  def after_owner_command(command, key: new_key)
    events_written do
      ActiveRecord::Base.transaction(requires_new: true) do
        ctx = scenario.context(request: owner_request(command, {}, key: key))
        RE.after_command(ctx, T::Table.entry_for(command).new)
      end
    end
  end

  def items(state: nil)
    scope = InboxItem.where(workspace_id: scenario.workspace_id, kind: ITEM)
    state ? scope.where(state: state) : scope
  end

  def open_item = items(state: "open").sole

  def seat_command(seat, command, params = {}, key: new_key)
    T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
      key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  def reviewer_eligibility_timer
    events_written { Leverage::Timers.apply_workspace(scenario.workspace_id, "reviewer_eligibility", at: scenario.database_now) }
  end

  # --- The one list -------------------------------------------------------------

  test "REEVALUATED_BY is the commands of the state rows that carry the item's side events (SM-42)" do
    rows = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }.select do |row|
      row.fetch("side_events").any? { |side| side.fetch("event") == "inbox.opened" && side["note"].to_s.include?("SM-42") }
    end
    assert_equal rows.map { |row| row.fetch("command") }.uniq.sort, RE::REEVALUATED_BY.sort
    assert RE::REEVALUATED_BY.frozen?
  end

  # --- When it opens ------------------------------------------------------------

  test "with the rule on and only a reviewer of a provider that built the task, the item opens, naming the review and the rule" do
    reviewer("claude")
    written = reevaluate

    item = open_item
    assert_equal [ "task", @task.id, nil, nil ], item.attributes.values_at("about_kind", "about_id", "hold_id", "credential_id")
    assert_equal({ "review_id" => @review.id, "rule_id" => @rule.id }, item.facts)
    assert_equal %w[connect_seat turn_rule_off], item.choices
    event = written.sole
    assert_equal [ "inbox.opened", "app", nil, "inbox_item", item.id, @task.id, 0, nil, nil ],
      event.attributes.values_at("type", "actor_kind", "actor_id", "subject_kind", "subject_id", "task_id", "round",
        "cause_id", "command_id")
    assert_equal({ "kind" => ITEM }, event.payload)
    assert_empty reevaluate, "nothing is written while nothing changes"
  end

  test "with no reviewer seat at all the item opens; a reviewer of another provider that never built the task keeps it closed" do
    reevaluate
    assert_equal 1, items(state: "open").count

    reviewer("codex")
    reevaluate
    assert_empty items(state: "open")
    assert_equal [ "resolved" ], items.pluck(:state), "one item, opened and resolved"
  end

  test "a reviewer that built the task does not count, whatever its provider (L455)" do
    codex = reviewer("codex")
    scenario.append("task.claimed", task: @task, actor_kind: "seat", actor_id: codex.id,
      payload: { seat_id: codex.id, credential_id: codex.credential_id, model: nil })
    reevaluate
    assert_equal @review.id, open_item.facts["review_id"]
  end

  test "a disabled, paused or removed reviewer does not count" do
    reviewer("codex", enabled: false)
    scenario.pause_seat(reviewer("codex"))
    scenario.remove(reviewer("codex"))
    reevaluate
    assert_equal 1, items(state: "open").count
  end

  test "a reviewer that connects on its own counts by its own provider" do
    scenario.seat(role: "reviewer", provider: "claude")
    reevaluate
    assert_equal 1, items(state: "open").count

    scenario.seat(role: "reviewer", provider: "grok")
    reevaluate
    assert_empty items(state: "open")
  end

  # RD-51: an allowed reviewer whose accounts are all at a limit or signed
  # out has no account to review on, and the item opens; the
  # reviewer_eligibility timer resolves it when one resets, with no command.
  test "an allowed reviewer whose accounts are all unavailable does not count; the timer resolves the item when one resets (RD-51)" do
    codex = scenario.credential(provider: "codex")
    seat = scenario.seat(role: "reviewer", credential: codex)
    scenario.limit_credential(codex, reset_at: scenario.database_now + 3600)
    reevaluate
    item = open_item

    assert_empty reviewer_eligibility_timer, "nothing has reset"
    codex.update!(limited_until: scenario.database_now - 1)
    written = reviewer_eligibility_timer
    event = written.sole
    assert_equal [ "inbox.resolved", "app", nil, item.id, nil, nil, { "choice" => nil } ],
      event.attributes.values_at("type", "actor_kind", "actor_id", "subject_id", "cause_id", "command_id", "payload")
    assert_equal [ "resolved", "app", nil ], item.reload.attributes.values_at("state", "resolved_by_kind", "resolved_by_id")

    scenario.sign_out_credential(Credential.find(seat.credential_id))
    reviewer_eligibility_timer
    assert_equal 1, items(state: "open").count, "a signed-out login is no account either"
  end

  # RD-50: the provider compared is that of the account the review would run
  # on, not the seat's own.
  test "the account a reviewer's review would run on decides, not the seat's own provider (RD-50)" do
    codex = scenario.credential(provider: "codex")
    below = scenario.credential(provider: "claude")
    seat = scenario.seat(role: "reviewer", credential: codex)
    scenario.limit_credential(codex, reset_at: scenario.database_now + 3600)
    reevaluate
    assert_equal 1, items(state: "open").count, "its only available account is of a provider that built the task"

    scenario.limit_credential(below, reset_at: scenario.database_now + 3600)
    allowed = scenario.credential(provider: "grok")
    scenario.run(seat, on: allowed)
    reevaluate
    assert_empty items(state: "open"), "an allowed account below is the one its review would run on"
  end

  test "the timer resolves the item when the world's answer changes with no command (RD-51)" do
    reviewer("codex")
    Leverage::Gating.implementation = ProviderWorld.for(@rule, built_by: { @task.id => %w[claude codex] })
    reevaluate
    item = open_item

    Leverage::Gating.implementation = ProviderWorld.for(@rule, built_by: { @task.id => %w[claude] })
    assert_equal [ [ "inbox.resolved", item.id ] ], reviewer_eligibility_timer.map { |event| [ event.type, event.subject_id ] }
  end

  # --- With the rule off --------------------------------------------------------

  test "with the provider rule off or removed no item opens, and an open one resolves (RD-51)" do
    reviewer("claude")
    reevaluate
    item = open_item

    @rule.update!(enabled: false)
    Leverage::Gating.implementation = ProviderWorld.for(@rule)
    reevaluate
    assert_equal "resolved", item.reload.state
    assert_empty reevaluate

    @rule.update!(enabled: true, removed_at: scenario.database_now)
    reevaluate
    assert_empty items(state: "open")
  end

  test "turning the rule off resolves the item with the choice turn_rule_off, as the owner; removing it with none" do
    reviewer("claude")
    reevaluate
    item = open_item
    @rule.update!(enabled: false)
    key = new_key

    event = after_owner_command("disable_rule", key: key).sole
    assert_equal [ "inbox.resolved", "owner", scenario.owner.id, item.id, key, nil, { "choice" => "turn_rule_off" } ],
      event.attributes.values_at("type", "actor_kind", "actor_id", "subject_id", "command_id", "cause_id", "payload")
    assert_equal [ "owner", scenario.owner.id ], item.reload.attributes.values_at("resolved_by_kind", "resolved_by_id")

    @rule.update!(enabled: true)
    reevaluate
    @rule.update!(removed_at: scenario.database_now)
    assert_equal [ { "choice" => nil } ], after_owner_command("remove_rule").map(&:payload)
  end

  # --- What it runs after -------------------------------------------------------

  test "every workspace-wide command of REEVALUATED_BY re-evaluates every waiting review" do
    reviewer("claude")
    other = scenario.task(state: "in_review", builder: @builder)
    workspace_wide = %w[connect_seat change_seat pause_seat resume_seat remove_seat report_run_stopped report_request_result
                        install_shipped_rules enable_rule disable_rule save_rule revert_rule remove_rule reviewer_eligibility]
    assert_empty workspace_wide - RE::REEVALUATED_BY

    workspace_wide.each do |command|
      items.update_all(state: "resolved")
      written = after_owner_command(command)
      assert_equal [ @task.id, other.id ].sort, written.map(&:task_id).sort, command
      assert_equal [ "inbox.opened" ], written.map(&:type).uniq, command
    end
  end

  test "a command outside REEVALUATED_BY that writes no waiting event runs nothing" do
    reviewer("claude")
    assert_empty after_owner_command("hold")
    assert_empty items
  end

  test "release_review opens the item caused by review.released, with that event's key and the app as actor" do
    codex = reviewer("codex")
    scenario.review(@task, reviewer: codex)
    Leverage::Gating.implementation = ProviderWorld.for(@rule, built_by: { @task.id => %w[claude codex] })
    key = new_key

    written = events_written { assert seat_command(codex, "release_review", { "id" => @review.id }, key: key).completed? }
    released, opened = written
    assert_equal %w[review.released inbox.opened], written.map(&:type)
    assert_equal [ "app", nil, released.id, key, released.effective_at ],
      opened.attributes.values_at("actor_kind", "actor_id", "cause_id", "command_id", "effective_at")
  end

  # The owner's Hold on the task applies the due review lease first
  # (Timers.apply_due), as any command on the task does.
  test "a review lease that ends inside another command opens the item caused by review.lease_expired, with no key" do
    codex = reviewer("codex")
    scenario.review(@task, reviewer: codex)
    Leverage::Gating.implementation = ProviderWorld.for(@rule, built_by: { @task.id => %w[claude codex] })
    scenario.make_due(@review.reload)

    written = events_written { assert_completed(owner_command("hold", { "id" => @task.id })) }
    expired = written.find { |event| event.type == "review.lease_expired" }
    opened = written.find { |event| event.type == "inbox.opened" }
    assert opened, "review.lease_expired is one of SM-42's three events"
    assert_equal [ "app", nil, expired.id, nil, expired.effective_at ],
      opened.attributes.values_at("actor_kind", "actor_id", "cause_id", "command_id", "effective_at")
  end

  test "a reviewer's limit with no allowed candidate releases the review and opens the item as the helper (trace 19, L913)" do
    codex = scenario.credential(provider: "codex")
    seat = scenario.seat(role: "reviewer", credential: codex)
    scenario.credential(provider: "claude")
    scenario.review(@task, reviewer: seat)
    key = new_key

    written = events_written do
      assert_completed(report_limit(codex, seat, review: @review, reset_at: scenario.database_now + 3600, key: key))
    end
    assert_equal %w[credential.limit_reached review.released inbox.opened], written.map(&:type)
    assert_equal [ "app", scenario.helper.id, written[1].id, key ],
      written.last.attributes.values_at("actor_kind", "actor_id", "cause_id", "command_id")
  end

  test "an item whose review was taken is resolved; a new round's waiting review gets an item of its own" do
    reviewer("claude")
    reevaluate
    first = open_item
    scenario.review(@task, reviewer: scenario.seat(role: "reviewer", provider: "grok"))
    reevaluate
    assert_equal "resolved", first.reload.state

    @review.reload.update!(verdict: "failed", lease_due_at: nil)
    @task.update!(round: 1)
    second = Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 1)
    Seat.where(workspace_id: scenario.workspace_id, provider: "grok").update_all(enabled: false)
    reevaluate
    assert_equal({ "review_id" => second.id, "rule_id" => @rule.id }, open_item.facts)
  end

  test "task_ids: limits it to those tasks" do
    reviewer("claude")
    other = scenario.task(state: "in_review", builder: @builder)
    assert_equal [ other.id ], reevaluate(task_ids: [ other.id ]).map(&:task_id)
  end
end
