module V1
  module Owner
    # POST /v1/owner/tools/{provider}/install (install_tool): install a
    # provider's tool on the Mac, after the owner confirmed (IN-23, PV-5).
    # The helper does the work; the answer carries the request to follow.
    class ToolsController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      def install
        body = checked_body("install_tool")
        run_command("install_tool", params: body.merge("provider" => provider))
      end

      private

      # A provider the contract lists names a tool; anything else names nothing.
      def provider
        value = params[:provider].to_s
        providers = Leverage::Contract.openapi.dig("components", "parameters", "PathProvider", "schema", "enum")
        raise NotFound, "No such provider" unless providers.include?(value)

        value
      end
    end
  end
end
