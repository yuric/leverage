module Leverage
  module Transitions
    module Entries
      # change_seat (PRD L148, L258; milestone 3 plan HE-27, HE-10, HM-51):
      # only the fields the request sets change (ChangeSeatRequest), and
      # seat.changed is written. A Prompt seat may report its own model and
      # effort through report_model (UX-9).
      #
      # - name, model, effort, strength rank apply at once; the next run
      #   uses them. A null model or effort is "", the tool's default, and a
      #   null rank is 1, the seats' default (IN-29).
      # - role: a change is invalid_state while the seat holds a task or a
      #   review. Changing a running app seat to or from General restarts
      #   it through start_seat (GA-8). Approved actions are held when the
      #   previous builder changes to a role that does not build.
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
      #   (Holds.close_seat_bound, with HE-35's wait_cause). Finishing
      #   tasks with open approvals are held (L147, AP-19). A review the
      #   seat holds is released when its run is reported stopped (IF-21).
      #   enabled true starts nothing: the owner chooses Start. Milestone 4
      #   (plan §2.1 rule 11): the pending submit of that Working task, and a
      #   provisional claim the seat holds, are cancelled with invalid_state
      #   after seat.changed and before task.released; a reviewer's pending
      #   pass is cancelled when its run is reported stopped (SeatRuns), not
      #   by the change; a job the seat holds as a checker or a planner is
      #   left to its run timeout.
      # - permissions: the whole set is applied together. Turning Deliver
      #   off releases the Working task and ends any provisional claim or
      #   pending submit, while the seat keeps its approved actions (UX-11a).
      #
      # A request that changes no field (an empty body, or every field set
      # to what it is) completes with no event and changes nothing.
      #
      # A removed or unknown seat is 404. Result: helper_request_id, the
      # start_seat or stop_seat request when one was queued, else null.
      #
      # Params: id (the seat), and the ChangeSeatRequest body.
      class ChangeSeat < Entry
        CREDENTIAL_HOLDS = %w[credential_limit credential_signed_out].freeze
        MODEL_FIELDS = %w[effort model].freeze

        def load(ctx)
          @params = ctx.request.params
          @report = ctx.request.caller_kind == "seat"
          id = @report ? ctx.request.caller_id : @params["id"]
          @seat = Seat.find_by(id: id, workspace_id: ctx.workspace.id, removed_at: nil)
          raise NotFound, "No such seat" unless @seat

          if @report
            @report_forbidden = @seat.credential_id.present? || @params.keys.sort != MODEL_FIELDS
            return if @report_forbidden
          else
            load_owner_change(ctx)
          end

          @values = changes
          validate_model
        end

        def refusals(_ctx)
          return [ Refusal.new(code: "forbidden") ] if @report_forbidden

          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if role_change_refused?
          causes.compact
        end

        def perform(ctx)
          changed = @values.any? { |column, value| @seat.public_send(column) != value }
          if @report
            apply_changes(ctx) if changed
            @result = @values.stringify_keys
          elsif changed
            perform_owner_change(ctx)
          else
            @result = { "helper_request_id" => nil }
          end
        end

        private

        def load_owner_change(ctx)
          if @params.key?("name") && !(@params["name"].is_a?(String) && !@params["name"].empty?)
            raise Invalid, "A seat needs a name"
          end
          if @params.key?("role") && !Contract.list("seat_roles").include?(@params["role"])
            raise Invalid, "A seat is general, a builder, a reviewer, a planner or an orchestrator"
          end

          rank = @params["strength_rank"]
          unless rank.nil? || [ 1, 2, 3 ].include?(rank)
            raise Invalid, "A seat's strength rank is 1, 2 or 3"
          end

          load_login(ctx) if @params.key?("credential_id")
        end

        def validate_model
          provider = @values.fetch(:provider, @seat.provider)
          model_fields_set = MODEL_FIELDS.any? { |field| @params.key?(field) }
          return unless model_fields_set || provider != @seat.provider

          if !@report && @seat.credential_id.nil?
            raise Invalid, "An agent that connects by prompt reports its own model and effort"
          end

          problem = ModelCatalog.problem(provider: provider, model: @values.fetch(:model, @seat.model),
            effort: @values.fetch(:effort, @seat.effort), native: !@report)
          raise Invalid, problem if problem
        end

        def perform_owner_change(ctx)
          turning_off = @values[:enabled] == false && @seat.enabled
          turning_deliver_off = @values[:may_deliver] == false && @seat.may_deliver
          login_changes = @login && @login.id != @seat.credential_id
          old_role = @seat.role
          changed = apply_changes(ctx, **(turning_off ? { wanted_running: false } : {}))
          if turning_deliver_off && !turning_off
            SeatRuns.release_working_task(ctx, @seat, reason: "deliver_turned_off", cause: changed)
          end
          request = turning_off ? turn_off(ctx, changed) : change_role(ctx, old_role, changed)
          look_again(ctx, changed) if login_changes
          @result = { "helper_request_id" => request&.id }
        end

        def apply_changes(ctx, **extra)
          @seat.update!(@values.merge(extra))
          ctx.emit("seat.changed", subject: @seat, payload: {})
        end

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
          values.merge!(Permissions.columns(@params.fetch("permissions"))) if @params.key?("permissions")
          values
        end

        def change_role(ctx, old_role, changed)
          return if old_role == @seat.role

          if Roles.acts_as?(old_role, "builder") && !Roles.acts_as?(@seat.role, "builder")
            SeatRuns.hold_finishing_tasks(ctx, @seat, cause: changed)
          end
          return unless old_role == "general" || @seat.role == "general"
          return unless @seat.credential_id && @seat.run_state == "running" && @seat.wanted_running

          SeatRuns.start(ctx, @seat, SeatRuns.placement(@seat, at: ctx.at))
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
          SeatRuns.hold_finishing_tasks(ctx, @seat, cause: changed)
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
