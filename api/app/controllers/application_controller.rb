# The one place where an unhandled error becomes a response. Every error
# answers with the same JSON shape:
#
#   {"error":{"code":"not_found","message":"..."}}
#
# The status comes from Rails' own mapping of exception classes to statuses
# (config.action_dispatch.rescue_responses), so a missing record is a 404 and
# a missing parameter a 400. Anything unmapped is a 500, whose message never
# reveals internals.
class ApplicationController < ActionController::API
  rescue_from StandardError, with: :render_error

  # Unknown paths reach this action through the catch-all route, so that they
  # get the same JSON error shape as every other error.
  def route_not_found
    raise ActionController::RoutingError, "No route matches #{request.request_method} #{request.path}"
  end

  private

  def render_error(exception)
    status = ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name)
    code = Rack::Utils::SYMBOL_TO_STATUS_CODE.key(status) || :internal_server_error

    if status >= 500
      logger.error { "#{exception.class}: #{exception.message}\n#{Array(exception.backtrace).first(20).join("\n")}" }
      message = Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Internal Server Error")
    else
      message = exception.message
    end

    render json: { error: { code: code.to_s, message: message } }, status: status
  end
end
