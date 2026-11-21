module V1
  module Agent
    class ActionsController < BaseController
      def start = run("start_action", "start_action", ids: [ :id, :aid ])
      def done = run("report_action_done", "report_action_done", ids: [ :id, :aid ])
    end
  end
end
