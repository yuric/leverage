module Leverage
  module Transitions
    module Entries
      # report_limit (PRD L678-L682; milestone 3 plan §2.1 rules 5 and 6,
      # HE-8, HE-9, HE-22, HE-32, HE-33, HD-10): the helper reports that a
      # run met a provider limit. Handoff.interrupt marks the credential and
      # writes credential.limit_reached; Handoff.continue_or_hold switches
      # the work to the next candidate, holds the task, or releases the
      # review. The events are the app's with the helper's id and key
      # (IF-37). It answers completed with no result (HE-8).
      #
      # Checked in this order (HE-9), after the timers due on the work's task
      # (the pipeline's step 3):
      #
      #   422 invalid   a job: a report that names one is report_job_limit's
      #                 (milestone 4 plan RD-40; the helper's controller
      #                 picks the command by the body; HE-33's 404 is gone);
      #   404           a credential, seat, task or review that is not in
      #                 the workspace;
      #   422 invalid   a credential that is not an added login, the path
      #                 and the body naming two credentials, a seat with no
      #                 credential, or not exactly one of task and review;
      #   lease_expired, task_cancelled, not_holder  as for the seat's own
      #                 calls, when the seat does not hold the work;
      #   invalid_state no row for the task's state that is served (no row
      #                 from Finishing is, HS-3), the credential reported is
      #                 not the one recorded for the work, or the task
      #                 already waits on a credential hold (no run is on it,
      #                 HE-21: the report is stale).
      #
      # A refused report marks no credential and writes no event.
      #
      # Params: "id" (the credential, from the path) and the LimitReport
      # body: credential_id, seat_id, task_id, review_id, job_id, window,
      # reset_at, observed_at, tool_version.
      class ReportLimit < Entry
        # The task states whose rows are not served yet (HS-3).
        NOT_SERVED_FROM = %w[finishing].freeze

        # The kind of stop Handoff.interrupt records.
        def kind = "limit"

        def load(ctx)
          @params = ctx.request.params
          raise Invalid, "A report that names a job is report_job_limit's or report_job_signed_out's." if @params["job_id"]

          workspace_id = ctx.workspace.id
          @credential = Credential.find_by(id: @params["id"], workspace_id: workspace_id) || raise(NotFound, "No such credential")
          @seat = Seat.find_by(id: @params["seat_id"], workspace_id: workspace_id) || raise(NotFound, "No such seat")
          @task = @params["task_id"] && (Task.find_by(id: @params["task_id"], workspace_id: workspace_id) ||
                                         raise(NotFound, "No such task"))
          @review = @params["review_id"] && (Review.find_by(id: @params["review_id"], workspace_id: workspace_id) ||
                                             raise(NotFound, "No such review"))
          check_shape
          @on = @task || Task.find_by!(id: @review.task_id, workspace_id: workspace_id)
        end

        def refusals(ctx)
          codes = @review ? Eligibility.review_refusals(@review, @seat) : Eligibility.task_refusals(@task, @seat, role: @seat.role)
          codes -= [ "forbidden" ]
          codes << state_refusal(@on.state, guards(ctx))
          codes << Refusal.new(code: "invalid_state") if NOT_SERVED_FROM.include?(@on.state)
          codes << Refusal.new(code: "invalid_state") unless (@review || @task).credential_id == @credential.id
          codes << Refusal.new(code: "invalid_state") if held?
          codes.compact
        end

        def perform(ctx)
          first = Handoff.interrupt(ctx, credential: @credential, seat: @seat, kind: kind, task: @task, review: @review,
            **limit_report)
          Handoff.continue_or_hold(ctx, seat: @seat, stopped: @credential, cause: first, task: @task, review: @review)
          after_hand_over(ctx, first)
          @result = nil
        end

        private

        # Whether the task already waits on a credential hold: no run is
        # on it then (HE-21), so a report about it is stale, and a second
        # one would write the interruption and open the hold again.
        def held?
          @task && Holds.open_holds(@task).any? { |hold| Handoff::CREDENTIAL_REASONS.include?(hold.reason) }
        end

        # What a sign-out adds after the work has moved (ReportSignedOut).
        def after_hand_over(_ctx, _first); end

        def limit_report
          { window: @params["window"], reset_at: time(@params["reset_at"]), observed_at: time(@params["observed_at"]) }
        end

        def check_shape
          unless @params["credential_id"] == @credential.id
            raise Invalid, "The path and the body name the same credential."
          end
          unless @credential.kind == "login" && @credential.last_verified_at
            raise Invalid, "Only an added login is reported on."
          end
          raise Invalid, "A seat that connects on its own has no account the app reports on." unless @seat.credential_id
          raise Invalid, "A report names exactly one of a task, a review or a job." unless [ @task, @review ].compact.one?
        end

        # The guards of the row the report's work is in: for a review,
        # whether a reviewer holds it; then whether a candidate is next
        # (rule 4, HE-4).
        def guards(ctx)
          work = @review || @task
          following = Candidates.next_after(@seat, work, @credential, ctx.at)
          guards = [ following ? "candidate_available" : "no_candidate_available" ]
          return guards unless @review

          held = @review.reviewer_seat_id && @review.verdict.nil?
          [ held ? "reviewer_holds_review" : "no_reviewer_holds_review" ] + (held ? guards : [])
        end

        def time(value)
          value.is_a?(String) ? Time.iso8601(value) : value
        rescue ArgumentError
          raise Invalid, "A time is ISO 8601."
        end
      end
    end
  end
end
