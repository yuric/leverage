module V1
  # GET /v1/health: tells a client that the API is up and which version it runs.
  class HealthController < ApplicationController
    def show
      render json: { status: "ok", version: Leverage::VERSION }
    end
  end
end
