module V1
  module Agent
    # What every agent call shares (milestone 2 plan §2.1, IN-13): the seat
    # signs in by its bearer token, the body is checked against its schema in
    # openapi.json, and a change is a Request run by the transition function.
    # Nothing here knows what a command does, which role may send it or
    # whether a task is the seat's: the entry decides that and answers it as
    # a refusal. Only a call that reads (a briefing) checks that the seat
    # holds what it asks for, and answers 404 when it does not.
    class BaseController < ApplicationController
      include AuthenticatesSeat
      include RunsCommands

      # The body of the operation's request, checked against its schema in
      # openapi.json: a Hash with string keys; {} for an operation that takes
      # none. Raises RequestSchema::Malformed (400) or ::Invalid (422).
      #
      # This is Leverage::Http::RequestSchema.body! with the braces of the
      # path template percent-encoded in the JSON pointer: body! hands
      # json_schemer a pointer such as "#/paths/~1v1~1tasks~1{id}~1submit/...",
      # which is not a URI, and every operation with an id in its path then
      # fails with URI::InvalidURIError (reported in notes.md, WP8; the file
      # is WP1's). The helper's RequestsController calls this too. Remove it
      # when body! is fixed.
      def self.body!(operation_id, raw_body)
        schema = Leverage::Http::RequestSchema
        pointer = schema.schema_pointer(operation_id)
        return {} unless pointer

        body = schema.parse(raw_body.to_s)
        errors = schema.schemer.ref(pointer.gsub("{", "%7B").gsub("}", "%7D")).validate(body).map do |error|
          "#{error.fetch("data_pointer")} #{error.fetch("error")}"
        end
        raise schema::Invalid, "The body does not match the contract: #{errors.first(3).join("; ")}" unless errors.empty?

        body
      end

      private

      # Checks the body, reads the path's ids, and runs the command.
      #
      # operation_id - the operation, for its request schema.
      # command      - the command's name, or a callable given the checked
      #                body that returns it (a verdict is two commands).
      # ids          - the path parameters, named as the contract names them;
      #                each must be a UUID. An id that names nothing in the
      #                seat's workspace is the entry's 404.
      def run(operation_id, command, ids: [])
        body = checked_body(operation_id)
        command = command.call(body) if command.respond_to?(:call)
        run_command(command, params: ids.to_h { |name| [ name.to_s, uuid_param!(name) ] }.merge(body))
      end

      # The body as a Hash; {} for a call whose operation takes none (what
      # such a call is sent is ignored).
      def checked_body(operation_id) = self.class.body!(operation_id, request.raw_post)
    end
  end
end
