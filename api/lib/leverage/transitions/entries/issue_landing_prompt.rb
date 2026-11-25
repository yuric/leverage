module Leverage
  module Transitions
    module Entries
      # Issues a prompt before a seat that connects on its own lands (UX-2).
      # The token and rendered prompt exist only in the first answer.
      class IssueLandingPrompt < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id, removed_at: nil)
          raise NotFound, "No such seat" unless @seat
        end

        def refusals(ctx)
          return [ state_refusal(nil) ] if @seat.credential_id

          guard = landed?(ctx) ? "seat_has_landed" : "seat_has_not_landed"
          [ state_refusal(nil, [ guard ]) ].compact
        end

        def perform(ctx)
          connection, address = ctx.request.params.values_at("connection", "address")
          token = Tokens.issue(:seat)
          @seat.update!(token_hash: Tokens.digest(token))

          @result = { "seat_id" => @seat.id, "connection" => connection }
          @once = { "seat_token" => token, "text" => Reads::LandingPrompt.call(address: address, token: token, connection: connection) }
        end

        private

        def landed?(ctx)
          @seat.last_polled_at.present? || Eligibility.holds_anything?(@seat, at: ctx.at) || Jobs.held(@seat, ctx.at).present?
        end
      end
    end
  end
end
