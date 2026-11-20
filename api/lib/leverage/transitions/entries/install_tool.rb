module Leverage
  module Transitions
    module Entries
      # install_tool (PRD L605; milestone 2 plan IN-23, PV-5): after the
      # owner confirmed what will be installed and from where, queues an
      # install_tool request with the provider as params, and writes no
      # event. Only a login provider has a tool; an API provider, or an
      # install the owner did not confirm, is 422 invalid.
      #
      # Params: "provider" (the path's), "confirmed".
      class InstallTool < Entry
        def load(ctx)
          @provider = ctx.request.params["provider"]
          raise Invalid, "The owner confirms an install first" unless ctx.request.params["confirmed"] == true

          login = Contract.registry.fetch("credential_providers")
            .any? { |entry| entry.fetch("provider") == @provider && entry.fetch("kind") == "login" }
          raise Invalid, "#{@provider.inspect} has no tool to install" unless login
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          request = SeatRuns.queue(ctx, "install_tool", params: { "provider" => @provider })
          @result = { "helper_request_id" => request.id }
        end
      end
    end
  end
end
