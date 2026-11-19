# The one place where an unhandled error becomes a response. Every error
# answers with the same JSON shape, the contract's TransportError:
#
#   {"error":{"code":"not_found","message":"..."}}
#
# The five transport codes are IF-3's: 400 malformed, 401 unauthenticated,
# 404 not_found, 422 key_reused and 422 invalid. The status comes from the
# error's own class (TransportError and the engine's errors below) or from
# Rails' mapping of exception classes to statuses
# (config.action_dispatch.rescue_responses), so a missing record is a 404
# and an unparsable body a 400. Anything unmapped is a 500, whose message
# never reveals internals.
#
# Errors raised in a controller are rescued here. Errors raised before any
# controller runs, in the router or in a middleware (a malformed URI or query
# string, say), reach Rails' ShowExceptions middleware, which calls
# ApplicationController.exceptions_app (config.exceptions_app in
# config/application.rb). Both build the answer with error_response.
class ApplicationController < ActionController::API
  # An error a controller raises with its transport code (IF-3).
  class TransportError < StandardError
    def self.status = raise(NotImplementedError)
    def self.code = raise(NotImplementedError)
  end

  class Malformed < TransportError
    def self.status = 400
    def self.code = "malformed"
  end

  class Unauthenticated < TransportError
    def self.status = 401
    def self.code = "unauthenticated"

    def initialize(message = "Sign in with a valid bearer token") = super
  end

  class NotFound < TransportError
    def self.status = 404
    def self.code = "not_found"
  end

  class KeyReused < TransportError
    def self.status = 422
    def self.code = "key_reused"
  end

  class Invalid < TransportError
    def self.status = 422
    def self.code = "invalid"
  end

  # The engine's errors, by the transport error each one is.
  ENGINE_ERRORS = {
    "Leverage::Idempotency::KeyReused" => KeyReused,
    "Leverage::Transitions::NotFound" => NotFound,
    "Leverage::Transitions::Invalid" => Invalid,
    "Leverage::Http::RequestSchema::Malformed" => Malformed,
    "Leverage::Http::RequestSchema::Invalid" => Invalid
  }.freeze

  # The transport code of a status Rails maps an exception to.
  CODES = { 400 => "malformed", 401 => "unauthenticated", 404 => "not_found", 422 => "invalid" }.freeze

  rescue_from StandardError, with: :render_error

  # The status and the JSON body for an exception.
  def self.error_response(exception)
    transport = exception.is_a?(TransportError) ? exception.class : ENGINE_ERRORS[exception.class.name]
    if transport
      status = transport.status
      code = transport.code
    else
      status = ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name)
      code = CODES[status] || (Rack::Utils::SYMBOL_TO_STATUS_CODE.key(status) || :internal_server_error).to_s
    end
    message = status >= 500 ? Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Internal Server Error") : exception.message
    [ status, { error: { code: code, message: message } } ]
  end

  # A plain Rack answer, not a controller action: an action would read the
  # request's parameters again, and a malformed query string would fail again.
  # ShowExceptions has already logged the exception.
  def self.exceptions_app(env)
    status, body = error_response(env.fetch("action_dispatch.exception"))
    [ status, { "content-type" => "application/json; charset=utf-8" }, [ body.to_json ] ]
  end

  # Unknown paths reach this action through the catch-all routes, so that they
  # get the same JSON error shape as every other error.
  def route_not_found
    raise ActionController::RoutingError, "No route matches #{request.request_method} #{request.path}"
  end

  # Who the call's bearer token signed in (a Leverage::Tokens::Caller), set
  # by AuthenticatesSeat, AuthenticatesOwner or AuthenticatesHelper.
  attr_reader :current_caller

  private

  # The token of an "Authorization: Bearer <token>" header, or nil.
  def bearer_token
    header = request.authorization.to_s
    match = /\ABearer[ ]+(\S+)\s*\z/.match(header)
    match && match[1]
  end

  # Signs the call in with a token of the kind, or answers 401.
  def authenticate!(kind)
    @current_caller = Leverage::Tokens.find(bearer_token, kind: kind) || raise(Unauthenticated)
  end

  # A path id that is not a UUID names nothing: 404, not a database error.
  def uuid_param!(name)
    value = params[name].to_s
    raise NotFound, "No such #{name}" unless /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/.match?(value)

    value
  end

  def render_error(exception)
    status, body = self.class.error_response(exception)
    if status >= 500
      logger.error { "#{exception.class}: #{exception.message}\n#{Array(exception.backtrace).first(20).join("\n")}" }
    end
    render json: body, status: status
  end
end
