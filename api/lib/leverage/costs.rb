module Leverage
  # Records spend under the workspace lock. Reviews and seats' own reports
  # count against the task and its project. Jobs count against the project
  # only (AP-10). A seat's own report has no event subject.
  module Costs
    module_function

    def report(_ctx, task:, subject:, tokens:, spend:) = nil

    def cap_changed(_ctx, _task) = nil
  end
end
