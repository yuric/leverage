module V1
  module Helper
    # The helper's reports about an account a run used (milestone 3 plan
    # §2.3, HE-8, HE-9): it met a provider limit, or it was found signed
    # out. The entries decide what each does, including the 404 for a
    # report that names a job (HE-33); this only checks the body and runs
    # the command with the path's credential id and the body as its params.
    # The order of answers is IN-13's: 401, then the body (400 or 422), then
    # 404 for the id. Neither report has a result (HE-8): the helper learns
    # what to do next from get_helper_next.
    class CredentialsController < ApplicationController
      include AuthenticatesHelper
      include RunsCommands

      # POST /v1/helper/credentials/{id}/limit-reached
      def limit_reached = report("report_limit")

      # POST /v1/helper/credentials/{id}/signed-out
      def signed_out = report("report_signed_out")

      private

      def report(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
