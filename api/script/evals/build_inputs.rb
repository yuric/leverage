# The eval suite's job inputs (milestone 4 plan RV-3, RV-6): each case of a
# suite folder (evals/specific-details/) as the RuleCheckJobInput an
# orchestrator would be handed for it, built on the production path outside
# the server. For each case it writes, in a transaction it then rolls back,
# the rows claim_job reads: a workspace, its owner, the shipped rule
# "Every task needs specific details" at version 1 (the instruction of
# api/contract/shipped_rules.json), a Backlog task, the owner's Complete
# contract with the case's contract waiting as a pending transition, the
# rule's check and its job; and asks Leverage::JobInputs for the job's
# input, which carries the orchestrator's role file. Nothing is kept and
# no event is written.
#
# A case is {id, label, category, why, contract}; only its contract reaches
# the input. {{CANARY_PATH}} in the contract becomes the canary path given,
# the file scripts/eval_rule.sh writes the run's made-up word into.
#
#   bin/rails runner script/evals/build_inputs.rb --suite DIR --canary-path PATH --out FILE
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
  RULE_KEY = "specific_details".freeze

  module_function

  # The suite's cases, by file name.
  def read_cases(folder)
    Pathname(folder).join("cases").glob("*.json").sort.map { |path| JSON.parse(path.read) }
  end

  # The case's contract, the body of a Complete contract, with the canary
  # path in place of {{CANARY_PATH}}.
  def contract(kase, canary_path:)
    raise ArgumentError, "the canary path must be absolute, not #{canary_path.inspect}" unless canary_path.to_s.start_with?("/")

    fill(kase.fetch("contract"), canary_path.to_s)
  end

  # The RuleCheckJobInput claim_job would hand an orchestrator for the case.
  def input_for(kase, canary_path:)
    body = contract(kase, canary_path: canary_path)
    input = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      input = Leverage::JobInputs.for(waiting_job(body))
      raise ActiveRecord::Rollback
    end
    input
  end

  # Every case's input, in file order.
  def suite(folder, canary_path:)
    instruction = Leverage::Rules::Shipped.find(RULE_KEY).instruction
    raise ArgumentError, "#{RULE_KEY} has no instruction in shipped_rules.json" if instruction.nil?

    { "suite" => "specific-details", "instruction_sha256" => Digest::SHA256.hexdigest(instruction),
      "cases" => read_cases(folder).map { |kase| { "id" => kase.fetch("id"), "input" => input_for(kase, canary_path: canary_path) } } }
  end

  # The rows of a Complete contract waiting on the shipped rule's check, as
  # the gate leaves them (trace 16 command 2), and the check's job: what
  # JobInputs reads. Every value but the contract is made up for the case.
  def waiting_job(body)
    workspace = Workspace.create!
    owner = User.create!(workspace_id: workspace.id, email_address: "eval-#{SecureRandom.hex(6)}@example.invalid",
      password: SecureRandom.hex(24))
    shipped = Leverage::Rules::Shipped.find(RULE_KEY)
    rule = Rule.create!(workspace_id: workspace.id, key: RULE_KEY, enabled: true, current_version: 1)
    version = RuleVersion.create!(workspace_id: workspace.id, rule_id: rule.id, version: 1, author_kind: "owner",
      author_id: owner.id, **shipped.version_fields)
    task = Task.create!(workspace_id: workspace.id, title: body["title"], state: "backlog")
    pending = PendingTransition.create!(workspace_id: workspace.id, task_id: task.id, command: "complete_contract",
      command_key: "eval-#{SecureRandom.hex(8)}", requester_kind: "owner", requester_id: owner.id,
      frozen_rule_version_ids: [ version.id ], state: "pending", params: body.merge("id" => task.id))
    check = RuleCheck.create!(workspace_id: workspace.id, task_id: task.id, rule_id: rule.id, rule_version_id: version.id,
      hook: version.hook, round: task.round, input_hash: SecureRandom.hex(32), pending_transition_id: pending.id)
    Job.create!(workspace_id: workspace.id, kind: "rule_check", task_id: task.id, target_kind: "rule_check",
      target_id: check.id, seat_role: version.checker_role, state: "queued", queued_at: Time.current, input: {},
      attempt_number: 1)
  end

  def fill(value, canary_path)
    case value
    when String then value.gsub(CANARY, canary_path)
    when Array then value.map { |item| fill(item, canary_path) }
    when Hash then value.transform_values { |item| fill(item, canary_path) }
    else value
    end
  end

  def main(argv)
    options = {}
    OptionParser.new do |parser|
      parser.banner = "usage: bin/rails runner script/evals/build_inputs.rb --suite DIR --canary-path PATH --out FILE"
      parser.on("--suite DIR") { |value| options[:suite] = value }
      parser.on("--canary-path PATH") { |value| options[:canary_path] = value }
      parser.on("--out FILE") { |value| options[:out] = value }
    end.parse!(argv)
    missing = %i[suite canary_path out].reject { |key| options[key] }
    abort("build_inputs: missing --#{missing.first.to_s.tr("_", "-")}") if missing.any?

    built = suite(options[:suite], canary_path: options[:canary_path])
    abort("build_inputs: no case in #{options[:suite]}") if built.fetch("cases").empty?
    File.write(options[:out], JSON.pretty_generate(built) + "\n")
    $stdout.puts "build_inputs: #{built.fetch("cases").size} inputs written"
  end
end

EvalInputs.main(ARGV) if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
