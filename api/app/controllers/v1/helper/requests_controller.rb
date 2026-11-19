module V1
  module Helper
    # The helper's reports on a request: one check's state while it runs, and
    # its result (milestone 2 plan §2.1, IN-23). The entries (WP7) decide
    # what each does; this only checks the body and runs the command with
    # the path's id and the body as its params. The seat's token and the
    # run reports are V1::Helper::SeatsController's.
    class RequestsController < ApplicationController
      include AuthenticatesHelper
      include RunsCommands

      def progress = run("report_request_progress")
      def result = run("report_request_result")

      private

      def run(operation_id)
        body = V1::Agent::BaseController.body!(operation_id, request.raw_post)
        run_command(operation_id, params: { "id" => uuid_param!(:id) }.merge(body))
      end
    end
  end
end
