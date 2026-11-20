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

  # Recovery times (PRD L703, test 11; milestone 3 plan HE-17, HE-18): prints
  # every recovery time of every workspace, or of the one WORKSPACE_ID
  # names, as Leverage::Reads::RecoveryTimes computes it from the log. The
  # bar is CEILING_SECONDS when that is set, else the workspace's recovery
  # time ceiling, else none. With a bar, each interval is printed beside it
  # and the task exits 1 when a closed one is longer; with none, it says so
  # and compares nothing. OPEN=fail also exits 1 when one is still open. A
  # start whose task was done or cancelled first is "not recovered" and has
  # no length to compare. Ids and times only: no content, no secret.
  #
  #   bin/rails leverage:recovery_times
  #   CEILING_SECONDS=900 OPEN=fail bin/rails leverage:recovery_times
  desc "Print every recovery time, against the ceiling when one is set"
  task recovery_times: :environment do
    id = ENV["WORKSPACE_ID"].presence
    abort "recovery_times: no such workspace #{id}" if id && !Workspace.exists?(id: id)
    given = ENV["CEILING_SECONDS"].presence
    given = Integer(given, 10) if given
    open_fails = ENV["OPEN"] == "fail"

    failed = false
    scope = id ? Workspace.where(id: id) : Workspace.order(:created_at, :id)
    scope.pluck(:id, :recovery_time_ceiling_seconds).each do |workspace_id, ceiling|
      bar = given || ceiling
      list = Leverage::Reads::RecoveryTimes.call(workspace_id)
      against = bar ? "bar #{bar} s#{" (CEILING_SECONDS)" if given}" : "no recovery time ceiling is set, so nothing is compared"
      puts "recovery_times: workspace #{workspace_id}: #{list.size} recovery times; #{against}"
      list.each do |item|
        seconds = item.fetch("seconds")
        status = case item.fetch("ended_by")
        when nil then "open, #{seconds} s so far"
        when "not_recovered" then "not recovered (the task was done or cancelled first)"
        else "#{seconds} s, ended by #{item.fetch("ended_by")}"
        end
        longer = bar && item.fetch("ended_at") && seconds > bar
        verdict = bar && item.fetch("ended_at") ? ", bar #{bar} s: #{longer ? "longer" : "within"}" : ""
        puts "  #{item.fetch("kind")} of credential #{item.fetch("credential_id")} " \
             "#{item.fetch("review_id") ? "on review #{item.fetch("review_id")}" : "on build work"} " \
             "at #{item.fetch("started_at")}: #{status}#{verdict}"
        failed ||= longer
        failed ||= open_fails && item.fetch("ended_by").nil?
      end
    end
    abort "recovery_times: a recovery time is longer than the bar, or open with OPEN=fail" if failed
    puts "recovery_times: pass"
  end
end
