module V1
  module Owner
    # GET /v1/owner/board (get_board): the Kanban read (MA-20, MA-29).
    class BoardController < ApplicationController
      include AuthenticatesOwner

      def show
        render json: Leverage::Reads::Board.call(current_caller.workspace_id)
      end
    end
  end
end
