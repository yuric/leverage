module V1
  module Helper
    # The helper's calls about a seat the app runs (milestone 2 plan IN-11,
    # IN-17, PK-7, IF-21): the seat-token pickup for a start_seat request,
    # whose first answer carries the seat's fresh token once
    # (SeatTokenPickup), and the run-started and run-stopped reports. The
    # order of answers is IN-13's: 401, then the body (400 or 422), then
    # 404 for an id.
    class SeatsController < ApplicationController
      include AuthenticatesHelper
      include RunsCommands

      # POST /v1/helper/requests/{id}/seat-token: the id is the start_seat
      # request's.
      def seat_token
        Leverage::Http::RequestSchema.body!("issue_seat_token", request.raw_post)
        run_command("issue_seat_token", params: { "id" => uuid_param!(:id) })
      end

      # POST /v1/helper/seats/{id}/run-started
      def run_started = report("report_run_started")

      # POST /v1/helper/seats/{id}/run-stopped
      def run_stopped = report("report_run_stopped")

      private

      def report(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end

      # The body checked against the operation's request schema: what
      # RequestSchema.body! does, except that the schema is found by the
      # requestBody's $ref. body! builds a JSON pointer from the path
      # template, and a path with {id} is not a valid URI fragment, so for
      # these two calls it raises URI::InvalidURIError (a 500). Until
      # http/request_schema.rb escapes the braces (asked in notes.md, WP6),
      # this is the work-around; then it is body! again.
      def checked_body(operation_id)
        schema = Leverage::Http::RequestSchema
        _template, _verb, operation = schema.operation(operation_id)
        ref = operation.dig("requestBody", "content", "application/json", "schema", "$ref")
        return schema.body!(operation_id, request.raw_post) unless ref

        body = schema.parse(request.raw_post.to_s)
        errors = schema.schemer.ref(ref).validate(body).map { |error| "#{error.fetch("data_pointer")} #{error.fetch("error")}" }
        raise schema::Invalid, "The body does not match the contract: #{errors.first(3).join("; ")}" unless errors.empty?

        body
      end
    end
  end
end
