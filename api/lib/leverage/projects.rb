module Leverage
  module Projects
    module_function

    def create(_ctx, name:, goal: nil, budget: nil) = nil
    def edit_brief(_ctx, _project, entries:) = nil
    def pause(_ctx, _project, by:) = nil
    def resume(_ctx, _project) = nil
    def change_budget(_ctx, _project, budget:) = nil
    def hold_if_paused(_ctx, _task) = nil
    def release_from(_ctx, _task, _project) = nil
  end
end
