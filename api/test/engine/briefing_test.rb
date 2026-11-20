require "test_helper"

# Leverage::Briefing and Leverage::RoleFiles (PRD, The briefing; milestone 2
# plan EN-6): the briefing holds the brief (empty, version 0, while tasks
# have no project), the seat's role file and the contract; its hash is
# SHA-256 over Gating::CanonicalJson of the parts as {kind, id, version},
# followed by Gating.briefing_rules (none in milestone 2); and an
# acknowledgement is kept per seat, per lease and per hash.
class BriefingTest < ActiveSupport::TestCase
  include OpenapiAssertions

  B = Leverage::Briefing

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @reviewer = @scenario.seat(role: "reviewer")
    @task = @scenario.task(state: "working", builder: @builder)
  end

  def acknowledge(task, seat, hash, review: nil)
    lease = B.lease_event(task, seat: seat, review: review)
    BriefingAcknowledgement.create!(workspace_id: task.workspace_id, seat_id: seat.id, task_id: task.id,
      review_id: review&.id, lease_event_id: lease.id, briefing_hash: hash, acknowledged_at: @scenario.database_now)
  end

  # Four role files from milestone 4 (L470, milestone 4 plan RD-61): the
  # planner's and the orchestrator's join the builder's and the reviewer's.
  test "the role files are the four roles' texts, versioned by the release" do
    assert_equal Leverage::VERSION, Leverage::RoleFiles.version
    %w[builder reviewer planner orchestrator].each do |role|
      assert_equal Rails.root.join("config/role_files/#{role}.md").read, Leverage::RoleFiles.text(role)
    end
    %w[builder reviewer].each { |role| assert_match(/evidence/i, Leverage::RoleFiles.text(role)) }
    assert_raises(ArgumentError) { Leverage::RoleFiles.text("owner") }
  end

  test "the hash is SHA-256 over the parts brief, role file and contract, then the rules" do
    parts = [
      { "kind" => "brief", "id" => nil, "version" => 0 },
      { "kind" => "role_file", "id" => "builder", "version" => Leverage::VERSION },
      { "kind" => "contract", "id" => @task.id, "version" => @task.contract_version }
    ]
    expected = Digest::SHA256.hexdigest(Leverage::Gating::CanonicalJson.dump(parts))

    assert_equal expected, B.hash_for(@task, seat: @builder)
  end

  test "the builder's and the reviewer's hashes differ only by the role file" do
    refute_equal B.hash_for(@task, seat: @builder), B.hash_for(@task, seat: @reviewer)
  end

  test "the hash changes with the contract version and with nothing outside the parts" do
    before = B.hash_for(@task, seat: @builder)
    criterion = Criterion.where(task_id: @task.id, kind: "build").first
    criterion.update!(state: "passed")
    @task.update!(work_reference: "~/work/somewhere-else")
    assert_equal before, B.hash_for(@task.reload, seat: @builder)

    @task.update!(contract_version: @task.contract_version + 1)
    refute_equal before, B.hash_for(@task, seat: @builder)
  end

  test "the briefing has the contract's shape, with criteria, their evidence and no rules" do
    criterion = Criterion.where(task_id: @task.id, kind: "build").first
    Evidence.create!(workspace_id: @task.workspace_id, criterion_id: criterion.id, kind: "link",
      value: "https://example.test/proof", attached_by_seat_id: @builder.id)
    briefing = B.for(@task, seat: @builder)

    assert_matches_component("Briefing", briefing)
    assert_equal B.hash_for(@task, seat: @builder), briefing["hash"]
    assert_equal Leverage::RoleFiles.text("builder"), briefing["role_file"]
    assert_equal [], briefing["rules"]
    assert_equal [], briefing["brief"]
    assert_equal({ "rule_version_ids" => [], "brief_version" => 0, "role_file_version" => Leverage::VERSION,
                   "contract_version" => @task.contract_version }, briefing["versions"])
    contract = briefing["contract"]
    assert_equal @task.goal, contract["goal"]
    assert_equal Criterion.where(task_id: @task.id).order(:position).pluck(:id), contract["criteria"].map { |row| row["id"] }
    assert_equal [ "https://example.test/proof" ], contract["criteria"].first["evidence"].map { |row| row["value"] }
    assert_equal [], contract["actions"]
  end

  test "the builder's response carries the notes of failed reviews, oldest first; the reviewer's none" do
    first = Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 0, verdict: "failed",
      notes: "The first notes.", reviewer_seat_id: @reviewer.id)
    second = Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 1, verdict: "failed",
      notes: "The second notes.", reviewer_seat_id: @reviewer.id)
    Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 2, verdict: "passed", notes: "Fine.")

    response = B.response(@task, seat: @builder)
    assert_matches_component("BriefingResponse", response)
    assert_equal @task.work_reference, response["work_reference"]
    assert_equal [ [ first.id, 0, "The first notes." ], [ second.id, 1, "The second notes." ] ],
      response["review_notes"].map { |note| note.values_at("review_id", "round", "notes") }
    assert_equal [], B.response(@task, seat: @reviewer, review: second)["review_notes"]
  end

  test "an acknowledgement counts for the seat's current lease and hash only" do
    assert_equal :missing, B.acknowledgement(@task, seat: @builder)

    acknowledge(@task, @builder, "an-older-hash")
    assert_equal :changed, B.acknowledgement(@task, seat: @builder)

    acknowledge(@task, @builder, B.hash_for(@task, seat: @builder))
    assert_equal :current, B.acknowledgement(@task, seat: @builder)

    @task.update!(contract_version: @task.contract_version + 1)
    assert_equal :changed, B.acknowledgement(@task.reload, seat: @builder)
  end

  test "a fresh lease needs its own acknowledgement" do
    acknowledge(@task, @builder, B.hash_for(@task, seat: @builder))
    @scenario.append("review.failed", task: @task, subject: Review.create!(workspace_id: @task.workspace_id,
      task_id: @task.id, round: 0), actor_kind: "seat", actor_id: @reviewer.id,
      payload: { failed_criterion_ids: [], failed_rule_check_id: nil, lease_seat_id: @builder.id, wait_cause: nil })

    assert_equal :missing, B.acknowledgement(@task, seat: @builder)
  end

  test "a reviewer's lease is the review.started of its review" do
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: @reviewer)
    started = Event.where(task_id: task.id, type: "review.started").last

    assert_equal started.id, B.lease_event(task, seat: @reviewer, review: review).id
    assert_equal :missing, B.acknowledgement(task, seat: @reviewer, review: review)
    acknowledge(task, @reviewer, B.hash_for(task, seat: @reviewer, review: review), review: review)
    assert_equal :current, B.acknowledgement(task, seat: @reviewer, review: review)
  end

  # --- milestone 4: rules join the briefing (L470, L476; plan WP3) ---------

  def use_engine = Leverage::Gating.implementation = Leverage::Rules::Engine.new

  # Saves a new version of rule with fields changed, as save_rule will.
  def save(rule, **fields)
    current = @scenario.current_version(rule)
    version = RuleVersion.create!(current.attributes.except("id", "created_at").merge("version" => current.version + 1)
      .merge(fields.stringify_keys))
    rule.update!(current_version: version.version)
    version
  end

  test "the rules join the briefing with their versions: a model rule's instruction, an app rule's sentence (L470, RD-62)" do
    use_engine
    rules = @scenario.with_shipped_rules.to_h { |rule| [ rule.key, rule ] }
    acting = %w[acceptance_criteria specific_details different_provider_review].map { |key| rules.fetch(key) }
    versions = acting.map { |rule| @scenario.current_version(rule) }
    briefing = B.for(@task, seat: @builder)

    assert_matches_component("Briefing", briefing)
    assert_equal versions.map(&:id), briefing["versions"]["rule_version_ids"]
    assert_equal [
      [ acting[0].id, versions[0].id, "acceptance_criteria", "Every task needs acceptance criteria",
        "Every task needs at least 1 acceptance criterion besides the review.", false ],
      [ acting[1].id, versions[1].id, "specific_details", "Every task needs specific details", versions[1].instruction, false ],
      [ acting[2].id, versions[2].id, "different_provider_review", "A different provider reviews every task",
        "An agent on a provider that built the task may not review it.", false ]
    ], briefing["rules"].map { |rule| rule.values_at("rule_id", "rule_version_id", "key", "name", "instruction", "may_apply") }
    parts = acting.map { |rule| { "kind" => "rule", "id" => rule.id, "version" => 1 } }
    expected = Digest::SHA256.hexdigest(Leverage::Gating::CanonicalJson.dump([
      { "kind" => "brief", "id" => nil, "version" => 0 },
      { "kind" => "role_file", "id" => "builder", "version" => Leverage::VERSION },
      { "kind" => "contract", "id" => @task.id, "version" => @task.contract_version }
    ] + parts))
    assert_equal expected, briefing["hash"]
  end

  test "the hash changes when a rule in it is saved, switched or removed, and a reviewer reads the same rules" do
    use_engine
    rule = @scenario.rule(hook: "task.before_submit")
    deciding = @scenario.rule(hook: "task.before_done", scope_kind: "checker_decides")
    hashes = [ B.hash_for(@task, seat: @builder) ]
    assert_equal [ [ rule.id, false ], [ deciding.id, true ] ],
      B.for(@task, seat: @builder)["rules"].map { |row| row.values_at("rule_id", "may_apply") }

    saved = save(rule, instruction: "A made-up instruction, saved again.")
    hashes << B.hash_for(@task, seat: @builder)
    assert_equal [ saved.id, @scenario.current_version(deciding).id ], B.for(@task, seat: @builder)["versions"]["rule_version_ids"]
    assert_equal "A made-up instruction, saved again.", B.for(@task, seat: @builder)["rules"].first["instruction"]

    rule.update!(enabled: false)
    hashes << B.hash_for(@task, seat: @builder)
    assert_equal [ deciding.id ], B.for(@task, seat: @builder)["rules"].map { |row| row["rule_id"] }
    rule.update!(enabled: true)
    assert_equal hashes[1], B.hash_for(@task, seat: @builder), "the hash covers the parts' versions only"

    deciding.update!(removed_at: @scenario.database_now)
    hashes << B.hash_for(@task, seat: @builder)
    assert_equal [ rule.id ], B.for(@task, seat: @builder)["rules"].map { |row| row["rule_id"] }
    assert_equal hashes.uniq, hashes

    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: @reviewer)
    assert_equal B.for(task, seat: @scenario.seat)["rules"], B.for(task, seat: @reviewer, review: review)["rules"]
  end

  test "a builder sent back by a rule when the review has passed reads its name and reason after the reviewer's notes (RD-38)" do
    rule = @scenario.rule(hook: "task.before_done", name: "Made-up done rule")
    check = @scenario.rule_check(@task, rule: rule, result: "failed", reason: "The made-up check's reason.")
    with_notes = Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 0, verdict: "failed",
      notes: "The reviewer's notes.", reviewer_seat_id: @reviewer.id, failed_rule_check_id: check.id)
    without = Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 1, verdict: "failed",
      reviewer_seat_id: @reviewer.id, failed_rule_check_id: check.id)

    response = B.response(@task, seat: @builder)
    assert_matches_component("BriefingResponse", response)
    assert_equal [
      [ with_notes.id, "The reviewer's notes.\n\nMade-up done rule: The made-up check's reason." ],
      [ without.id, "Made-up done rule: The made-up check's reason." ]
    ], response["review_notes"].map { |note| note.values_at("review_id", "notes") }
  end
end
