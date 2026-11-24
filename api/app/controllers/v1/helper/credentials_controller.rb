module V1
  module Helper
    # The helper reports usage readings, provider limits and sign-outs.
    # A limit or sign-out names exactly one task, review or job. A report
    # that names a job runs its own command (milestone 4 plan RD-40).
    # Each action checks the body and passes it with the path's credential
    # id. The reports have no result. The helper learns what to do next
    # from get_helper_next.
    class CredentialsController < ApplicationController
      include AuthenticatesHelper
      include RunsCommands

      # POST /v1/helper/credentials/{id}/limit-reached
      def limit_reached = report("report_limit", "report_job_limit")

      # POST /v1/helper/credentials/{id}/signed-out
      def signed_out = report("report_signed_out", "report_job_signed_out")

      def readings
        run_command("report_reading", params: checked_body("report_reading").merge("id" => uuid_param!(:id)))
      end

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
