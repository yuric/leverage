# Signs the helper in by its bearer token (milestone 2 plan IN-17, IN-18):
# the token's digest must be the helper's token_hash; the next token
# issued replaces it. Anything else is 401 unauthenticated, before the
# action runs (IN-13).
module AuthenticatesHelper
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_helper!
  end

  # The signed-in Helper.
  def current_helper = current_caller.record

  private

  def authenticate_helper! = authenticate!(:helper)
end
