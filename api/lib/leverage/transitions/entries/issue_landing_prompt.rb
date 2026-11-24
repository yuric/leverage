module Leverage
  module Transitions
    module Entries
      # Issues a new prompt for a seat that connects on its own (GA-13,
      # GA-17). The token and rendered prompt exist only in the first answer.
      class IssueLandingPrompt < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id, removed_at: nil)
          raise NotFound, "No such seat" unless @seat
        end

        def refusals(_ctx)
          return [ Refusal.new(code: "invalid_state") ] if @seat.credential_id

          [ state_refusal(nil) ].compact
        end

        def perform(ctx)
          connection, address = ctx.request.params.values_at("connection", "address")
          token = Tokens.issue(:seat)
          @seat.update!(token_hash: Tokens.digest(token))
          SeatRuns.release_for_new_prompt(ctx, @seat)

          @result = { "seat_id" => @seat.id, "connection" => connection }
          @once = { "seat_token" => token, "text" => Reads::LandingPrompt.call(address: address, token: token, connection: connection) }
        end
      end
    end
  end
end
