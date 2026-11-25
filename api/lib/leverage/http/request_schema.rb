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
      # request. An operation that takes no body accepts an empty body or
      # an empty JSON object, and answers {}; any other body is 422 invalid
      # (one rule for the agent, owner and helper interfaces).
      #
      # A body with a NUL character in any key or text is 422 invalid too.
      # JSON can carry one (the escape \u0000) and every string schema
      # accepts it, but PostgreSQL text and bcrypt cannot take one: the
      # command would fail where the value is stored or compared and
      # answer 500, on sign-in and setup as on any other call.
      def body!(operation_id, raw_body)
        pointer = schema_pointer(operation_id)
        text = raw_body.to_s
        if pointer.nil?
          return {} if text.strip.empty? || parse(text) == {}

          raise Invalid, "#{operation_id} takes no body"
        end

        body = parse(text)
        raise Invalid, "Text cannot contain a NUL character" if nul?(body)

        errors = schemer.ref(pointer).validate(body).map { |error| "#{error.fetch("data_pointer")} #{error.fetch("error")}" }
        raise Invalid, "The body does not match the contract: #{errors.first(3).join("; ")}" unless errors.empty?

        body
      end

      # The JSON pointer of the operation's request body schema, or nil.
      def schema_pointer(operation_id)
        template, verb, operation = operation(operation_id)
        return nil unless operation.key?("requestBody")

        "#/paths/#{escape(template)}/#{verb}/requestBody/content/application~1json/schema"
      end

      # A path template as one token of a JSON pointer inside a URI
      # fragment: "~" and "/" escaped as RFC 6901 says, and the braces of
      # a path parameter ({id}) percent-encoded, because json_schemer reads
      # the pointer as a URI and a raw brace is not allowed in one.
      def escape(template)
        template.gsub("~", "~0").gsub("/", "~1").gsub("{", "%7B").gsub("}", "%7D")
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

      # Whether a parsed body holds a NUL character in a key or a text, at
      # any depth. The parsed value is read, not the raw body, where the
      # six characters \u0000 may also be an escaped backslash and "u0000".
      def nul?(value)
        case value
        when String then value.include?("\u0000")
        when Array then value.any? { |item| nul?(item) }
        when Hash then value.any? { |key, item| nul?(key) || nul?(item) }
        else false
        end
      end

      def schemer
        @schemer || @mutex.synchronize { @schemer ||= JSONSchemer.openapi(Contract.openapi) }
      end
    end
  end
end
