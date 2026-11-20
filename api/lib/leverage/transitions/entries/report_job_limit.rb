module Leverage
  module Transitions
    module Entries
      # report_job_limit (PRD L399, L401, L679, L688, L698, L872; milestone 4
      # plan RD-40; trace 19 commands 26 and 27): the helper reports that a
      # job's run met a provider limit. Handoff.interrupt marks the
      # credential and writes credential.limit_reached on the job's task,
      # naming the seat and the job; Handoff.continue_job switches the
      # job's run to the next candidate (credential.switched naming the job;
      # the job stays claimed and records the new credential), or, with
      # none, writes nothing more: the seat stops claiming jobs and the job
      # runs into its run timeout (no job.requeued, RD-40). No task state is
      # read and no task hold opens. The events are the app's with the
      # helper's id and key (IF-37). It answers completed with no result.
      #
      # Checked in this order, as report_limit is (HE-9):
      #
      #   404           a credential, seat or job that is not in the
      #                 workspace;
      #   422 invalid   a credential that is not an added login, the path and
      #                 the body naming two credentials, a seat with no
      #                 credential, or a task or a review named as well;
      #   not_holder    the seat did not claim the job;
      #   invalid_state the job is no longer claimed (finished, timed out or
      #                 withdrawn), or the credential reported is not the one
      #                 recorded for the job: the report is stale.
      #
      # A refused report marks no credential and writes no event.
      #
      # Params: "id" (the credential, from the path) and the LimitReport
      # body with job_id set.
      class ReportJobLimit < ReportLimit
        def load(ctx)
          @params = ctx.request.params
          workspace_id = ctx.workspace.id
          @credential = Credential.find_by(id: @params["id"], workspace_id: workspace_id) || raise(NotFound, "No such credential")
          @seat = Seat.find_by(id: @params["seat_id"], workspace_id: workspace_id) || raise(NotFound, "No such seat")
          @job = Job.find_by(id: @params["job_id"], workspace_id: workspace_id) || raise(NotFound, "No such job")
          check_job_shape
        end

        def refusals(ctx)
          codes = []
          codes << "not_holder" unless @job.claimed_by_seat_id == @seat.id
          codes << Refusal.new(code: "invalid_state") unless @job.state == "claimed"
          codes << Refusal.new(code: "invalid_state") unless @job.credential_id == @credential.id
          codes << state_refusal(nil, job_guards(ctx))
          codes.compact
        end

        def perform(ctx)
          first = Handoff.interrupt(ctx, credential: @credential, seat: @seat, kind: kind, job: @job, **limit_report)
          Handoff.continue_job(ctx, seat: @seat, stopped: @credential, cause: first, job: @job)
          @result = nil
        end

        private

        # Whether a candidate is next for the job's run (rule 4, with no
        # rule 3 for a job).
        def job_guards(ctx)
          [ Candidates.next_after(@seat, nil, @credential, ctx.at) ? "candidate_available" : "no_candidate_available" ]
        end

        def check_job_shape
          raise Invalid, "The path and the body name the same credential." unless @params["credential_id"] == @credential.id
          raise Invalid, "Only an added login is reported on." unless @credential.kind == "login" && @credential.last_verified_at
          raise Invalid, "A seat that connects on its own has no account the app reports on." unless @seat.credential_id
          raise Invalid, "A report names exactly one of a task, a review or a job." if @params["task_id"] || @params["review_id"]
        end
      end
    end
  end
end
