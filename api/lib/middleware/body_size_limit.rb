require "json"

# Refuses, before Rails reads it, a request body over LIMIT bytes,
# whatever its method and path.
#
# The contract's length limits (openapi.json) bound the fields that have
# one; without this nothing bounds what a controller reads into memory and
# parses, on the two calls that need no token (setup and sign-in) as on
# the rest. The largest body those limits allow, a task with every text
# field full, is under 1 MiB as UTF-8, so LIMIT refuses nothing the
# contract accepts. The answer is 400 malformed in the contract's
# TransportError shape, one of the five transport codes (IF-3), given
# from the stated length alone: the body is not read.
#
# Puma decodes a chunked body and puts its length in CONTENT_LENGTH before
# the application runs. A body that still arrives with a Transfer-Encoding
# and no length cannot be measured, and is refused too.
#
#   config.middleware.use BodySizeLimit   # config/application.rb
class BodySizeLimit
  LIMIT = 4 * 1024 * 1024

  TOO_LARGE = { error: { code: "malformed", message: "A request body is at most #{LIMIT} bytes" } }.to_json.freeze
  NO_LENGTH = { error: { code: "malformed", message: "A request body must state its length" } }.to_json.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    answer = refusal(env)
    return @app.call(env) unless answer

    [ 400, { "content-type" => "application/json; charset=utf-8" }, [ answer ] ]
  end

  private

  def refusal(env)
    length = env["CONTENT_LENGTH"].to_s
    return (TOO_LARGE if length.to_i > LIMIT) unless length.empty?

    NO_LENGTH unless env["HTTP_TRANSFER_ENCODING"].to_s.empty?
  end
end
