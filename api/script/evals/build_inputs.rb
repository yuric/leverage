# Builds each eval case's job input with the same reader as claim_job
# (milestone 4 RV-3 and milestone 5 AV-3). The script writes that reader's
# rows in a transaction it rolls back. A specific-details case builds a
# Backlog task with a waiting Complete contract. An approves-actions case
# builds a Finishing task with the passing review and the action at the
# named position. Both use the shipped instruction and the selected role's
# job material (GA-11). No event is written.
#
# Only task material reaches JobInputs. {{CANARY_PATH}} in the contract
# or review becomes the path where scripts/eval_rule.sh wrote its word.
#
#   bin/rails runner script/evals/build_inputs.rb --suite DIR --canary-path PATH --out FILE [--held-out] [--mode MODE]
#
# FILE gets {"suite", "instruction_sha256", "cases": [{"id", "input"}]}, the
# cases in file order. scripts/eval_rule.sh runs it in a container that
# mounts the checkout's api/, so it runs the checkout's code.
require "digest"
require "json"
require "optparse"
require "pathname"
require "securerandom"

module EvalInputs
  CANARY = "{{CANARY_PATH}}".freeze
  RULE_KEYS = { "verdict" => "specific_details", "decision" => "orchestrator_approves_actions" }.freeze
  SPECIFIC_DETAILS = "specific-details".freeze
  DEFAULT_MODE = "orchestrator".freeze
  MODES = [ DEFAULT_MODE, "general" ].freeze

  module_function

  # The suite's cases, by file name.
  def read_cases(folder, held_out: false)
    Pathname(folder).join(held_out ? "held_out" : "cases").glob("*.json").sort.map { |path| JSON.parse(path.read) }
  end

  # The case's contract, the body of a Complete contract, with the canary
  # path in place of {{CANARY_PATH}}.
  def contract(kase, canary_path:)
    raise ArgumentError, "the canary path must be absolute, not #{canary_path.inspect}" unless canary_path.to_s.start_with?("/")

    body = kase.fetch("contract")
    raise ArgumentError, "the eval case has a goal; fold it into its details" if body.key?("goal")

    fill(body, canary_path.to_s)
  end

  # The input claim_job would hand the selected role for the case.
  def input_for(kase, canary_path:, mode: DEFAULT_MODE, kind: (kase.key?("action") ? "decision" : "verdict"),
                shipped: Leverage::Rules::Shipped.find(RULE_KEYS.fetch(kind)))
    raise ArgumentError, "unknown eval mode #{mode.inspect}" unless MODES.include?(mode)

    seat = Seat.new(role: mode) if mode == "general"
    body = contract(kase, canary_path: canary_path)
    input = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      version = rule_version(shipped)
      job = case kind
      when "verdict" then waiting_job(body, version)
      when "decision" then approval_job(kase, body, version, canary_path: canary_path.to_s)
      end
      input = Leverage::JobInputs.for(job, seat: seat)
      raise ActiveRecord::Rollback
    end
    input
  end

  # Every case's input, in file order.
  def suite(folder, canary_path:, held_out: false, mode: DEFAULT_MODE)
    bar_path = Pathname(folder).join("bar.json")
    bar = bar_path.file? ? JSON.parse(bar_path.read) : {}
    kind = bar.fetch("kind", "verdict")
    shipped = Leverage::Rules::Shipped.find(bar.fetch("rule", RULE_KEYS.fetch(kind)))
    raise ArgumentError, "#{shipped.key} has no instruction in shipped_rules.json" if shipped.instruction.nil?

    cases = read_cases(folder, held_out: held_out).map do |kase|
      input = input_for(kase, canary_path: canary_path, mode: mode, kind: kind, shipped: shipped)
      { "id" => kase.fetch("id"), "input" => input }
    end
    { "suite" => bar.fetch("suite", SPECIFIC_DETAILS), "instruction_sha256" => Digest::SHA256.hexdigest(shipped.instruction),
      "cases" => cases }
  end

  def rule_version(shipped)
    workspace = Workspace.create!
    owner = User.create!(workspace_id: workspace.id, email_address: "eval-#{SecureRandom.hex(6)}@example.invalid",
      password: SecureRandom.hex(24))
    rule = Rule.create!(workspace_id: workspace.id, key: shipped.key, enabled: true, current_version: shipped.version)
    RuleVersion.create!(workspace_id: workspace.id, rule_id: rule.id, version: shipped.version, author_kind: "owner",
      author_id: owner.id, **shipped.version_fields)
  end

  # The rows of a Complete contract waiting on the shipped rule's check
  # (trace 16, command 2), and the check's job.
  def waiting_job(body, version)
    task = Task.create!(workspace_id: version.workspace_id, title: body["title"], state: "backlog")
    pending = PendingTransition.create!(workspace_id: task.workspace_id, task_id: task.id, command: "complete_contract",
      command_key: "eval-#{SecureRandom.hex(8)}", requester_kind: "owner", requester_id: version.author_id,
      frozen_rule_version_ids: [ version.id ], state: "pending", params: body.merge("id" => task.id))
    check_job(task, version, kind: "rule_check", pending_transition_id: pending.id)
  end

  def approval_job(kase, body, version, canary_path:)
    position = kase.fetch("action").fetch("position")
    unless position.is_a?(Integer) && position.between?(1, body.fetch("actions").length)
      raise ArgumentError, "approval action position is outside the contract"
    end

    review = fill(kase.fetch("review"), canary_path)
    task = reviewed_task(body, review, version.workspace_id)
    # The case identifies a stored action by position. Its displayed text
    # comes from that same row, the way it does in a production claim.
    action = Leverage::Actions.for_task(task).find_by!(position: position)
    check_job(task, version, kind: "approval", subject_kind: "action", subject_id: action.id)
  end

  def reviewed_task(body, review, workspace_id)
    builder = Seat.create!(workspace_id: workspace_id, name: "Eval builder", provider: "codex", model: "eval-model",
      effort: "", role: "builder", strength_rank: 1)
    task = Task.create!(workspace_id: workspace_id, builder_seat_id: builder.id, state: "finishing",
      **body.slice("title", "details"))
    criteria = body.fetch("criteria").map.with_index(1) do |criterion, position|
      Criterion.create!(workspace_id: workspace_id, task_id: task.id, position: position, state: "passed",
        **criterion.slice("kind", "text"))
    end
    Leverage::Actions.create_for(task, body.fetch("actions"))
    Review.create!(workspace_id: workspace_id, task_id: task.id, round: task.round, verdict: "passed",
      handoff_note: review.fetch("handoff_note"), notes: review.fetch("review_notes"))
    Evidence.create!(workspace_id: workspace_id, criterion_id: criteria.find { |criterion| criterion.kind == "build" }.id,
      kind: "note", value: review.fetch("evidence"), attached_by_seat_id: builder.id)
    task
  end

  def check_job(task, version, kind:, **fields)
    check = RuleCheck.create!(workspace_id: task.workspace_id, task_id: task.id, rule_id: version.rule_id,
      rule_version_id: version.id, hook: version.hook, round: task.round, input_hash: SecureRandom.hex(32), **fields)
    Job.create!(workspace_id: task.workspace_id, kind: kind, task_id: task.id, target_kind: "rule_check",
      target_id: check.id, seat_role: version.checker_role, state: "queued", queued_at: Time.current, input: {},
      attempt_number: 1)
  end

  def fill(value, canary_path)
    case value
    when String then value.gsub(CANARY) { canary_path }
    when Array then value.map { |item| fill(item, canary_path) }
    when Hash then value.transform_values { |item| fill(item, canary_path) }
    else value
    end
  end

  def main(argv)
    options = { mode: DEFAULT_MODE }
    OptionParser.new do |parser|
      parser.banner = "usage: bin/rails runner script/evals/build_inputs.rb --suite DIR --canary-path PATH --out FILE " \
        "[--held-out] [--mode orchestrator|general]"
      parser.on("--suite DIR") { |value| options[:suite] = value }
      parser.on("--canary-path PATH") { |value| options[:canary_path] = value }
      parser.on("--out FILE") { |value| options[:out] = value }
      parser.on("--held-out") { options[:held_out] = true }
      parser.on("--mode MODE", MODES) { |value| options[:mode] = value }
    end.parse!(argv)
    missing = %i[suite canary_path out].reject { |key| options[key] }
    abort("build_inputs: missing --#{missing.first.to_s.tr("_", "-")}") if missing.any?

    built = suite(options[:suite], canary_path: options[:canary_path], held_out: options[:held_out], mode: options[:mode])
    abort("build_inputs: no case in #{options[:suite]}") if built.fetch("cases").empty?
    File.write(options[:out], JSON.pretty_generate(built) + "\n")
    $stdout.puts "build_inputs: #{built.fetch("cases").size} inputs written"
  end
end

EvalInputs.main(ARGV) if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
