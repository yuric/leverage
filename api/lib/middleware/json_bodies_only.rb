require "json"
require "rack"

# Refuses, before Rails reads it, a request body under /v1/ that is not
# sent as application/json (PRD, Security: no secret appears in a log).
#
# Every leverage call that has a body takes JSON (openapi.json), and the
# controllers read the raw body. Rails, though, parses a body with a form
# media type, or with none, into params, and ActionController's
# "Parameters:" log line prints them; parameter filtering hides values,
# not keys, so a JSON body sent as a form would be logged whole, a
# password with it. This middleware answers such a request 400 malformed,
# in the contract's TransportError shape, before any controller runs. A
# request with no body (a bodyless command, a GET) passes whatever its
# media type.
#
#   config.middleware.use JsonBodiesOnly   # config/application.rb
class JsonBodiesOnly
  WITH_BODY = %w[POST PUT PATCH DELETE].freeze
  JSON_TYPE = "application/json".freeze
  ANSWER = { error: { code: "malformed", message: "A request body must be sent as application/json" } }.to_json.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless refuse?(env)

    [ 400, { "content-type" => "application/json; charset=utf-8" }, [ ANSWER ] ]
  end

  private

  def refuse?(env)
    return false unless WITH_BODY.include?(env["REQUEST_METHOD"]) && env["PATH_INFO"].to_s.start_with?("/v1/")
    return false unless body?(env)

    Rack::MediaType.type(env["CONTENT_TYPE"]) != JSON_TYPE
  end

  # Whether the request carries a body: a positive Content-Length, or a
  # chunked one (Transfer-Encoding, which has no length).
  def body?(env)
    length = env["CONTENT_LENGTH"].to_s
    return length.to_i.positive? unless length.empty?

    !env["HTTP_TRANSFER_ENCODING"].to_s.empty?
  end
end
