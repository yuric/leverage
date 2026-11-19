# Signs the owner in by the bearer token of a session (milestone 2 plan
# IN-5, IN-18): the token's digest must be a session's token_hash; a
# signed-out session has no row. Anything else is 401 unauthenticated,
# before the action runs (IN-13). current_caller.id is the owner's user.
# setup and sign-in, which have no session yet, skip it with
# skip_before_action :authenticate_owner!.
module AuthenticatesOwner
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_owner!
  end

  # The signed-in Session.
  def current_session = current_caller.record

  private

  def authenticate_owner! = authenticate!(:owner)
end
