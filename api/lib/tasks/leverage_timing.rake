namespace :leverage do
  # The timing questions of PRD L315 to L318 (milestone 4 plan §2.1, §5.2
  # step 2): for every rule of every workspace, or of the one WORKSPACE_ID
  # names, what Leverage::Reads::RuleTiming answers: its rows counted by
  # result, its attempts' queue and run time, how long it held tasks up, its
  # tokens and spend, and its overrides. Read-only. Keys, ids and figures
  # only: a rule's name and instruction and a check's reason are the
  # owner's content and are not printed.
  #
  #   bin/rails leverage:rule_timing                     every workspace
  #   WORKSPACE_ID=<uuid> bin/rails leverage:rule_timing one workspace
  desc "Print each rule's checks, queue and run time, time it held tasks up, tokens and spend"
  task rule_timing: :environment do
    id = ENV["WORKSPACE_ID"].presence
    abort "rule_timing: no such workspace #{id}" if id && !Workspace.exists?(id: id)

    seconds = ->(value) { value.nil? ? "-" : format("%.1f s", value) }
    ids = id ? [ id ] : Workspace.order(:created_at, :id).pluck(:id)
    ids.each do |workspace_id|
      rows = Leverage::Reads::RuleTiming.call(workspace_id)
      puts "rule_timing: workspace #{workspace_id}: #{rows.size} rules"
      rows.each do |row|
        results = row.fetch("results").map { |result, count| "#{result} #{count}" }.join(", ")
        puts "  rule #{row.fetch("rule_id")} #{row.fetch("key")}#{" (removed)" if row.fetch("removed")}: " \
             "#{row.fetch("results").values.sum} checks (#{results.presence || "none"}), " \
             "#{row.fetch("attempts")} attempts, queue #{seconds.(row.fetch("queue_seconds"))} " \
             "(average #{seconds.(row.fetch("average_queue_seconds"))}), run #{seconds.(row.fetch("run_seconds"))} " \
             "(average #{seconds.(row.fetch("average_run_seconds"))}), held tasks up #{seconds.(row.fetch("held_up_seconds"))}, " \
             "#{row.fetch("tokens")} tokens, spend #{format("%.6f", row.fetch("spend"))} USD as reported, " \
             "#{row.fetch("overrides")} overrides"
      end
    end
  end
end
