namespace :leverage do
  # DB-53, IM-6: every workspace with no Imaginarium project gets one, once,
  # through the transition function: the command install_imaginarium_project,
  # as the app with no key, applied by Timers.apply_workspace as
  # install_shipped_rules is. A workspace that has one is left alone.
  # bin/docker-entrypoint runs it after install_shipped_rules and before the
  # server starts. Prints one line per workspace it wrote; ids only.
  #
  #   bin/rails leverage:install_imaginarium_project
  desc "Create the Imaginarium project of every workspace that has none"
  task install_imaginarium_project: :environment do
    ids = Workspace.where(imaginarium_project_id: nil).order(:created_at, :id).pluck(:id)
    ids.each do |workspace_id|
      outcome = Leverage::Timers.apply_workspace(workspace_id, "install_imaginarium_project", at: Time.current)
      said = outcome.completed? ? "wrote the project" : "has one (#{outcome.refusal.code})"
      puts "install_imaginarium_project: workspace #{workspace_id}: #{said}"
    end
    puts "install_imaginarium_project: #{ids.size} workspaces had no Imaginarium project"
  end
end
