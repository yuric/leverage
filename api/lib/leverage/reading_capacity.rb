module Leverage
  # Whether the helper's reading shows room after a credential met a
  # limit (PRD, Handoff, CR-14). The reading uses the command's storage
  # time for the current limit and the helper's observation time for what
  # happened at the provider.
  module ReadingCapacity
    module_function

    def shown?(credential, reading)
      return false unless credential.limited?(reading.created_at)
      return false unless reading.state == "ok" && reading.observed_at > credential.limited_since

      refusals = Event.where(workspace_id: credential.workspace_id, subject_kind: "credential", subject_id: credential.id,
        type: "credential.limit_reached", effective_at: credential.limited_since..)
      last_by_window = refusals.group(Arel.sql("payload->>'window'")).maximum(:effective_at)
      return false if last_by_window.values.any? { |at| reading.observed_at <= at }

      windows = last_by_window.keys
      limits = reading.figures.select { |figure| figure["kind"] == "limit" }
      return false unless (windows.compact - limits.pluck("window")).empty?

      limits.select! { |figure| windows.include?(figure["window"]) } unless windows.empty? || windows.include?(nil)
      limits.any? && limits.all? { |figure| figure["percent_used"] && figure["percent_used"] < 100 }
    end
  end
end
