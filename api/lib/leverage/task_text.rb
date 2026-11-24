module Leverage
  # The task row is migrated in the database (UI-1). Older snapshots of
  # task text still in a pending request, job or command receipt use the
  # same fold when read or applied.
  module TaskText
    module_function

    def fold_previous_goal(fields, title: fields["title"])
      return fields unless fields.key?("goal")

      fold = Contract.load("goal_fold.json")
      trimmed = Regexp.escape(fold.fetch("trimmed"))
      edges = /\A[#{trimmed}]+|[#{trimmed}]+\z/
      goal = fields["goal"].to_s.gsub(edges, "")
      details = fields["details"]
      unless goal.empty? || goal == title.to_s.gsub(edges, "")
        details = details.to_s.gsub(edges, "").empty? ? goal : [ goal, details ].join(fold.fetch("separator"))
      end
      fields.except("goal").merge("details" => details)
    end
  end
end
