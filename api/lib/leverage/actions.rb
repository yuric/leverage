module Leverage
  module Actions
    module_function

    def create_for(_task, _inputs) = nil
    def request_all(_ctx, _task) = nil
    def approve(_ctx, _action, by:, rule_check: nil) = nil
    def stop(_ctx, _action, by:, rule_check: nil, reason: nil) = nil
    def start(_ctx, _action) = nil
    def report_done(_ctx, _action) = nil
    def mark_done(_ctx, _action) = nil
    def waive(_ctx, _action) = nil
    def withdraw_open(_ctx, _task) = nil
    def revoke_open(_ctx, _task) = nil
    def record_overturn(_ctx, _action) = nil
    def approvals_complete?(_task) = false
    def last_open?(_action) = false
    def any_started?(_task) = false
    def first_approved_open(_task) = nil
    def stopped_by_check?(_action) = false
  end
end
