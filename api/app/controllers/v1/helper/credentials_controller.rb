module V1
  module Helper
    # The helper's reports about an account a run used (milestone 3 plan
    # §2.3, HE-8, HE-9; milestone 4 plan RD-40): it met a provider limit, or
    # it was found signed out. A report names exactly one of a task, a review
    # and a job (the schema enforces it): one that names a job runs
    # report_job_limit or report_job_signed_out, any other report_limit or
    # report_signed_out. The entries decide what each does; this only checks
    # the body and runs the command with the path's credential id and the body
    # as its params. The order of answers is IN-13's: 401, then the body (400
    # or 422), then 404 for the id. Neither report has a result (HE-8): the
    # helper learns what to do next from get_helper_next.
    class CredentialsController < ApplicationController
      include AuthenticatesHelper
      include RunsCommands

      # POST /v1/helper/credentials/{id}/limit-reached
      def limit_reached = report("report_limit", "report_job_limit")

      # POST /v1/helper/credentials/{id}/signed-out
      def signed_out = report("report_signed_out", "report_job_signed_out")

      private

      # operation_id names the body to check and the command a task's or a
      # review's report runs; job_command is the one a job's report runs.
      def report(operation_id, job_command)
        body = checked_body(operation_id)
        run_command(body["job_id"] ? job_command : operation_id, params: body.merge("id" => uuid_param!(:id)))
      end
    end
  end
end
