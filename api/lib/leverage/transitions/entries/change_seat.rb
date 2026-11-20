module Leverage
  module Transitions
    module Entries
      # change_seat (PRD L148, L258; milestone 3 plan HE-27, HE-10, HM-51):
      # only the fields the request sets change (ChangeSeatRequest), and
      # seat.changed is written.
      #
      # - name, model, effort, strength rank apply at once; the next run
      #   uses them. A null model or effort is "", the tool's default, and a
      #   null rank is 1, the seats' default (IN-29).
      # - role: builder or reviewer (planner and orchestrator are 422
      #   invalid until milestone 4, as in connect_seat); a change of role is
      #   invalid_state while the seat holds a task or a review.
      # - credential_id: for a seat the app runs only (a seat that connects
      #   on its own has no login: 422 invalid). The login must be an added
      #   login of the workspace (404 for an unknown id, 422 invalid for an
      #   API token or one whose add is still running), and it cannot be
      #   emptied (422 invalid). It brings its provider and applies from the
      #   seat's next claim: the run is not touched here (HD-4 moves it). A
      #   task the seat holds with an open credential hold is looked at
      #   again (Handoff.reevaluate, caused by seat.changed, HE-10).
      # - enabled false: wanted_running is cleared and, for a seat the app
      #   runs, stop_seat is queued; a Working task the seat holds is
      #   released to Ready with seat_disabled, caused by seat.changed
      #   (SeatRuns.release_working_task), and its seat-bound holds close
      #   (Holds.close_seat_bound, with HE-35's wait_cause). A review the
      #   seat holds is released when its run is reported stopped (IF-21).
      #   enabled true starts nothing: the owner chooses Start.
      #
      # The row's other side events need Finishing (action_unconfirmed,
      # milestone 5), checks and jobs (milestone 4) or No reviewer is
      # eligible (SM-42, milestone 4) and are not written.
      #
      # A request that changes no field (an empty body, or every field set
      # to what it is) completes with no event and changes nothing.
      #
      # A removed or unknown seat is 404. Result: helper_request_id, the
      # stop_seat request when one was queued, else null.
      #
      # Params: id (the seat), and the ChangeSeatRequest body.
      class ChangeSeat < Entry
        ROLES = %w[builder reviewer].freeze
        CREDENTIAL_HOLDS = %w[credential_limit credential_signed_out].freeze

        def load(ctx)
          @params = ctx.request.params
          @seat = Seat.find_by(id: @params["id"], workspace_id: ctx.workspace.id, removed_at: nil)
          raise NotFound, "No such seat" unless @seat

          if @params.key?("name") && !(@params["name"].is_a?(String) && !@params["name"].empty?)
            raise Invalid, "A seat needs a name"
          end
          if @params.key?("role") && !ROLES.include?(@params["role"])
            raise Invalid, "Builder and reviewer seats only in this milestone"
          end

          load_login(ctx) if @params.key?("credential_id")
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if role_change_refused?
          causes.compact
        end

        def perform(ctx)
          turning_off = @params["enabled"] == false && @seat.enabled
          login_changes = @login && @login.id != @seat.credential_id
          values = changes
          if values.all? { |column, value| @seat.public_send(column) == value }
            @result = { "helper_request_id" => nil }
            return
          end

          @seat.update!(values.merge(turning_off ? { wanted_running: false } : {}))
          changed = ctx.emit("seat.changed", subject: @seat, payload: {})
          stop = turn_off(ctx, changed) if turning_off
          look_again(ctx, changed) if login_changes
          @result = { "helper_request_id" => stop&.id }
        end

        private

        def load_login(ctx)
          credential_id = @params["credential_id"]
          raise Invalid, "An agent that connects on its own has no login to change" unless @seat.credential_id
          raise Invalid, "An agent the app runs keeps a login" if credential_id.nil?

          @login = Credential.find_by(id: credential_id, workspace_id: ctx.workspace.id)
          raise NotFound, "No such login" unless @login
          raise Invalid, "The agent's login must be an added login" unless @login.kind == "login" && @login.last_verified_at
        end

        # A change of role while the seat holds a task or a review (HE-27).
        def role_change_refused?
          return false unless @params.key?("role") && @params["role"] != @seat.role

          Task.where(workspace_id: @seat.workspace_id, holder_seat_id: @seat.id).exists? ||
            Review.where(workspace_id: @seat.workspace_id, reviewer_seat_id: @seat.id, verdict: nil).exists?
        end

        # The columns the request sets.
        def changes
          values = {}
          values[:name] = @params["name"] if @params.key?("name")
          values[:role] = @params["role"] if @params.key?("role")
          values[:model] = @params["model"].to_s if @params.key?("model")
          values[:effort] = @params["effort"].to_s if @params.key?("effort")
          values[:strength_rank] = @params["strength_rank"] || 1 if @params.key?("strength_rank")
          values[:enabled] = @params["enabled"] if @params.key?("enabled")
          values.merge!(credential_id: @login.id, provider: @login.provider) if @login
          values
        end

        # Releases the Working task the seat holds and closes its seat-bound
        # holds; queues stop_seat for a seat the app runs. Returns the
        # HelperRequest, or nil.
        def turn_off(ctx, changed)
          released = SeatRuns.release_working_task(ctx, @seat, reason: "seat_disabled", cause: changed)
          if released
            task = Task.find(released.task_id)
            Holds.close_seat_bound(ctx, task, cause: released, wait_cause: Candidates.wait_cause(task, ctx.at))
          end
          @seat.credential_id && SeatRuns.queue(ctx, "stop_seat", seat: @seat)
        end

        # HE-10: the open credential hold of a task the seat holds may close
        # now that the seat has another login.
        def look_again(ctx, changed)
          tasks = Task.where(workspace_id: @seat.workspace_id, holder_seat_id: @seat.id).order(:created_at)
            .select { |task| Holds.open_holds(task).any? { |hold| CREDENTIAL_HOLDS.include?(hold.reason) } }
          Handoff.reevaluate(ctx, tasks: tasks, cause: changed) unless tasks.empty?
        end
      end
    end
  end
end
