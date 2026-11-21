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

      payload = Event.where(workspace_id: credential.workspace_id, subject_kind: "credential",
        subject_id: credential.id, type: "credential.limit_reached").order(seq: :desc).pick(:payload)
      window = payload&.fetch("window", nil)
      relevant = reading.figures.select { |figure| figure["kind"] == "limit" && (window.nil? || figure["window"] == window) }
      relevant.any? && relevant.all? { |figure| figure["percent_used"] && figure["percent_used"] < 100 }
    end
  end
end
