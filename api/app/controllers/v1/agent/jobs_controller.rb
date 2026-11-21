module V1
  module Agent
    # The job calls of an orchestrator or a planner (milestone 4 plan §2.1,
    # §2.3, RD-34, RD-40, RD-41): claim the next job and send its result.
    #
    # Nothing here knows which role may claim or hold a job, whether the job
    # is the seat's or whether its time has run out: the entries decide that
    # and answer it as a refusal (`forbidden`, `not_holder`, `invalid_state`).
    # A result is one command, submit_job_result, whatever the job's kind: the
    # entry hands a planner's contract on to Complete contract itself (RE-6).
    class JobsController < BaseController
      # POST /v1/jobs/claim-next
      def claim_next = run("claim_next_job", "claim_job")

      # POST /v1/jobs/{id}/result
      def result = run("submit_job_result", "submit_job_result", ids: [ :id ])
    end
  end
end
