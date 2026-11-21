namespace :leverage do
  # PRD L434 with Q-12; milestone 4 plan RD-2: every workspace that has no
  # rules row gets the seven shipped rules, once, through the transition
  # function: the command install_shipped_rules, as the app with no key,
  # applied by Timers.apply_workspace, the path the sweep uses for a
  # workspace timer. A workspace with any rule is left alone, so a start on
  # an installation that has its rules writes nothing. bin/docker-entrypoint
  # runs it after db:prepare and before the server starts, so no command
  # ever runs rule-free in an installation upgraded to this milestone.
  # Prints one line per workspace it wrote; ids only.
  #
  #   bin/rails leverage:install_shipped_rules
  desc "Write the shipped rules of every workspace that has none"
  task install_shipped_rules: :environment do
    ids = Workspace.where.not(id: Rule.select(:workspace_id)).order(:created_at, :id).pluck(:id)
    ids.each do |workspace_id|
      outcome = Leverage::Timers.apply_workspace(workspace_id, "install_shipped_rules", at: Time.current)
      said = outcome.completed? ? "wrote the #{Leverage::Rules::Shipped.all.size} shipped rules" : "has rules (#{outcome.refusal.code})"
      puts "install_shipped_rules: workspace #{workspace_id}: #{said}"
    end
    puts "install_shipped_rules: #{ids.size} workspaces had no rules"
  end
end
