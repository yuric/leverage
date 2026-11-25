module Leverage
  module Transitions
    module Entries
      # connect_seat (PRD L590-L591, L803; milestone 2 plan §2.1, IN-11,
      # IN-29, IN-30, SC-10, SC-11): makes the seat and writes
      # seat.connected. The SM-42 side events (No reviewer is eligible) are
      # not written in this milestone (SC-11).
      #
      # With credential_id, a seat the app runs: an API credential is 422
      # invalid (TK-4). An unknown or unfinished login is 404. The provider is the
      # login's, and naming another is 422 invalid. The seat has no token
      # until the helper picks up its start (issue_seat_token); it is
      # stopped, wanted running, and start_seat is queued (IN-30).
      #
      # Without, a seat that connects on its own: it must name its provider
      # (seats.provider is required). The owner issues its token separately
      # through issue_landing_prompt (GA-13). Both ways return only the seat id.
      #
      # Any registry seat role: the planner and the
      # orchestrator arrived with rules (milestone 4 plan §0.1 fact 12,
      # RV-5), and are connected exactly as a builder is, on any login, with
      # or without a model from the login's catalog. A Prompt seat
      # reports its own model and effort. An empty or null model or effort
      # is stored as "". The strength rank defaults to 1 (AP-24), and all
      # permissions default on (UX-10).
      #
      # Params: "name", "role", "provider", "model", "effort",
      # "strength_rank", "credential_id", "permissions".
      class ConnectSeat < Entry
        ROLES = Contract.list("seat_roles").freeze

        def load(ctx)
          params = ctx.request.params
          @name, @role, @provider = params.values_at("name", "role", "provider")
          raise Invalid, "A seat needs a name" unless @name.is_a?(String) && !@name.empty?
          raise Invalid, "A seat's role is one of #{ROLES.join(", ")}" unless ROLES.include?(@role)

          rank = params["strength_rank"]
          rank = 1 if rank.nil?
          unless rank.is_a?(Numeric) && (1..3).cover?(rank) && rank == rank.to_i
            raise Invalid, "A seat's strength rank must be from 1 to 3"
          end
          @strength_rank = rank.to_i

          @model, @effort = params.values_at("model", "effort").map(&:to_s)
          @permissions = params.key?("permissions") ? Permissions.columns(params.fetch("permissions")) : {}
          params["credential_id"] ? load_login(ctx, params["credential_id"]) : load_own
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          seat = Seat.create!(workspace_id: ctx.workspace.id, name: @name, role: @role, provider: @provider,
            model: @model, effort: @effort, strength_rank: @strength_rank, credential_id: @credential&.id, **@permissions)
          ctx.emit("seat.connected", subject: seat, payload: {})
          SeatRuns.connected(ctx, seat)
          @result = { "seat_id" => seat.id }
        end

        private

        def load_login(ctx, credential_id)
          @credential = Credential.find_by(id: credential_id, workspace_id: ctx.workspace.id)
          raise Invalid, "A seat's credential must be a login" if @credential && @credential.kind != "login"
          raise NotFound, "No such login" unless @credential&.last_verified_at
          raise Invalid, "The seat's provider is its login's" if @provider && @provider != @credential.provider

          @provider = @credential.provider
          problem = ModelCatalog.problem(provider: @provider, model: @model, effort: @effort, native: true)
          raise Invalid, problem if problem
        end

        def load_own
          unless ModelCatalog.provider?(@provider)
            raise Invalid, "A seat that connects on its own names a login provider"
          end
          return if @model.empty? && @effort.empty?

          raise Invalid, "An agent that connects by prompt reports its own model and effort"
        end
      end
    end
  end
end
