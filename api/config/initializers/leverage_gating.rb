# The gating every command's hook goes to: in milestone 2 a workspace has
# no rules, so Leverage::Gating::NoRules (milestone 2 plan EN-5). Set on
# every prepare, so a code reload in development sets it again.
Rails.application.config.to_prepare do
  Leverage::Gating.implementation = Leverage::Gating::NoRules.new
end
