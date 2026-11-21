# The gating every command's hook goes to: the rules engine (milestone 4
# plan §2.1, RE-1, ADR 0011), which decides from the workspace's rule
# rows and, with none, answers as milestone 2's rule-free gating did
# (RT-2). Set on every prepare, so a code reload in development sets it
# again.
Rails.application.config.to_prepare do
  Leverage::Gating.implementation = Leverage::Rules::Engine.new
end
