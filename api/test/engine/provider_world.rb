# A Gating::StandIn world with the provider rule (milestone 4 plan WP9,
# "red, against Gating::StandIn worlds, whose answers stand for the
# engine's"): the shipped policy "A different provider reviews every task"
# at review.assign, on when a rule id is given, and nothing else.
#
# - built_by: {task_id => [provider]} as StandIn takes it; when it is not
#   given, the providers that built a task are read from the log as PRD
#   L451 says (task.claimed's credential, a builder's credential.switched,
#   a seat that claimed with no credential), so a world follows the
#   commands a test sends. WP3's rules/provider_record.rb is the real
#   reading; this one stands in for it.
# - At review.assign the rule plans an applied row with effect refused
#   only for a seat whose account (its run's credential, or its own
#   provider for a seat that connects on its own: RD-50) the rule refuses,
#   and no row otherwise (RC-15). A policy there never makes a command
#   wait, so nothing is frozen when nothing is planned: Transitions::Gate
#   as milestone 2 left it refuses to apply any planned field.
class ProviderWorld < Leverage::Gating::StandIn
  HOOK = "review.assign".freeze

  # rule_id: nil is a world with the rule off.
  def initialize(rule_id: SecureRandom.uuid, version_id: SecureRandom.uuid, built_by: nil, **world)
    rules = []
    if rule_id
      rules << { id: rule_id, version_id: version_id, version: 1, hook: HOOK, kind: "policy", checker: "app",
                 on_fail: nil, route: nil, enabled: true, scope: "covers", effect: nil }
    end
    super(rules: rules, built_by: built_by || {}, **world)
    @from_log = built_by.nil?
  end

  # The world for a Rule row of the workspace (Scenario#with_shipped_rules),
  # on when the row is.
  def self.for(rule, **world)
    version = RuleVersion.find_by!(rule_id: rule.id, version: rule.current_version)
    new(rule_id: (rule.id if rule.enabled && rule.removed_at.nil?), version_id: version.id, **world)
  end

  def built_by_providers(task_id:)
    return super unless @from_log

    built_providers(task_id).map { |provider| group(provider) }.uniq
  end

  # No other hook has a rule in this world, so it plans nothing there (and
  # needs no hashed inputs: the gated entries give theirs from WP4 on).
  def evaluate(request)
    return nothing unless request.hook == HOOK

    rule = @rules.find { |candidate| candidate[:hook] == HOOK && candidate[:enabled] }
    seat = Seat.find(request.subject_id)
    refused = rule && !provider_allowed?(task_id: request.task_id, provider: account_provider(seat))
    input_hash = Leverage::Gating.input_hash(hook: request.hook, inputs: request.inputs)
    checks = refused ? [ check(rule, request, input_hash, result: "applied", effect: "refused") ] : []
    effects = refused ? [ Leverage::Gating::Effect.new(rule_id: rule[:id], hook: HOOK, effect: "refused") ] : []
    Leverage::Gating::Evaluation.new(outcome: :completed, frozen_rule_version_ids: refused ? [ rule[:version_id] ] : [],
      checks: checks, jobs: [], failures: [], warnings: [], effects: effects, holds_to_open: [])
  end

  private

  def nothing
    Leverage::Gating::Evaluation.new(outcome: :completed, frozen_rule_version_ids: [], checks: [], jobs: [], failures: [],
      warnings: [], effects: [], holds_to_open: [])
  end

  def account_provider(seat)
    return seat.provider unless seat.credential_id

    Credential.find(Leverage::SeatRuns.run_credential_id(seat)).provider
  end

  def built_providers(task_id)
    events = Event.where(task_id: task_id, type: %w[task.claimed credential.switched]).order(:seq).to_a
    events.filter_map do |event|
      payload = event.payload
      next if event.type == "credential.switched" && (payload["review_id"] || payload["job_id"])

      credential_id = event.type == "task.claimed" ? payload["credential_id"] : event.subject_id
      credential_id ? Credential.find(credential_id).provider : Seat.find(payload["seat_id"]).provider
    end
  end

  def group(provider)
    Leverage::Contract.registry.fetch("credential_providers").find { |entry| entry["provider"] == provider }
      .fetch("provider_group")
  end
end
