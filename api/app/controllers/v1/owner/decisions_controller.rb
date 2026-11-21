module V1
  module Owner
    class DecisionsController < ApplicationController
      include AuthenticatesOwner

      def index
        render json: Leverage::Reads::Decisions.call(current_caller.workspace_id)
      end
    end
  end
end
