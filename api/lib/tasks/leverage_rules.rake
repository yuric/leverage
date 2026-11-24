namespace :leverage do
  # Run the app's Write the shipped rules command (UI-5) for each workspace
  # after db:prepare and before the server starts. Prints one line per
  # workspace the command updated.
  #
  #   bin/rails leverage:install_shipped_rules
  desc "Install or update the shipped defaults in every workspace"
  task install_shipped_rules: :environment do
    ids = Workspace.order(:created_at, :id).pluck(:id)
    updated = 0
    ids.each do |workspace_id|
      outcome = Leverage::Timers.apply_workspace(workspace_id, "install_shipped_rules", at: Time.current)
      next unless outcome.completed?

      updated += 1
      puts "install_shipped_rules: workspace #{workspace_id}: wrote shipped defaults"
    end
    puts "install_shipped_rules: updated #{updated} of #{ids.size} workspaces"
  end
end
