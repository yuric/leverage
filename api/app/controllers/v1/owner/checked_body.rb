module V1
  module Owner
    # Reads a request's JSON body and checks it against the operation's
    # request schema in openapi.json, as Leverage::Http::RequestSchema.body!
    # does (400 malformed, 422 invalid).
    #
    # WORKAROUND, to be deleted: RequestSchema.body! builds its JSON pointer
    # with `{id}` and `{provider}` left raw, and json_schemer refuses that as
    # a URI (URI::InvalidURIError), so every operation with a request body and
    # a path parameter answers 500. This module percent-encodes the braces and
    # otherwise uses RequestSchema's own parts. When request_schema.rb is
    # fixed (notes.md, WP9, request 1), call RequestSchema.body! again and
    # remove this file.
    module CheckedBody
      private

      def checked_body(operation_id)
        raw = request.raw_post
        pointer = Leverage::Http::RequestSchema.schema_pointer(operation_id)
        return Leverage::Http::RequestSchema.body!(operation_id, raw) if pointer.nil?

        body = Leverage::Http::RequestSchema.parse(raw.to_s)
        errors = Leverage::Http::RequestSchema.schemer.ref(pointer.gsub("{", "%7B").gsub("}", "%7D")).validate(body)
          .map { |error| "#{error.fetch("data_pointer")} #{error.fetch("error")}" }
        unless errors.empty?
          raise Leverage::Http::RequestSchema::Invalid, "The body does not match the contract: #{errors.first(3).join("; ")}"
        end

        body
      end
    end
  end
end
