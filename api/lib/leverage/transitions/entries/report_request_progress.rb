module Leverage
  module Transitions
    module Entries
      # report_request_progress (milestone 2 plan IN-23): one check's state
      # while a run_add_checks or verify request runs. helper_requests.
      # progress keeps each check's latest report, in the order the checks
      # were first reported, and updated_at becomes the command's time, which
      # the app's long poll on get_helper_request compares. No event: the
      # outcome is report_request_result's.
      #
      # What the schema cannot say is 422 invalid: a failure code is set
      # exactly when the check failed, and an install offer only on
      # tool_installed while it waits for the owner or after it failed. A
      # request of another kind, or one that has finished or failed, is
      # invalid_state; an unknown one 404.
      #
      # Params: "id" (the request), "check", "state", "failure", "install".
      class ReportRequestProgress < Entry
        KINDS = %w[run_add_checks verify].freeze
        UNFINISHED = %w[queued picked_up].freeze
        INSTALL_STATES = %w[waiting_for_install failed].freeze

        def load(ctx)
          params = ctx.request.params
          @request = HelperRequest.find_by(id: params["id"], workspace_id: ctx.workspace.id)
          raise NotFound, "No such helper request" unless @request

          @entry = params.slice("check", "state", "failure", "install")
          check_entry
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: "invalid_state") unless KINDS.include?(@request.kind) && UNFINISHED.include?(@request.state)
          causes.compact
        end

        def perform(ctx)
          progress = @request.progress.dup
          index = progress.index { |entry| entry["check"] == @entry["check"] }
          index ? progress[index] = @entry : progress << @entry
          @request.update!(progress: progress, updated_at: ctx.at)
          @result = {}
        end

        private

        def check_entry
          failed = @entry["state"] == "failed"
          raise Invalid, "A failure code goes with a failed check only" if failed != !@entry["failure"].nil?
          return if @entry["install"].nil?
          return if @entry["check"] == "tool_installed" && INSTALL_STATES.include?(@entry["state"])

          raise Invalid, "An install offer belongs to tool_installed while it waits or after it failed"
        end
      end
    end
  end
end
