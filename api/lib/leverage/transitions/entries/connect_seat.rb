module Leverage
  module Transitions
    module Entries
      # connect_seat (PRD L590-L591, L803; milestone 2 plan §2.1, IN-11,
      # IN-29, IN-30, SC-10, SC-11): makes the seat and writes
      # seat.connected. The SM-42 side events (No reviewer is eligible) are
      # not written in this milestone (SC-11).
      #
      # With credential_id, a seat the app runs: the login must be an added
      # one (its checks passed, IN-24), else 404; the provider is the
      # login's, and naming another is 422 invalid. The seat has no token
      # until the helper picks up its start (issue_seat_token); it is
      # stopped, wanted running, and start_seat is queued (IN-30). The
      # answer is SeatConnected with seat_token null.
      #
      # Without, a seat that connects on its own: it must name its provider
      # (seats.provider is required), and its token is returned once.
      #
      # Builder and reviewer only in this milestone; planner and
      # orchestrator seats arrive with rules (milestone 4) and are 422
      # invalid. An empty or null model or effort is stored as "" (the
      # tool's default, IN-29); the strength rank is 1 unless sent.
      #
      # Params: "name", "role", "provider", "model", "effort",
      # "strength_rank", "credential_id".
      class ConnectSeat < Entry
        ROLES = %w[builder reviewer].freeze

        def load(ctx)
          params = ctx.request.params
          @name, @role, @provider = params.values_at("name", "role", "provider")
          raise Invalid, "A seat needs a name" unless @name.is_a?(String) && !@name.empty?
          raise Invalid, "Connect offers builder and reviewer seats in this milestone" unless ROLES.include?(@role)

          params["credential_id"] ? load_login(ctx, params["credential_id"]) : load_own
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          token = @credential ? nil : Tokens.issue(:seat)
          seat = Seat.create!(workspace_id: ctx.workspace.id, name: @name, role: @role, provider: @provider,
            model: ctx.request.params["model"].to_s, effort: ctx.request.params["effort"].to_s,
            strength_rank: ctx.request.params["strength_rank"] || 1, credential_id: @credential&.id,
            token_hash: token && Tokens.digest(token))
          ctx.emit("seat.connected", subject: seat, payload: {})
          SeatRuns.connected(ctx, seat)
          @result = { "seat_id" => seat.id }
          @once = { "seat_token" => token }
        end

        private

        def load_login(ctx, credential_id)
          @credential = Credential.where.not(last_verified_at: nil)
            .find_by(id: credential_id, workspace_id: ctx.workspace.id, kind: "login")
          raise NotFound, "No such login" unless @credential
          raise Invalid, "The seat's provider is its login's" if @provider && @provider != @credential.provider

          @provider = @credential.provider
        end

        def load_own
          known = Contract.registry.fetch("credential_providers").any? { |entry| entry.fetch("provider") == @provider }
          raise Invalid, "A seat that connects on its own names its provider" unless known
        end
      end
    end
  end
end
