module V1
  module Agent
    class SeatsController < BaseController
      def report_model = run("report_model", "change_seat")
    end
  end
end
