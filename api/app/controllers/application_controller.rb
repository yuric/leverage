# The one place where an unhandled error becomes a response. Every error
# answers with the same JSON shape:
#
#   {"error":{"code":"not_found","message":"..."}}
#
# The status comes from Rails' own mapping of exception classes to statuses
# (config.action_dispatch.rescue_responses), so a missing record is a 404 and
# a missing parameter a 400. Anything unmapped is a 500, whose message never
# reveals internals.
#
# Errors raised in a controller are rescued here. Errors raised before any
# controller runs, in the router or in a middleware (a malformed URI or query
# string, say), reach Rails' ShowExceptions middleware, which calls
# ApplicationController.exceptions_app (config.exceptions_app in
# config/application.rb). Both build the answer with error_response.
class ApplicationController < ActionController::API
  rescue_from StandardError, with: :render_error

  # The status and the JSON body for an exception.
  def self.error_response(exception)
    status = ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name)
    code = Rack::Utils::SYMBOL_TO_STATUS_CODE.key(status) || :internal_server_error
    message = status >= 500 ? Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Internal Server Error") : exception.message
    [ status, { error: { code: code.to_s, message: message } } ]
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

  private

  def render_error(exception)
    status, body = self.class.error_response(exception)
    if status >= 500
      logger.error { "#{exception.class}: #{exception.message}\n#{Array(exception.backtrace).first(20).join("\n")}" }
    end
    render json: body, status: status
  end
end
