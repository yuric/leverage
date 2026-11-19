# Runs a command for the signed-in caller and renders its outcome (IF-4;
# milestone 2 plan §2.1): it reads the Idempotency-Key, builds the
# Leverage::Transitions::Request, calls Transitions.apply and answers 200
# completed, 202 pending or 409 refused with the outcome body
#
#   {key, command, outcome, result, refusal}
#
# A token shown once (Outcome#once) is merged into result in this response
# only. A repeat of the key answers the stored, token-free result, and for
# the four answers that carry a token it adds "repeated": true: the
# contract's OwnerSessionRepeated, HelperTokenIssuedRepeated,
# SeatConnectedRepeated and SeatTokenPickupRepeated (IN-9, IN-11).
#
#   def claim_next
#     run_command("claim")
#   end
#
# A missing or badly formed key is 400 malformed (IN-8); the engine's
# KeyReused, NotFound and Invalid become 422 key_reused, 404 not_found and
# 422 invalid in ApplicationController.
module RunsCommands
  extend ActiveSupport::Concern

  # The commands whose first answer carries a token, and its field.
  ONCE_FIELDS = {
    "create_owner" => "session_token",
    "sign_in" => "session_token",
    "issue_helper_token" => "helper_token",
    "connect_seat" => "seat_token",
    "issue_seat_token" => "seat_token"
  }.freeze

  STATUSES = { completed: 200, pending: 202, refused: 409 }.freeze

  # The outcome body of a command's Outcome.
  def self.outcome_body(command, key, outcome)
    { key: key, command: command, outcome: outcome.outcome.to_s, result: result_of(command, outcome),
      refusal: outcome.refusal&.to_h }
  end

  def self.result_of(command, outcome)
    return nil unless outcome.completed?

    result = outcome.result || {}
    if outcome.once
      result.merge(outcome.once)
    elsif ONCE_FIELDS.key?(command)
      result.merge("repeated" => true)
    else
      outcome.result
    end
  end

  private

  # Runs command and renders the outcome.
  #
  # params:       - the checked body and the path's ids, for the entry.
  # hash_without: - body fields the request hash leaves out (IN-9).
  # caller_kind:, caller_id:, workspace_id: - default: the signed-in caller;
  #                 setup and sign-in, which have no session, pass them.
  def run_command(command, params: {}, hash_without: [], caller_kind: current_caller&.kind,
                  caller_id: current_caller&.id, workspace_id: current_caller&.workspace_id)
    key = request.headers["Idempotency-Key"]
    raise ApplicationController::Malformed, "Idempotency-Key must be 1 to 128 of A-Z a-z 0-9 _ -" unless Leverage::Idempotency.valid_key?(key)

    hash = Leverage::Idempotency.request_hash(method: request.request_method, path: request.path, body: request.raw_post,
      without: hash_without)
    command_request = Leverage::Transitions::Request.new(command: command, workspace_id: workspace_id,
      caller_kind: caller_kind, caller_id: caller_id, key: key, request_hash: hash, params: params)
    outcome = Leverage::Transitions.apply(command_request)
    render json: RunsCommands.outcome_body(command, key, outcome), status: STATUSES.fetch(outcome.outcome)
  end
end
