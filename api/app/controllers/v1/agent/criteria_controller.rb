module V1
  module Agent
    # The criterion calls (milestone 2 plan §2.1).
    class CriteriaController < BaseController
      def start = run("start_criterion", "start_criterion", ids: [ :id, :cid ])
      def pass = run("pass_criterion", "pass_criterion", ids: [ :id, :cid ])
    end
  end
end
