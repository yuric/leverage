require "json"
require "json_schemer"

module Leverage
  module Http
    # Reads a request's JSON body and checks it against the operation's
    # requestBody schema in openapi.json (IF-3; milestone 2 plan §2.1).
    #
    #   body = Leverage::Http::RequestSchema.body!("add_task", request.raw_post)
    module RequestSchema
      # The body is not JSON: 400 malformed.
      class Malformed < StandardError; end

      # The body fails its schema: 422 invalid.
      class Invalid < StandardError; end

      @mutex = Mutex.new

      module_function

      # The parsed body (a Hash with string keys) of an operation's
      # request. An operation that takes no body accepts an empty one and
      # answers {}.
      def body!(operation_id, raw_body)
        pointer = schema_pointer(operation_id)
        text = raw_body.to_s
        if pointer.nil?
          return {} if text.strip.empty?

          raise Invalid, "#{operation_id} takes no body"
        end

        body = parse(text)
        errors = schemer.ref(pointer).validate(body).map { |error| "#{error.fetch("data_pointer")} #{error.fetch("error")}" }
        raise Invalid, "The body does not match the contract: #{errors.first(3).join("; ")}" unless errors.empty?

        body
      end

      # The JSON pointer of the operation's request body schema, or nil.
      def schema_pointer(operation_id)
        template, verb, operation = operation(operation_id)
        return nil unless operation.key?("requestBody")

        escaped = template.gsub("~", "~0").gsub("/", "~1")
        "#/paths/#{escaped}/#{verb}/requestBody/content/application~1json/schema"
      end

      def operation(operation_id)
        Contract.openapi.fetch("paths").each do |template, item|
          item.each do |verb, operation|
            return [ template, verb, operation ] if operation.is_a?(Hash) && operation["operationId"] == operation_id
          end
        end
        raise KeyError, "no operation #{operation_id} in openapi.json"
      end

      def parse(text)
        JSON.parse(text)
      rescue JSON::ParserError
        raise Malformed, "The body is not JSON"
      end

      def schemer
        @schemer || @mutex.synchronize { @schemer ||= JSONSchemer.openapi(Contract.openapi) }
      end
    end
  end
end
