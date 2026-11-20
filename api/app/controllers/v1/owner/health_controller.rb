module V1
  module Owner
    # GET /v1/owner/health (get_system_health): the health line (IN-33).
    # GET /v1/health stays public with status and version.
    class HealthController < ApplicationController
      include AuthenticatesOwner

      def show
        render json: Leverage::Reads::SystemHealth.call(current_caller.workspace_id)
      end
    end
  end
end
