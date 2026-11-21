module Leverage
  module Transitions
    module Entries
      # Reorder records every changed position before reconsidering held tasks
      # with the new candidates (CR-28, CR-30).
      class ReorderCredentials < Entry
        def load(ctx)
          @order = CredentialOrder.new(ctx.workspace.id)
          @ids = ctx.request.params["order"]
          unless @ids.is_a?(Array) && @order.exactly_the_added?(@ids)
            raise Invalid, "The order must list every added credential once"
          end
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          changed = @order.apply(@ids)
          return if changed.empty?

          last_change = nil
          changed.each do |credential|
            last_change = ctx.emit("credential.order_changed", subject: credential, payload: {})
          end
          Handoff.reevaluate(ctx, cause: last_change)
        end
      end
    end
  end
end
