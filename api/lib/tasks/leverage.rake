namespace :leverage do
  # PRD L896 and L921: a log passes when the replay rebuilds every replay
  # column from it (Leverage::Replay) and every command in it wrote the
  # events its state-table row names, with steps that partition each task's
  # life (Leverage::LogAudit). Prints one line per workspace and every
  # finding, and exits 1 when anything is found. Ids only: no content, no
  # secret.
  #
  #   bin/rails leverage:verify_log                     every workspace
  #   WORKSPACE_ID=<uuid> bin/rails leverage:verify_log one workspace
  desc "Replay the event log and audit each command against the state table"
  task verify_log: :environment do
    id = ENV["WORKSPACE_ID"].presence
    ids = id ? [ id ] : Workspace.order(:created_at, :id).pluck(:id)
    abort "verify_log: no such workspace #{id}" if id && !Workspace.exists?(id: id)

    failed = false
    ids.each do |workspace_id|
      events = Event.where(workspace_id: workspace_id).count
      begin
        replay = Leverage::Replay.diff(workspace_id)
        audit = Leverage::LogAudit.call(workspace_id)
      rescue Leverage::Replay::Unsupported, Leverage::Steps::Unsupported => error
        replay = [ "the log holds an event this version cannot replay: #{error.message}" ]
        audit = []
      end
      puts "verify_log: workspace #{workspace_id}: #{events} events, " \
           "replay #{replay.empty? ? "ok" : "#{replay.size} findings"}, audit #{audit.empty? ? "ok" : "#{audit.size} findings"}"
      (replay + audit).each { |line| puts "  #{line}" }
      failed ||= replay.any? || audit.any?
    end
    abort "verify_log: the log does not pass" if failed
    puts "verify_log: #{ids.size} workspaces pass"
  end

  # Recovery times (milestone 3 plan HE-18): written by WP9.
  desc "Print every recovery time, against the ceiling when one is set"
  task recovery_times: :environment do
  end
end
