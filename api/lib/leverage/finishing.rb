module Leverage
  module Finishing
    module_function

    def settle(_ctx, _task, by:) = nil
    def reenter_action(_ctx, _action, _trigger) = nil
    def after_command(_ctx) = nil
    def builder_free?(_task) = false
    def builder_holds_task?(_task) = false
    def waiting_for(_seat) = []
    def lose_builder(_ctx, _task, cause:) = nil
  end
end
