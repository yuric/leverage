module Leverage
  module Transitions
    module Entries
      # issue_helper_token (PRD L991; milestone 2 plan IN-11, IN-17, IN-18,
      # IN-30): the owner's app issues the helper a new token each time it
      # starts the helper. The workspace has one helper row: the first issue
      # makes it, each later one gives it the new name and the new token's
      # digest, which ends the previous token. The token is returned once,
      # in once, and never stored.
      #
      # It is also the point where the server and the Mac are brought back
      # in step (IN-30), in the same transaction: every unfinished helper
      # request fails (an add still running loses its credentials row,
      # IN-24), every seat still marked running is treated as stopped
      # (SeatRuns.run_stopped: its token ends and a review it holds is
      # released, written as the app with this command's key), and
      # start_seat is queued for every seat that is wanted running.
      #
      # Params: "name".
      class IssueHelperToken < Entry
        UNFINISHED = %w[queued picked_up].freeze

        # The result of a request failed by a new helper token: no check ran
        # under the new helper and nothing was reported.
        FAILED_RESULT = { "outcome" => "failed", "checks" => [], "tool_version" => nil, "plan" => nil,
                          "account_email" => nil }.freeze

        def load(ctx)
          @name = ctx.request.params["name"]
          raise Invalid, "The helper needs a name" unless @name.is_a?(String) && !@name.empty?
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          token = Tokens.issue(:helper)
          helper = issue(ctx, token)
          fail_unfinished_requests(ctx)
          stop_running_seats(ctx)
          start_wanted_seats(ctx)
          @result = { "helper_id" => helper.id }
          @once = { "helper_token" => token }
        end

        private

        def issue(ctx, token)
          helper = Helper.find_by(workspace_id: ctx.workspace.id)
          if helper
            helper.update!(name: @name, token_hash: Tokens.digest(token), last_reported_at: nil)
            helper
          else
            Helper.create!(workspace_id: ctx.workspace.id, name: @name, token_hash: Tokens.digest(token))
          end
        end

        def fail_unfinished_requests(ctx)
          HelperRequest.where(workspace_id: ctx.workspace.id, state: UNFINISHED).order(:requested_at).each do |request|
            request.update!(state: "failed", finished_at: ctx.at, result: FAILED_RESULT, updated_at: ctx.at)
            next unless request.kind == "run_add_checks" && request.credential_id

            # Only a row that never passed its checks is deleted (IN-24).
            Credential.where(id: request.credential_id, workspace_id: ctx.workspace.id, last_verified_at: nil).delete_all
          end
        end

        def stop_running_seats(ctx)
          Seat.where(workspace_id: ctx.workspace.id, run_state: "running").order(:created_at).each do |seat|
            SeatRuns.run_stopped(ctx, seat, actor_kind: "app", actor_id: nil)
          end
        end

        def start_wanted_seats(ctx)
          Seat.where(workspace_id: ctx.workspace.id, wanted_running: true, removed_at: nil).where.not(credential_id: nil)
            .order(:created_at).each do |seat|
            SeatRuns.queue(ctx, "start_seat", seat: seat, params: SeatRuns.start_params(seat))
          end
        end
      end
    end
  end
end
