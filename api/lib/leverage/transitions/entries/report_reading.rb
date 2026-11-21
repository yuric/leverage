module Leverage
  module Transitions
    module Entries
      # Store the helper's usage reading, then look at limit holds that the
      # recovered account could end (CR-14, IF-37). The reading itself has
      # no event. The controller checks the body's schema before dispatch.
      class ReportReading < Entry
        attr_reader :capacity_restored

        def load(ctx)
          @params = ctx.request.params
          @credential = Credential.added.find_by(id: @params["id"], workspace_id: ctx.workspace.id)
          raise NotFound, "No such credential" unless @credential
          raise Invalid, "The path and body must name the same credential" unless @params["credential_id"] == @credential.id

          @observed_at = observation_time(@params["observed_at"])
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          reading = CredentialReading.create!(workspace_id: ctx.workspace.id, credential_id: @credential.id,
            observed_at: @observed_at, state: @params["state"], tool_version: @params["tool_version"],
            figures: @params["figures"], resets: @params["resets"], created_at: ctx.at)
          return unless ReadingCapacity.shown?(@credential, reading)

          @credential.update!(limited_since: nil, limited_until: nil, updated_at: ctx.at)
          @capacity_restored = Candidates.available?(@credential, ctx.at)
          Handoff.reevaluate(ctx, tasks: waiting_for_capacity(ctx)) if @capacity_restored
        end

        private

        def observation_time(value)
          Time.iso8601(value.to_s)
        rescue ArgumentError
          raise Invalid, "The observation time must be ISO 8601"
        end

        def waiting_for_capacity(ctx)
          workspace_id = ctx.workspace.id
          held = ::Hold.where(workspace_id: workspace_id, reason: "credential_limit", closed_at: nil).select(:task_id)
          Task.where(workspace_id: workspace_id, id: held).where.not(holder_seat_id: nil).find_each.filter_map do |task|
            seat = Seat.find_by(workspace_id: workspace_id, id: task.holder_seat_id)
            task if Candidates.kept_for?(seat, @credential, task)
          end
        end
      end
    end
  end
end
