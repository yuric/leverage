# Signs a seat in by its bearer token (milestone 2 plan IN-17, IN-18): the
# token's digest must be a seat's token_hash, and the seat not removed.
# Anything else is 401 unauthenticated, before the action runs (IN-13).
module AuthenticatesSeat
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_seat!
  end

  # The signed-in Seat.
  def current_seat = current_caller.record

  private

  def authenticate_seat! = authenticate!(:seat)
end
