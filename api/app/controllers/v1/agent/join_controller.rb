module V1
  module Agent
    # GET /v1/join reads instructions without polling for work.
    class JoinController < ApplicationController
      include AuthenticatesSeat

      def show
        render json: Leverage::Reads::JoinInstructions.call(seat: current_seat, address: request.base_url,
          connection: request.query_parameters["connection"])
      end
    end
  end
end
